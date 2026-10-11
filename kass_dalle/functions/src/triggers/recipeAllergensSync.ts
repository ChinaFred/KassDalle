/**
 * Allergènes d'une recette, déduits du référentiel à l'écriture.
 *
 * Aucun appel de modèle ici. Les ingrédients sont examinés par la chaîne
 * nutrition (`syncRecipeNutrition`, poste `allergens_auto`), juste après
 * qu'elle a créé leur document dans le référentiel ; ce module ne fait que
 * l'union, et l'écrit sur la recette.
 *
 * Deux moments, décidés par `onRecipeWritten` :
 *  - les ingrédients ont changé (ou la recette naît) : après la nutrition,
 *    une fois les ingrédients neufs examinés ;
 *  - le champ manque et aucune entrée n'a changé (recette antérieure au
 *    champ, ou écho d'une écriture du déclencheur pendant un calcul en
 *    cours) : tout de suite, avec ce que le référentiel sait déjà. Sans appel
 *    de modèle dans ce cas : un écho n'a pas à facturer une seconde fois les
 *    ingrédients que le premier passage est en train d'examiner. Ce qui reste
 *    non examiné rend le résultat incomplet, et le backfill « Allergènes des
 *    ingrédients » le complète.
 *
 * Pas de boucle : `allergens` n'est pas une entrée du déclencheur
 * (`recipeTriggerInputsFingerprint`), et son écho trouve le champ présent.
 */

import { recipeBudgetUserId } from "../ai/budget";
import { logError } from "../logging";
import { writeRecipeAllergens } from "../nutrition/allergenExamination";
import type { DocumentReference } from "firebase-admin/firestore";

/** Vrai quand la recette ne porte pas encore de champ `allergens` exploitable. */
export function recipeAllergensMissing(data: Record<string, unknown> | undefined): boolean {
  const value = data?.allergens;
  return !value || typeof value !== "object" || Array.isArray(value);
}

/** Recalcule et écrit `allergens`. Ne lève jamais : l'échec est journalisé. */
export async function syncRecipeAllergens(args: {
  recipeRef: DocumentReference;
  data: Record<string, unknown>;
  correlationId: string;
  scanId?: string;
}): Promise<void> {
  const { recipeRef, data, correlationId, scanId } = args;
  try {
    await writeRecipeAllergens(recipeRef);
  } catch (err) {
    await logError({
      message: "syncRecipeAllergens: allergènes de la recette non écrits",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId,
      scanId,
      userId: recipeBudgetUserId(data.created_by),
      feature: "allergens_auto",
      extra: { recipeId: recipeRef.id },
    });
  }
}
