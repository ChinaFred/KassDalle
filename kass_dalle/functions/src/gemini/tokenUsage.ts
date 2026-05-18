/**
 * Helpers de tracking des tokens Gemini consommés.
 *
 * Écrit dans Firestore `token_usage/{uid}` (compatible avec la collection
 * existante côté client) pour conserver les statistiques d'usage.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import type { GenerateContentResult } from "@google/generative-ai";
import { COLL_TOKEN_USAGE } from "../config";

export interface TokenUsageLog {
  feature: string;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
  userId?: string;
}

/**
 * Extrait l'usage tokens depuis une réponse Gemini et l'écrit dans Firestore.
 *
 * Aligné sur le schéma utilisé par TokenUsageRepository côté Dart :
 *   token_usage/{uid} = {
 *     total_tokens: number,
 *     features: { [feature]: { input, output, total, count } }
 *   }
 */
export async function recordTokenUsage(
  result: GenerateContentResult,
  feature: string,
  userId?: string,
): Promise<void> {
  const usage = result.response.usageMetadata;
  if (!usage || !userId) return;

  const input = usage.promptTokenCount ?? 0;
  const output = usage.candidatesTokenCount ?? 0;
  const total = usage.totalTokenCount ?? input + output;

  if (total === 0) return;

  const db = getFirestore();
  await db
    .collection(COLL_TOKEN_USAGE)
    .doc(userId)
    .set(
      {
        total_tokens: FieldValue.increment(total),
        updated_at: FieldValue.serverTimestamp(),
        [`features.${feature}.input`]: FieldValue.increment(input),
        [`features.${feature}.output`]: FieldValue.increment(output),
        [`features.${feature}.total`]: FieldValue.increment(total),
        [`features.${feature}.count`]: FieldValue.increment(1),
      },
      { merge: true },
    );
}
