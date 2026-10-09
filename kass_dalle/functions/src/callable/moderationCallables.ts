/**
 * Entrées HTTPS de la modération d'images.
 *
 * Toute image destinée à être vue par la famille passe par ici : le client
 * écrit dans `quarantine/{uid}/`, appelle cette fonction avec la destination
 * voulue, et reçoit soit l'URL publiée, soit un état d'attente. Les quatre
 * dossiers publiés sont fermés en écriture côté règles ; c'est le serveur, et
 * lui seul, qui y dépose.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { isAdminAccount, requireAdmin, requireAuth } from "./_auth";
import { logError, logInfo, logWarn } from "../logging";
import { recordUsage } from "../ai/usage";
import {
  MODERATION_FEATURE,
  MODERATION_FEATURE_BATCH,
  analyseImage,
  getModerationConfig,
} from "../moderation/engine";
import { decideModeration } from "../moderation/decision";
import {
  ImageFormatRejected,
  QuarantineFileMissing,
  moderateAndPromote,
  type ModerationItem,
} from "../moderation/moderateAndPromote";
import { clientDeclaredOrigin } from "../moderation/origin";
import {
  TargetNotOwned,
  quarantineToRejected,
  isTargetKind,
  isValidDocumentId,
  legacyFileMayHaveChanged,
  pinnedGeneration,
  promoteImage,
} from "../moderation/promote";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "512MiB" as const,
  timeoutSeconds: 120,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
};

const COLLECTION = "image_moderation";

/**
 * `ownerId` absent ou vide vaut `null` ; présent, il doit être un identifiant
 * de document. Un « / » ferait viser un autre document que celui dont la
 * propriété est vérifiée, et un autre dossier Storage.
 */
function parseOwnerId(value: unknown): string | null {
  if (value == null || value === "") return null;
  if (!isValidDocumentId(value)) {
    throw new HttpsError("invalid-argument", "ownerId invalide.");
  }
  return value;
}

function parseItems(data: unknown, uid: string): ModerationItem[] {
  const raw = (data ?? {}) as { items?: unknown };
  if (!Array.isArray(raw.items) || raw.items.length === 0) {
    throw new HttpsError(
      "invalid-argument",
      "items est requis et doit contenir au moins une image.",
    );
  }
  if (raw.items.length > 25) {
    throw new HttpsError("invalid-argument", "25 images au maximum par appel.");
  }
  return raw.items.map((entry) => {
    const item = (entry ?? {}) as Record<string, unknown>;
    const quarantinePath = typeof item.quarantinePath === "string" ? item.quarantinePath : "";
    if (!quarantinePath.startsWith(`quarantine/${uid}/`)) {
      throw new HttpsError("permission-denied", "Chemin de quarantaine invalide.");
    }
    if (!isTargetKind(item.targetKind)) {
      throw new HttpsError("invalid-argument", "targetKind inconnu.");
    }
    return {
      quarantinePath,
      targetKind: item.targetKind,
      ownerId: parseOwnerId(item.ownerId),
      contentType: typeof item.contentType === "string" ? item.contentType : "image/jpeg",
      // Jamais `ai` depuis un client, et `asset` seulement à vérifier sur
      // l'empreinte du fichier (`moderation/origin.ts`).
      origin: clientDeclaredOrigin(item.origin),
    };
  });
}

/**
 * Analyse et publie un lot d'images.
 *
 * Un lot est un poste de coût à part (`image_moderation_batch`) : le distinguer
 * de sa version unitaire est le seul moyen de vérifier que le groupage fait son
 * office.
 */
export const moderateAndPromoteImagesFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, MODERATION_FEATURE);
  const items = parseItems(req.data, ctx.userId);

  try {
    return await moderateAndPromote({
      items,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      isAdmin: isAdminAccount,
    });
  } catch (err) {
    // Les deux refus que le cœur signale par une erreur typée sont des refus
    // d'appel, pas des verdicts : ils se rendent au client tels quels.
    if (err instanceof ImageFormatRejected) {
      throw new HttpsError("failed-precondition", err.detail);
    }
    if (err instanceof QuarantineFileMissing) {
      throw new HttpsError("not-found", "Fichier en quarantaine introuvable.");
    }
    if (err instanceof TargetNotOwned) {
      await logWarn({
        message: "Publication refusée : destination d'un autre compte",
        moduleType: "MODERATION",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        feature: MODERATION_FEATURE,
        extra: { targetKind: err.kind, ownerId: err.ownerId },
      });
      throw new HttpsError("permission-denied", err.detail);
    }
    throw err;
  }
});

/** Décision d'un administrateur sur une image en attente. */
export const reviewModeratedImageFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAdmin(req, "image_moderation_review");
  const data = (req.data ?? {}) as Record<string, unknown>;
  const moderationId = typeof data.moderationId === "string" ? data.moderationId : "";
  const decision =
    data.decision === "approve" ? "approve" : data.decision === "reject" ? "reject" : null;
  const note = typeof data.note === "string" ? data.note.trim() : "";

  if (moderationId.length === 0 || decision === null) {
    throw new HttpsError("invalid-argument", "moderationId et decision sont requis.");
  }
  if (decision === "reject" && note.length === 0) {
    // Le motif n'est pas une formalité : c'est ce que lira l'envoyeur.
    throw new HttpsError("invalid-argument", "Un refus demande un motif.");
  }

  const db = getFirestore();
  const ref = db.collection(COLLECTION).doc(moderationId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Décision introuvable.");

  const doc = snap.data() as Record<string, unknown>;
  const status = String(doc.status ?? "");
  if (status !== "manual_review") {
    throw new HttpsError("failed-precondition", "Cette image n'attend pas de décision.");
  }

  // Document antérieur à l'épinglage de la génération : on ne publie pas un
  // fichier qui a pu être réécrit après l'analyse. L'image repasse en attente,
  // et « Relancer l'analyse » (`retryPendingModerationFn`) la juge à nouveau.
  //
  // Quand le fichier est jugé inchangé, sa génération lue ici est épinglée
  // pour la copie : il ne doit pas pouvoir changer entre cette vérification
  // et la promotion.
  let sourceGeneration: unknown = doc.quarantine_generation;
  if (decision === "approve" && pinnedGeneration(doc.quarantine_generation) == null) {
    const [meta] = await getStorage()
      .bucket()
      .file(String(doc.quarantine_path ?? ""))
      .getMetadata();
    const createdAt = doc.created_at as { toMillis?: () => number } | undefined;
    const createdAtMs = typeof createdAt?.toMillis === "function" ? createdAt.toMillis() : null;
    if (legacyFileMayHaveChanged(meta.updated, createdAtMs)) {
      await ref.update({ status: "pending" });
      await logWarn({
        message: "Approbation refusée : le fichier a pu changer depuis l'analyse",
        moduleType: "MODERATION",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        feature: "image_moderation_review",
        extra: { moderationId, fileUpdated: meta.updated ?? null, createdAtMs },
      });
      throw new HttpsError(
        "failed-precondition",
        "Le fichier a changé depuis son analyse. L'image repasse en attente : " +
          "relancez l'analyse avant de décider.",
      );
    }
    sourceGeneration = meta.generation;
  }

  let publishedUrl: string | null = null;
  let rejectedPath: string | null = null;
  if (decision === "approve") {
    const promoted = await promoteImage({
      quarantinePath: String(doc.quarantine_path ?? ""),
      targetPath: String(doc.target_path ?? ""),
      contentType: String(doc.mime_type ?? "image/jpeg"),
      moderationId,
      correlationId: ctx.correlationId,
      sourceGeneration,
    });
    publishedUrl = promoted.downloadUrl;
  } else {
    rejectedPath = await quarantineToRejected({
      quarantinePath: String(doc.quarantine_path ?? ""),
      moderationId,
      correlationId: ctx.correlationId,
      sourceGeneration: doc.quarantine_generation,
    });
  }

  await ref.update({
    status: decision === "approve" ? "approved" : "rejected",
    decision_reason: decision === "approve" ? "manual_approved" : "manual_rejected",
    published_url: publishedUrl,
    rejected_path: rejectedPath,
    reviewed_by: ctx.userId,
    reviewed_at: FieldValue.serverTimestamp(),
    review_note: note.length > 0 ? note : null,
  });

  await logInfo({
    message: `Décision d'administration : ${decision === "approve" ? "publiée" : "refusée"}`,
    moduleType: "MODERATION",
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    feature: "image_moderation_review",
    extra: { moderationId, note: note.length > 0 ? note : null },
  });

  return { status: decision === "approve" ? "approved" : "rejected", url: publishedUrl };
});

/**
 * Relance les images restées sans verdict.
 *
 * Un état qui ne se relance pas est une fuite : sans cette entrée, une panne de
 * moteur laisserait des images en attente pour toujours.
 */
export const retryPendingModerationFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAdmin(req, "image_moderation_retry");
  const config = await getModerationConfig();
  if (!config.enabled) {
    throw new HttpsError("failed-precondition", "La modération est désactivée.");
  }

  const db = getFirestore();
  const bucket = getStorage().bucket();
  const snap = await db.collection(COLLECTION).where("status", "==", "pending").limit(20).get();

  let relaunched = 0;
  let stillDown = 0;
  let unitsBilled = 0;
  let engineModel = "";

  for (const doc of snap.docs) {
    const data = doc.data() as Record<string, unknown>;
    const quarantinePath = String(data.quarantine_path ?? "");
    const file = bucket.file(quarantinePath);
    const [exists] = await file.exists();
    if (!exists) {
      // L'octet a disparu : l'attente n'a plus d'objet, et la laisser en
      // « pending » ferait grossir une file que personne ne peut vider.
      await doc.ref.update({
        status: "rejected",
        decision_reason: "engine_unavailable",
        review_note: "Fichier de quarantaine introuvable au moment de la relance.",
        reviewed_at: FieldValue.serverTimestamp(),
        reviewed_by: ctx.userId,
      });
      continue;
    }

    // Même épinglage qu'au premier passage : la version relancée est celle
    // qu'on promeut ou qu'on écarte.
    const [meta] = await file.getMetadata();
    const generation = pinnedGeneration(meta.generation);
    const [bytes] = await bucket
      .file(quarantinePath, generation != null ? { generation } : undefined)
      .download();
    try {
      const analysis = await analyseImage(bytes, config);
      engineModel = analysis.model;
      unitsBilled += analysis.units;
      const decision = decideModeration(analysis.signals, config.thresholds);
      let publishedUrl: string | null = null;
      let rejectedPath: string | null = null;
      if (decision.status === "approved") {
        const promoted = await promoteImage({
          quarantinePath,
          targetPath: String(data.target_path ?? ""),
          contentType: String(data.mime_type ?? "image/jpeg"),
          moderationId: doc.id,
          correlationId: ctx.correlationId,
          sourceGeneration: generation,
        });
        publishedUrl = promoted.downloadUrl;
      } else if (decision.status === "rejected") {
        rejectedPath = await quarantineToRejected({
          quarantinePath,
          moderationId: doc.id,
          correlationId: ctx.correlationId,
          sourceGeneration: generation,
        });
      }
      await doc.ref.update({
        quarantine_generation: generation != null ? String(generation) : null,
        status: decision.status,
        decision_reason: decision.reason,
        culinary_matches: decision.culinaryMatches,
        signals: {
          adult: analysis.signals.adult,
          racy: analysis.signals.racy,
          violence: analysis.signals.violence,
          medical: analysis.signals.medical,
          raw: analysis.signals.raw,
          labels: analysis.signals.labels,
        },
        engine: analysis.provider,
        engine_version: analysis.model,
        published_url: publishedUrl,
        rejected_path: rejectedPath,
        decided_at: FieldValue.serverTimestamp(),
      });
      relaunched += 1;
    } catch (err) {
      stillDown += 1;
      await logError({
        message: "Relance de modération : moteur toujours injoignable",
        moduleType: "MODERATION",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { moderationId: doc.id },
      });
    }
  }

  if (unitsBilled > 0) {
    await recordUsage({
      feature: MODERATION_FEATURE_BATCH,
      provider: "vision",
      model: engineModel,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      analyzedImageUnits: unitsBilled,
      entityType: "image_moderation_retry",
    });
  }

  await logInfo({
    message: `Relance de modération : ${relaunched} traitée(s), ${stillDown} en échec`,
    moduleType: "MODERATION",
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    feature: "image_moderation_retry",
    extra: { relaunched, stillDown, unitsBilled },
  });

  return { relaunched, stillDown };
});
