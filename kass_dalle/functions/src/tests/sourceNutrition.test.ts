/**
 * Nutrition annoncée par le site d'une recette importée : document écrit à
 * l'import, et comparaison avec le calcul du serveur.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { compareWithSourceNutrition, sourceNutritionDocument } from "../nutrition/sourceNutrition";

const ingredients = [
  { name: "lardons", qty: "200", unit: "g" },
  { name: "œufs", qty: "3", unit: "" },
];

const source = sourceNutritionDocument({
  perPortion: { kcal: 400, protein_g: 20, carbs_g: null, fat_g: 30 },
  portions: 4,
  ingredients,
});

function compare(overrides: Partial<Parameters<typeof compareWithSourceNutrition>[0]> = {}) {
  return compareWithSourceNutrition({
    sourceNutrition: source,
    ingredients,
    totals: { kcal: 1800, protein_g: 70, fat_g: 130 },
    recipePortions: 6,
    coverage: 1,
    canShowPartial: true,
    ...overrides,
  });
}

describe("source_nutrition", () => {
  test("valeurs présentes seules, portions du site, empreinte des ingrédients", () => {
    assert.deepEqual(source.per_portion, { kcal: 400, protein_g: 20, fat_g: 30 });
    assert.equal(source.portions, 4);
    assert.equal(source.ingredients_fingerprint, "lardons|200|g;œufs|3|");
  });
});

describe("comparaison", () => {
  test("écart modéré : ok, nos totaux divisés par les portions du site", () => {
    assert.deepEqual(compare(), {
      state: "ok",
      portions: 4,
      ratios: { kcal: 1.13, protein_g: 0.88, fat_g: 1.08 },
      gaps: [],
    });
  });

  test("facteur 2 dépassé : gap, la valeur nommée", () => {
    const check = compare({ totals: { kcal: 18_000, protein_g: 70, fat_g: 130 } });
    assert.equal(check?.state, "gap");
    assert.deepEqual(check && "gaps" in check ? check.gaps : null, ["kcal"]);
    const low = compare({ totals: { kcal: 1800, protein_g: 30, fat_g: 130 } });
    assert.deepEqual(low && "gaps" in low ? low.gaps : null, ["protein_g"]);
  });

  test("sans portions du site, celles de la recette", () => {
    const check = compareWithSourceNutrition({
      sourceNutrition: { ...source, portions: null },
      ingredients,
      totals: { kcal: 2400, protein_g: 120, fat_g: 180 },
      recipePortions: 6,
      coverage: 1,
      canShowPartial: true,
    });
    assert.deepEqual(check, {
      state: "ok",
      portions: 6,
      ratios: { kcal: 1, protein_g: 1, fat_g: 1 },
      gaps: [],
    });
  });

  test("ingrédients modifiés depuis l'import : pas de comparaison", () => {
    assert.deepEqual(compare({ ingredients: [{ name: "lardons", qty: "300", unit: "g" }] }), {
      state: "ingredients_changed",
    });
  });

  test("couverture insuffisante : pas de comparaison", () => {
    assert.deepEqual(compare({ canShowPartial: false, coverage: 0.333 }), {
      state: "low_coverage",
      coverage: 0.33,
    });
  });

  test("pas de source_nutrition lisible : null", () => {
    assert.equal(compare({ sourceNutrition: undefined }), null);
    assert.equal(compare({ sourceNutrition: { per_portion: "x" } }), null);
  });
});
