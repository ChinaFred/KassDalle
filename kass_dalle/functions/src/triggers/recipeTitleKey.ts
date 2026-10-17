/**
 * Clé de titre d'une recette — ce que la détection des doublons compare.
 *
 * `recipeProcessor` la pose à la création d'un brouillon importé. Le client,
 * lui, écrit des recettes sans elle (saisie, copie, correction du titre à la
 * relecture) : `onRecipeWritten` la recalcule donc à chaque écriture dont le
 * titre ne correspond plus à la clé. Les recettes antérieures la reçoivent par
 * le backfill « Clé de titre des recettes ».
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_RECIPES } from "../config";
import { logError } from "../logging";
import { titleKey } from "../pipeline/duplicateDetection";

/** La clé que la recette devrait porter, ou `null` si elle la porte déjà. */
export function titleKeyUpdate(data: Record<string, unknown>): string | null {
  const expected = titleKey(typeof data.titre === "string" ? data.titre : "");
  return data.titre_key === expected ? null : expected;
}

/** Aligne `titre_key` sur le titre. Best-effort, jamais silencieux. */
export async function syncRecipeTitleKey(args: {
  recipeId: string;
  data: Record<string, unknown>;
  correlationId: string;
  scanId?: string;
}): Promise<boolean> {
  const expected = titleKeyUpdate(args.data);
  if (expected == null) return false;
  try {
    await getFirestore()
      .collection(COLL_RECIPES)
      .doc(args.recipeId)
      .update({ titre_key: expected });
    return true;
  } catch (error) {
    // La recette garde une clé périmée : un doublon de son titre ne sera pas
    // détecté tant que le backfill ne l'a pas reprise.
    await logError({
      message: "syncRecipeTitleKey : clé de titre non écrite",
      errorDescription: error instanceof Error ? error.message : String(error),
      moduleType: "DESIGN",
      correlationId: args.correlationId,
      scanId: args.scanId,
      extra: { recipeId: args.recipeId },
    });
    return false;
  }
}
