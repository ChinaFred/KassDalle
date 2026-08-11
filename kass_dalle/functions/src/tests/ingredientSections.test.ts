/**
 * Sections CookLang : la catégorie d'un ingrédient doit survivre à la
 * normalisation référentiels.
 *
 * Logique pure (aucun Firestore) : ces tests couvrent le repérage des en-têtes
 * `== … ==` par offset, utilisé par `rewriteCooklangWithReferentials`, et la
 * déduplication par (identifiant, section) qui remplace une déduplication par
 * identifiant seul — laquelle fusionnait deux sections en une.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  buildSectionMarkers,
  sectionCategoryAt,
  ingredientSectionKey,
  dedupeResolvedIngredients,
  type DedupableIngredient,
} from "../nutrition/ingredientSections";

function ing(
  name: string,
  qty: string,
  unit: string,
  category?: string,
): DedupableIngredient {
  return {
    name,
    qty,
    unit,
    ingredient_ref_id: name.trim().toLowerCase().replaceAll(" ", "_"),
    ...(category ? { category } : {}),
  };
}

describe("sections CookLang", () => {
  const COOKLANG = [
    ">> titre: Tarte",
    "== Pour la pâte ==",
    "@farine{250%g}",
    "@beurre{125%g}",
    "== Pour la garniture ==",
    "@farine{20%g}",
    "@pommes{4}",
  ].join("\n");

  test("chaque token est rattaché à sa section", () => {
    const markers = buildSectionMarkers(COOKLANG);
    assert.deepEqual(
      markers.map((m) => m.category),
      ["Pour la pâte", "Pour la garniture"],
    );

    const offsets = [...COOKLANG.matchAll(/@([^{@#~\n]+)\{([^}]*)\}/g)].map((m) => ({
      name: m[1],
      category: sectionCategoryAt(markers, m.index ?? 0),
    }));
    assert.deepEqual(offsets, [
      { name: "farine", category: "Pour la pâte" },
      { name: "beurre", category: "Pour la pâte" },
      { name: "farine", category: "Pour la garniture" },
      { name: "pommes", category: "Pour la garniture" },
    ]);
  });

  test("avant tout en-tête, la section est vide", () => {
    const markers = buildSectionMarkers("@sel{1%pincée}\n== Sauce ==\n@eau{10%cl}");
    assert.equal(sectionCategoryAt(markers, 0), "");
    assert.equal(sectionCategoryAt(markers, COOKLANG.length), "Sauce");
  });

  test("un CookLang sans en-tête n'a aucune section", () => {
    assert.deepEqual(buildSectionMarkers("@sel{}\n@poivre{}"), []);
  });
});

describe("déduplication des ingrédients résolus", () => {
  test("le même ingrédient dans deux sections reste deux ingrédients", () => {
    const result = dedupeResolvedIngredients([
      ing("farine", "250", "g", "Pour la pâte"),
      ing("farine", "20", "g", "Pour la garniture"),
    ]);
    assert.equal(result.length, 2);
    assert.deepEqual(
      result.map((i) => i.category),
      ["Pour la pâte", "Pour la garniture"],
    );
  });

  test("deux libellés du même ingrédient dans une section fusionnent", () => {
    const result = dedupeResolvedIngredients([
      { ...ing("cerfeuil frais", "", "", "Garniture"), ingredient_ref_id: "cerfeuil_frais" },
      { ...ing("brins de cerfeuil frais", "3", "brin", "Garniture"), ingredient_ref_id: "cerfeuil_frais" },
    ]);
    assert.equal(result.length, 1);
    assert.equal(result[0].qty, "3");
    assert.equal(result[0].unit, "brin");
    assert.equal(result[0].category, "Garniture");
  });

  test("la fusion ne perd ni la quantité ni la catégorie du perdant", () => {
    const result = dedupeResolvedIngredients([
      { ...ing("beurre", "125", "", "Pour la pâte"), ingredient_ref_id: "beurre" },
      { ...ing("beurre", "", "g", "Pour la pâte"), ingredient_ref_id: "beurre" },
    ]);
    assert.equal(result.length, 1);
    assert.equal(result[0].qty, "125");
    assert.equal(result[0].unit, "g");
    assert.equal(result[0].category, "Pour la pâte");
  });

  test("un ingrédient sans section ne fusionne pas avec le même ingrédient sectionné", () => {
    const result = dedupeResolvedIngredients([
      ing("sel", "1", "pincée"),
      ing("sel", "2", "pincée", "Sauce"),
    ]);
    assert.equal(result.length, 2);
  });

  test("la clé de section ignore casse et espaces superflus", () => {
    assert.equal(
      ingredientSectionKey(" Farine ", " Pour La Pâte "),
      ingredientSectionKey("farine", "pour la pâte"),
    );
    assert.equal(ingredientSectionKey("farine", null), ingredientSectionKey("farine", ""));
  });
});
