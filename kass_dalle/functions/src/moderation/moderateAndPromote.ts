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

import { logError, logInfo, logWarn } from "../logging";
import { BudgetExceededError, withDailyBudget } from "../ai/budget";
import { estimateAiCostUsd, loadAiPricingTable } from "../ai/pricing";
import { recordUsage } from "../ai/usage";
import { scanUpload } from "../utils/uploadSecurity";
import { decideModeration, type ModerationDecision } from "./decision";
import {
  MODERATION_FEATURE,
  MODERATION_FEATURE_BATCH,
  analyseImage,
  getModerationConfig,
  type EngineAnalysis,
} from "./engine";
import { VISION_MODEL_ID, VISION_UNITS_PER_IMAGE } from "./vision";
import { resolveImageOrigin, sha256Hex, type ImageOrigin } from "./origin";
import {
  assertTargetOwnership,
  attachApprovedIllustration,
  pinnedGeneration,
  quarantineToRejected,
  promoteImage,
  targetPathFor,
  type ModerationTargetKind,
} from "./promote";

const COLLECTION = "image_moderation";

/**
 * Origine d'une image (`./origin.ts`).
 *
 * Seules les images soumises par une personne sont analysées. Une image
 * produite par l'IA côté serveur sort d'un moteur qui applique déjà ses
 * garde-fous, et un asset livré avec l'application est le nôtre : les analyser
 * doublerait le coût pour rien. L'origine déclarée par un client n'est jamais
 * crue telle quelle : `asset` se vérifie sur l'empreinte du fichier, `ai` ne
 * vient que du serveur.
 */
export type { ImageOrigin };

export interface ModerationItem {
  quarantinePath: string;
  targetKind: ModerationTargetKind;
  ownerId: string | null;
  contentType: string;
  origin: ImageOrigin;
  /**
   * Ajouter l'image à `image_urls` de la recette (`recipe_illustration`) dès
   * qu'elle est approuvée, tout de suite ou plus tard. Posé par l'import d'une
   * recette depuis un lien seulement — voir `attachApprovedIllustration`.
   */
  attachOnApproval?: boolean;
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
 * Coût d'une analyse Cloud Vision, en dollars, lu dans la grille tarifaire :
 * ses unités fois le prix de l'unité. `null` si la grille est illisible — la
 * réservation retombe alors sur la moyenne du jour, et le plafond d'appels
 * tient seul. Aucun prix n'est écrit dans le code.
 */
export async function visionAnalysisCostUsd(): Promise<number | null> {
  try {
    return estimateAiCostUsd({
      model: VISION_MODEL_ID,
      inputTokens: 0,
      outputTokens: 0,
      analyzedImageUnits: VISION_UNITS_PER_IMAGE,
      table: await loadAiPricingTable(),
    });
  } catch (err) {
    await logWarn({
      message: "Modération : coût d'une analyse inconnu, réservation à la moyenne du jour",
      moduleType: "MODERATION",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return null;
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
  /** Rôle administrateur de l'appelant, consulté seulement hors propriété. */
  isAdmin: (uid: string) => Promise<boolean>;
}): Promise<{ results: ItemOutcome[] }> {
  const { items, userId, correlationId } = args;
  const feature = items.length > 1 ? MODERATION_FEATURE_BATCH : MODERATION_FEATURE;

  // Propriété d'abord, pour tout le lot : aucune analyse facturée, aucune
  // image publiée, si une seule destination appartient à un autre.
  for (const item of items) {
    await assertTargetOwnership({
      kind: item.targetKind,
      ownerId: item.ownerId,
      callerUid: userId,
      isAdmin: args.isAdmin,
    });
  }

  const config = await getModerationConfig();
  const db = getFirestore();
  const bucket = getStorage().bucket();
  const outcomes: ItemOutcome[] = [];
  let unitsBilled = 0;
  let imagesAnalysed = 0;
  let engineModel = "moderation-disabled";
  let engineFailed = false;
  // Lu une fois par lot, au premier besoin : une image sans analyse (asset,
  // image de l'IA, modération coupée) ne lit pas la grille.
  let analysisCostUsd: number | null | undefined;

  // Le lot s'arrête à la première erreur (format, fichier absent, plafond
  // atteint). Les analyses déjà faites sont facturées : `finally` les
  // enregistre quand même, sans quoi elles sortaient du reporting et du
  // plafond du jour.
  try {
    for (const item of items) {
      const docRef = db.collection(COLLECTION).doc();
      const file = bucket.file(item.quarantinePath);

      const [exists] = await file.exists();
      if (!exists) {
        throw new QuarantineFileMissing(item.quarantinePath);
      }
      const [meta] = await file.getMetadata();
      // La version analysée est celle qu'on promouvra : téléchargement, copie
      // et refus portent tous sur cette génération (`pinnedGeneration`).
      const generation = pinnedGeneration(meta.generation);
      const [bytes] = await bucket
        .file(item.quarantinePath, generation != null ? { generation } : undefined)
        .download();

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

      // L'origine retenue, pas celle déclarée : un `asset` dont l'empreinte
      // n'est pas celle d'une image livrée redevient une image d'utilisateur.
      const { origin, downgraded } = resolveImageOrigin(item.origin, sha256Hex(bytes));
      if (downgraded) {
        await logWarn({
          message: "Image déclarée « asset » sans empreinte connue — analysée comme une autre",
          moduleType: "MODERATION",
          userId,
          correlationId,
          extra: { quarantinePath: item.quarantinePath, targetKind: item.targetKind },
        });
      }

      let decision: ModerationDecision;
      let signals: Record<string, unknown> = {};
      let provider = config.provider;

      if (origin !== "user") {
        // Ni analysée, ni facturée — mais journalisée, et à son motif propre.
        decision = {
          status: "approved",
          reason: origin === "ai" ? "ai_generated" : "bundled_asset",
          culinaryMatches: [],
        };
      } else if (!config.enabled) {
        // Modération coupée : on publie, et on le dit. Approuver en prétendant
        // qu'aucun signal n'a été vu ferait mentir le journal.
        decision = { status: "approved", reason: "moderation_disabled", culinaryMatches: [] };
      } else {
        // Plafond quotidien du compte, réservé avant l'analyse : chaque image
        // analysée est facturée par Cloud Vision. Sans cette réservation, un
        // compte qui rappelait la fonction en boucle sur sa quarantaine
        // déclenchait des analyses sans limite. Un refus remonte à l'appelant
        // (`BudgetExceededError`) : ce n'est pas une panne du moteur, l'image
        // ne passe pas en attente.
        if (analysisCostUsd === undefined) analysisCostUsd = await visionAnalysisCostUsd();
        const estimateUsd = analysisCostUsd;
        let analysis: EngineAnalysis | null = null;
        try {
          analysis = await withDailyBudget(userId, feature, () => analyseImage(bytes, config), {
            estimateUsd,
          });
        } catch (err) {
          if (err instanceof BudgetExceededError) throw err;
          // Pas de repli : publier par défaut, c'est modérer pour rien ; refuser
          // par défaut, c'est accuser à tort. L'image attend.
          engineFailed = true;
          await logError({
            message: "Moteur de modération injoignable — image laissée en attente",
            moduleType: "MODERATION",
            userId,
            correlationId,
            errorDescription: err instanceof Error ? err.message : String(err),
            extra: { quarantinePath: item.quarantinePath, provider: config.provider },
          });
        }
        if (analysis == null) {
          decision = { status: "pending", reason: "engine_unavailable", culinaryMatches: [] };
        } else {
          engineModel = analysis.model;
          provider = analysis.provider;
          unitsBilled += analysis.units;
          imagesAnalysed += 1;
          signals = {
            adult: analysis.signals.adult,
            racy: analysis.signals.racy,
            violence: analysis.signals.violence,
            medical: analysis.signals.medical,
            raw: analysis.signals.raw,
            labels: analysis.signals.labels,
          };
          decision = decideModeration(analysis.signals, config.thresholds);
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
          sourceGeneration: generation,
        });
        publishedUrl = promoted.downloadUrl;
      } else if (decision.status === "rejected") {
        // Conservée, pas détruite : un refus qu'on ne peut pas relire ne peut pas
        // être jugé, et ce sont les faux refus qu'il faut le plus pouvoir voir.
        rejectedPath = await quarantineToRejected({
          quarantinePath: item.quarantinePath,
          moderationId: docRef.id,
          correlationId,
          sourceGeneration: generation,
        });
      }

      await docRef.set({
        status: decision.status,
        uid: userId,
        quarantine_path: item.quarantinePath,
        // La version analysée : une décision d'administrateur promeut celle-ci,
        // pas un fichier réécrit depuis dans la quarantaine.
        quarantine_generation: generation != null ? String(generation) : null,
        target_path: targetPath,
        target_kind: item.targetKind,
        owner_id: item.ownerId,
        mime_type: meta.contentType ?? item.contentType,
        size_bytes: bytes.length,
        signals,
        culinary_matches: decision.culinaryMatches,
        engine: origin !== "user" ? "none" : config.enabled ? provider : "none",
        engine_version: engineModel,
        decision_reason: decision.reason,
        correlation_id: correlationId,
        published_url: publishedUrl,
        rejected_path: rejectedPath,
        attach_on_approval: item.attachOnApproval === true,
        created_at: FieldValue.serverTimestamp(),
        decided_at: FieldValue.serverTimestamp(),
        reviewed_by: null,
        reviewed_at: null,
        review_note: null,
      });

      await attachApprovedIllustration({
        attachOnApproval: item.attachOnApproval === true,
        targetKind: item.targetKind,
        ownerId: item.ownerId,
        url: publishedUrl,
        correlationId,
        moderationId: docRef.id,
      });

      outcomes.push({
        moderationId: docRef.id,
        status: decision.status,
        reason: decision.reason,
        url: publishedUrl,
      });
    }
  } finally {
    // Une analyse facturée est enregistrée même si le verdict a été négatif :
    // le fournisseur l'a servie et la facture. Un appel dont le moteur est
    // tombé ne consomme rien, mais reste visible avec le statut `error`.
    // Chaque image analysée compte pour un appel au plafond du jour.
    if (unitsBilled > 0 || engineFailed) {
      try {
        await recordUsage({
          feature,
          provider: "vision",
          model: engineModel,
          userId,
          correlationId,
          analyzedImageUnits: unitsBilled,
          dailyCalls: Math.max(1, imagesAnalysed),
          entityType: "image_moderation",
          status: engineFailed ? "error" : "ok",
        });
      } catch (err) {
        // Best-effort : l'analyse est faite et facturée, la perdre ici
        // fausserait le reporting d'autant. Visible, sans masquer l'erreur
        // d'origine du lot s'il y en a une.
        await logError({
          message: "Modération : consommation Cloud Vision non enregistrée",
          moduleType: "MODERATION",
          userId,
          correlationId,
          feature,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { unitsBilled, imagesAnalysed },
        });
      }
    }
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
