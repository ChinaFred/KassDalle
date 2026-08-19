/**
 * Le chemin d'une image vers sa publication : quarantaine → verdict → promotion.
 *
 * Ce module est le **seul** à décider si une image devient visible. Il vivait
 * dans le callable, où seul un client pouvait l'emprunter ; le pipeline
 * d'import, lui, écrivait ses découpes en direct avec l'Admin SDK — donc hors
 * quarantaine, hors modération, alors que ce sont des photographies choisies
 * par une personne, exactement ce que la modération existe pour regarder.
 *
 * L'extraire ici est ce qui permet aux deux appelants d'emprunter le même
 * chemin plutôt que d'en avoir chacun un. Un second chemin de publication
 * serait, tôt ou tard, un chemin sans verdict.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { logError, logInfo } from "../logging";
import { recordUsage } from "../ai/usage";
import { scanUpload } from "../utils/uploadSecurity";
import { decideModeration, type ModerationDecision } from "./decision";
import {
  MODERATION_FEATURE,
  MODERATION_FEATURE_BATCH,
  analyseImage,
  getModerationConfig,
} from "./engine";
import {
  quarantineToRejected,
  promoteImage,
  targetPathFor,
  type ModerationTargetKind,
} from "./promote";

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
export type ImageOrigin = "user" | "ai" | "asset";

export interface ModerationItem {
  quarantinePath: string;
  targetKind: ModerationTargetKind;
  ownerId: string | null;
  contentType: string;
  origin: ImageOrigin;
}

export interface ItemOutcome {
  moderationId: string;
  status: string;
  reason: string;
  url: string | null;
}

/**
 * Fichier refusé par le scan de format, avant toute analyse.
 *
 * Ce refus n'est pas une décision de modération — il ne crée donc aucune ligne
 * de journal. C'est une erreur typée, et non un `HttpsError`, parce que les
 * deux appelants n'en font pas la même chose : le callable la rend au client,
 * le pipeline écarte la découpe et poursuit l'import.
 */
export class ImageFormatRejected extends Error {
  constructor(
    readonly quarantinePath: string,
    readonly detail: string,
  ) {
    super(detail);
    this.name = "ImageFormatRejected";
  }
}

/** Fichier absent de la quarantaine au moment de l'analyse. */
export class QuarantineFileMissing extends Error {
  constructor(readonly quarantinePath: string) {
    super(`Fichier en quarantaine introuvable : ${quarantinePath}`);
    this.name = "QuarantineFileMissing";
  }
}

/**
 * Analyse et publie un lot d'images déjà déposées en quarantaine.
 *
 * Un lot est un poste de coût à part (`image_moderation_batch`) : le distinguer
 * de sa version unitaire est le seul moyen de vérifier que le groupage fait son
 * office.
 */
export async function moderateAndPromote(args: {
  items: ModerationItem[];
  userId: string;
  correlationId: string;
}): Promise<{ results: ItemOutcome[] }> {
  const { items, userId, correlationId } = args;
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
      throw new QuarantineFileMissing(item.quarantinePath);
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
        userId,
        correlationId,
        extra: { quarantinePath: item.quarantinePath, reason: formatScan.reason },
      });
      throw new ImageFormatRejected(
        item.quarantinePath,
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
          adult: analysis.signals.adult,
          racy: analysis.signals.racy,
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
          userId,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { quarantinePath: item.quarantinePath, provider: config.provider },
        });
      }
    }

    const targetPath = targetPathFor({
      kind: item.targetKind,
      uid: userId,
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
        correlationId,
      });
      publishedUrl = promoted.downloadUrl;
    } else if (decision.status === "rejected") {
      // Conservée, pas détruite : un refus qu'on ne peut pas relire ne peut pas
      // être jugé, et ce sont les faux refus qu'il faut le plus pouvoir voir.
      rejectedPath = await quarantineToRejected({
        quarantinePath: item.quarantinePath,
        moderationId: docRef.id,
        correlationId,
      });
    }

    await docRef.set({
      status: decision.status,
      uid: userId,
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
      correlation_id: correlationId,
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
      userId,
      correlationId,
      analyzedImageUnits: unitsBilled,
      entityType: "image_moderation",
      status: engineFailed ? "error" : "ok",
    });
  }

  await logInfo({
    message: `Modération de ${items.length} image(s)`,
    moduleType: "MODERATION",
    userId,
    correlationId,
    feature,
    extra: {
      results: outcomes.map((o) => ({ status: o.status, reason: o.reason })),
      unitsBilled,
      engine: config.enabled ? config.provider : "none",
    },
  });

  return { results: outcomes };
}
