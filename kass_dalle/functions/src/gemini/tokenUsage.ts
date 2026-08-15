/**
 * Comptabilisation des appels d'image.
 *
 * L'écriture elle-même vit dans `ai/usage.ts`, partagée par tous les types
 * d'appel. Ce fichier ne garde que la traduction d'une réponse Gemini Image en
 * entrée de consommation : le modèle facture à l'image produite, pas au jeton,
 * et c'est la seule particularité qui subsiste.
 *
 * Historique : `recordTokenUsage` vivait ici et écrivait `GEMINI_MODEL` et
 * `provider: "gemini"` en dur pour tous les appels de texte. Il a été remplacé
 * par le routeur, qui facture au modèle ayant réellement répondu.
 */

import type { GeminiResponse } from "./client";
import { recordUsage } from "../ai/usage";
import { GEMINI_IMAGE_MODEL } from "../config";

export interface AiUsageMeta {
  correlationId?: string;
  entityType?: string;
  entityId?: string;
  costBucket?: "production" | "backfill" | "rebuild" | "maintenance";
}

/**
 * Enregistre une image produite par [GEMINI_IMAGE_MODEL].
 *
 * Le coût ne se déduit pas des jetons : il est fixé par image. Les jetons
 * d'entrée sont tout de même conservés — ils existent, ils sont facturés, et
 * les ignorer sous-estimait le poste de quelques centimes par appel.
 */
export async function recordImageUsage(
  result: GeminiResponse,
  feature: string,
  userId?: string,
  meta?: AiUsageMeta,
): Promise<void> {
  await recordUsage({
    feature,
    provider: "gemini",
    model: GEMINI_IMAGE_MODEL,
    userId,
    correlationId: meta?.correlationId ?? null,
    inputTokens: result.usageMetadata?.promptTokenCount ?? 0,
    outputTokens: 0,
    imageOutputCount: 1,
    entityType: meta?.entityType,
    entityId: meta?.entityId,
    costBucket: meta?.costBucket,
  });
}
