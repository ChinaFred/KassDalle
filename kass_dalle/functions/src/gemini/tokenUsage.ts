/**
 * Comptabilisation des appels d'image.
 *
 * Écrit dans Firestore `token_usage/{uid}` (compatible avec la collection
 * existante côté client) pour conserver les statistiques d'usage.
 *
 * La comptabilisation des appels de texte vivait ici sous `recordTokenUsage`,
 * qui écrivait `GEMINI_MODEL` et `provider: "gemini"` en dur. Depuis que tout
 * appel de texte passe par `callModel`, c'est `recordModelUsage` (`ai/router.ts`)
 * qui s'en charge, au tarif du modèle ayant réellement répondu. Ne restent ici
 * que les appels d'image, que Claude ne sert pas.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import type { GeminiResponse } from "./client";
import { COLL_TOKEN_USAGE, COLL_AI_USAGE } from "../config";
import { estimateAiCostUsd } from "../ai/pricing";

export interface AiUsageMeta {
  correlationId?: string;
  entityType?: string;
  entityId?: string;
  costBucket?: "production" | "backfill" | "rebuild" | "maintenance";
}

/**
 * Enregistre un appel d'amélioration d'image (gemini-2.5-flash-image).
 * Le coût est facturé à $0.04 par image générée, pas au token.
 * On stocke image_output_count: 1 pour que le billing estime le coût réel.
 */
export async function recordImageUsage(
  result: GeminiResponse,
  feature: string,
  userId?: string,
  meta?: AiUsageMeta,
): Promise<void> {
  const trimmedUserId = typeof userId === "string" ? userId.trim() : "";
  const effectiveUserId = trimmedUserId.length > 0 ? trimmedUserId : "system_unattributed";

  const usage = result.usageMetadata;
  const input = usage?.promptTokenCount ?? 0;
  const estimatedCostUsd = estimateAiCostUsd({
    model: "gemini-2.5-flash-image",
    inputTokens: input,
    outputTokens: 0,
    imageOutputCount: 1,
  });

  const db = getFirestore();

  // 1. Agrégat par utilisateur
  if (trimmedUserId.length > 0) {
    await db
      .collection(COLL_TOKEN_USAGE)
      .doc(trimmedUserId)
      .set(
        {
          updated_at: FieldValue.serverTimestamp(),
          [`features.${feature}.input`]: FieldValue.increment(input),
          [`features.${feature}.image_outputs`]: FieldValue.increment(1),
          [`features.${feature}.count`]: FieldValue.increment(1),
        },
        { merge: true },
      );
  }

  // 2. Log par appel dans ai_usage avec image_output_count
  await db.collection(COLL_AI_USAGE).add({
    uid: effectiveUserId,
    feature,
    input_tokens: input,
    output_tokens: 0,
    total_tokens: input,
    image_output_count: 1,
    model: "gemini-2.5-flash-image",
    provider: "gemini",
    estimated_cost_usd: estimatedCostUsd,
    cost_bucket: meta?.costBucket ?? "production",
    correlation_id: meta?.correlationId ?? null,
    entity_type: meta?.entityType ?? null,
    entity_id: meta?.entityId ?? null,
    timestamp: FieldValue.serverTimestamp(),
  });
}
