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
import { requireAdmin, requireAuth } from "./_auth";
import { logError, logInfo } from "../logging";
import { recordUsage } from "../ai/usage";
import { scanUpload } from "../utils/uploadSecurity";
import { decideModeration, type ModerationDecision } from "../moderation/decision";
import {
  MODERATION_FEATURE,
  MODERATION_FEATURE_BATCH,
  analyseImage,
  getModerationConfig,
} from "../moderation/engine";
import {
  quarantineToRejected,
  isTargetKind,
  promoteImage,
  targetPathFor,
  type ModerationTargetKind,
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
 * Origine d'une image.
 *
 * Seules les images soumises par une personne sont analysées. Une image
 * produite par l'IA sort d'un moteur qui applique déjà ses garde-fous, et un
 * asset livré avec l'application est le nôtre : les analyser doublerait le coût
 * pour rien. Elles passent par le même chemin — c'est ce qui permet de fermer
 * les dossiers publiés en écriture — et le journal dit pourquoi elles sont
 * passées.
 */
type ImageOrigin = "user" | "ai" | "asset";

interface ModerationItem {
  quarantinePath: string;
  targetKind: ModerationTargetKind;
  ownerId: string | null;
  contentType: string;
  origin: ImageOrigin;
}

interface ItemOutcome {
  moderationId: string;
  status: string;
  reason: string;
  url: string | null;
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
      ownerId: typeof item.ownerId === "string" && item.ownerId.length > 0 ? item.ownerId : null,
      contentType: typeof item.contentType === "string" ? item.contentType : "image/jpeg",
      origin: item.origin === "ai" ? "ai" : item.origin === "asset" ? "asset" : "user",
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
  const feature = items.length > 1 ? MODERATION_FEATURE_BATCH : MODERATION_FEATURE;

  const config = await getModerationConfig();
  const db = getFirestore();
  const bucket = getStorage().bucket();
  const outcomes: ItemOutcome[] = [];
  let unitsBilled = 0;
  let engineModel = "moderation-disabled";
  let engineFailed = false;

  for (const item of items) {
    const docRef = db.collection(COLLECTION).doc();
    const file = bucket.file(item.quarantinePath);

    const [exists] = await file.exists();
    if (!exists) {
      throw new HttpsError("not-found", "Fichier en quarantaine introuvable.");
    }
    const [meta] = await file.getMetadata();
    const [bytes] = await file.download();

    // Le format d'abord : inutile d'envoyer un exécutable renommé à un moteur
    // d'analyse d'images. Ce refus-là n'est pas une décision de modération, il
    // ne crée donc pas de ligne de journal — il rejette l'appel.
    const fileName = item.quarantinePath.split("/").pop() ?? "upload";
    const formatScan = scanUpload({ fileName, mimeType: meta.contentType, bytes });
    if (!formatScan.clean) {
      await logError({
        message: "Image bloquée par le scan de format avant modération",
        moduleType: "MODERATION",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        extra: { quarantinePath: item.quarantinePath, reason: formatScan.reason },
      });
      throw new HttpsError(
        "failed-precondition",
        formatScan.reason ?? "Le fichier a été bloqué par le scan de sécurité.",
      );
    }

    let decision: ModerationDecision;
    let signals: Record<string, unknown> = {};
    let provider = config.provider;

    if (item.origin !== "user") {
      // Ni analysée, ni facturée — mais journalisée, et à son motif propre.
      decision = {
        status: "approved",
        reason: item.origin === "ai" ? "ai_generated" : "bundled_asset",
        culinaryMatches: [],
      };
    } else if (!config.enabled) {
      // Modération coupée : on publie, et on le dit. Approuver en prétendant
      // qu'aucun signal n'a été vu ferait mentir le journal.
      decision = { status: "approved", reason: "moderation_disabled", culinaryMatches: [] };
    } else {
      try {
        const analysis = await analyseImage(bytes, config);
        engineModel = analysis.model;
        provider = analysis.provider;
        unitsBilled += analysis.units;
        signals = {
          sexual: analysis.signals.sexual,
          violence: analysis.signals.violence,
          medical: analysis.signals.medical,
          raw: analysis.signals.raw,
          labels: analysis.signals.labels,
        };
        decision = decideModeration(analysis.signals, config.thresholds);
      } catch (err) {
        // Pas de repli : publier par défaut, c'est modérer pour rien ; refuser
        // par défaut, c'est accuser à tort. L'image attend.
        engineFailed = true;
        decision = { status: "pending", reason: "engine_unavailable", culinaryMatches: [] };
        await logError({
          message: "Moteur de modération injoignable — image laissée en attente",
          moduleType: "MODERATION",
          userId: ctx.userId,
          correlationId: ctx.correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { quarantinePath: item.quarantinePath, provider: config.provider },
        });
      }
    }

    const targetPath = targetPathFor({
      kind: item.targetKind,
      uid: ctx.userId,
      ownerId: item.ownerId,
      quarantinePath: item.quarantinePath,
      timestampMs: Date.now(),
    });

    let publishedUrl: string | null = null;
    let rejectedPath: string | null = null;
    if (decision.status === "approved") {
      const promoted = await promoteImage({
        quarantinePath: item.quarantinePath,
        targetPath,
        contentType: item.contentType,
        moderationId: docRef.id,
        correlationId: ctx.correlationId,
      });
      publishedUrl = promoted.downloadUrl;
    } else if (decision.status === "rejected") {
      // Conservée, pas détruite : un refus qu'on ne peut pas relire ne peut pas
      // être jugé, et ce sont les faux refus qu'il faut le plus pouvoir voir.
      rejectedPath = await quarantineToRejected({
        quarantinePath: item.quarantinePath,
        moderationId: docRef.id,
        correlationId: ctx.correlationId,
      });
    }

    await docRef.set({
      status: decision.status,
      uid: ctx.userId,
      quarantine_path: item.quarantinePath,
      target_path: targetPath,
      target_kind: item.targetKind,
      owner_id: item.ownerId,
      mime_type: meta.contentType ?? item.contentType,
      size_bytes: bytes.length,
      signals,
      culinary_matches: decision.culinaryMatches,
      engine: item.origin !== "user" ? "none" : config.enabled ? provider : "none",
      engine_version: engineModel,
      decision_reason: decision.reason,
      correlation_id: ctx.correlationId,
      published_url: publishedUrl,
      rejected_path: rejectedPath,
      created_at: FieldValue.serverTimestamp(),
      decided_at: FieldValue.serverTimestamp(),
      reviewed_by: null,
      reviewed_at: null,
      review_note: null,
    });

    outcomes.push({
      moderationId: docRef.id,
      status: decision.status,
      reason: decision.reason,
      url: publishedUrl,
    });
  }

  // Une analyse facturée est enregistrée même si le verdict a été négatif : le
  // fournisseur l'a servie et la facture. Un appel dont le moteur est tombé ne
  // consomme rien, mais reste visible avec le statut `error`.
  if (unitsBilled > 0 || engineFailed) {
    await recordUsage({
      feature,
      provider: "vision",
      model: engineModel,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      analyzedImageUnits: unitsBilled,
      entityType: "image_moderation",
      status: engineFailed ? "error" : "ok",
    });
  }

  await logInfo({
    message: `Modération de ${items.length} image(s)`,
    moduleType: "MODERATION",
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    feature,
    extra: {
      results: outcomes.map((o) => ({ status: o.status, reason: o.reason })),
      unitsBilled,
      engine: config.enabled ? config.provider : "none",
    },
  });

  return { results: outcomes };
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

  let publishedUrl: string | null = null;
  let rejectedPath: string | null = null;
  if (decision === "approve") {
    const promoted = await promoteImage({
      quarantinePath: String(doc.quarantine_path ?? ""),
      targetPath: String(doc.target_path ?? ""),
      contentType: String(doc.mime_type ?? "image/jpeg"),
      moderationId,
      correlationId: ctx.correlationId,
    });
    publishedUrl = promoted.downloadUrl;
  } else {
    rejectedPath = await quarantineToRejected({
      quarantinePath: String(doc.quarantine_path ?? ""),
      moderationId,
      correlationId: ctx.correlationId,
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

    const [bytes] = await file.download();
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
        });
        publishedUrl = promoted.downloadUrl;
      } else if (decision.status === "rejected") {
        rejectedPath = await quarantineToRejected({
          quarantinePath,
          moderationId: doc.id,
          correlationId: ctx.correlationId,
        });
      }
      await doc.ref.update({
        status: decision.status,
        decision_reason: decision.reason,
        culinary_matches: decision.culinaryMatches,
        signals: {
          sexual: analysis.signals.sexual,
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
