/**
 * Nutrition annoncée par le site d'une recette importée, et son écart avec le
 * calcul du serveur.
 *
 * Une page `schema.org/Recipe` publie souvent ses valeurs par portion
 * (`NutritionInformation`). L'import par lien les garde sur la recette
 * (`source_nutrition`), avec l'empreinte des ingrédients écrits. Chaque calcul
 * de la nutrition (`computeAndPersistRecipeNutrition`) compare ensuite ses
 * valeurs par portion à celles du site et écrit le résultat dans
 * `source_nutrition_check`. Un écart au-delà de `SOURCE_GAP_FACTOR` est
 * journalisé : il désigne une conversion d'unité fausse, un ingrédient
 * manquant ou un `per100g` aberrant du référentiel.
 *
 * Le site calcule avec ses propres bases : un écart de 20 à 30 % est normal et
 * n'est pas signalé. Une recette dont les ingrédients ont changé depuis
 * l'import ne se compare plus.
 *
 * Serveur seul. Rien ici n'entre dans un prompt ni ne s'affiche.
 */

import type { JsonLdNutrition } from "../web/recipePage";
import { ingredientsFingerprint, type StoredIngredient } from "../triggers/recipeIngredients";

/** Écart, dans un sens ou dans l'autre, à partir duquel une valeur est signalée. */
export const SOURCE_GAP_FACTOR = 2;

/** Les valeurs comparées, dans l'ordre où elles sont rapportées. */
export const SOURCE_NUTRIENT_KEYS = ["kcal", "protein_g", "carbs_g", "fat_g"] as const;

/** Le champ `source_nutrition` écrit à l'import. */
export function sourceNutritionDocument(args: {
  perPortion: JsonLdNutrition;
  portions: number | null;
  ingredients: StoredIngredient[];
}): Record<string, unknown> {
  const perPortion: Record<string, number> = {};
  for (const key of SOURCE_NUTRIENT_KEYS) {
    const value = args.perPortion[key];
    if (value != null) perPortion[key] = value;
  }
  return {
    per_portion: perPortion,
    portions: args.portions,
    ingredients_fingerprint: ingredientsFingerprint(args.ingredients),
  };
}

/** Résultat d'une comparaison, tel qu'il est écrit dans `source_nutrition_check`. */
export type SourceNutritionCheck =
  | { state: "ingredients_changed" }
  | { state: "low_coverage"; coverage: number }
  | {
      state: "ok" | "gap";
      /** Portions qui divisent nos totaux : celles du site, sinon celles de la recette. */
      portions: number;
      /** Notre valeur par portion divisée par celle du site, arrondie au centième. */
      ratios: Record<string, number>;
      /** Valeurs hors de [1 / SOURCE_GAP_FACTOR, SOURCE_GAP_FACTOR]. */
      gaps: string[];
    };

/**
 * Compare nos totaux à la nutrition du site. `null` quand la recette ne porte
 * pas de `source_nutrition` lisible.
 *
 * `canShowPartial` vient du calcul : sous ce seuil de couverture, nos totaux
 * manquent d'ingrédients et un écart ne prouve rien.
 */
export function compareWithSourceNutrition(args: {
  sourceNutrition: unknown;
  ingredients: StoredIngredient[];
  totals: Record<string, number>;
  recipePortions: number;
  coverage: number;
  canShowPartial: boolean;
}): SourceNutritionCheck | null {
  const source = args.sourceNutrition;
  if (!source || typeof source !== "object") return null;
  const record = source as Record<string, unknown>;
  const perPortion = record.per_portion;
  if (!perPortion || typeof perPortion !== "object") return null;

  if (record.ingredients_fingerprint !== ingredientsFingerprint(args.ingredients)) {
    return { state: "ingredients_changed" };
  }
  if (!args.canShowPartial) {
    return { state: "low_coverage", coverage: Math.round(args.coverage * 100) / 100 };
  }

  const sitePortions =
    typeof record.portions === "number" && Number.isFinite(record.portions) && record.portions > 0
      ? record.portions
      : null;
  const portions = sitePortions ?? args.recipePortions;
  const ratios: Record<string, number> = {};
  const gaps: string[] = [];
  for (const key of SOURCE_NUTRIENT_KEYS) {
    const site = (perPortion as Record<string, unknown>)[key];
    if (typeof site !== "number" || !Number.isFinite(site) || site <= 0) continue;
    const ours = (args.totals[key] ?? 0) / portions;
    const ratio = Math.round((ours / site) * 100) / 100;
    ratios[key] = ratio;
    if (ratio > SOURCE_GAP_FACTOR || ratio < 1 / SOURCE_GAP_FACTOR) gaps.push(key);
  }
  if (Object.keys(ratios).length === 0) return null;
  return { state: gaps.length > 0 ? "gap" : "ok", portions, ratios, gaps };
}
