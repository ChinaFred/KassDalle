/**
 * Sections CookLang : la catégorie d'un ingrédient doit survivre à la
 * normalisation référentiels, dans les deux sens.
 *
 * Logique pure (aucun Firestore) : lecture des en-têtes, écriture des en-têtes
 * manquants (`planSectionHeaders`, utilisé par `rewriteCooklangWithReferentials`)
 * et déduplication par (identifiant, section) — laquelle, par identifiant seul,
 * fusionnait deux sections en une.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  parseSectionHeader,
  formatSectionHeader,
  buildCategoryByRefId,
  planSectionHeaders,
  ingredientRefKey,
  ingredientSectionKey,
  dedupeResolvedIngredients,
  type DedupableIngredient,
} from "../nutrition/ingredientSections";
import { resolveIngredientUnitFields } from "../nutrition/ingredientUnitResolution";

function ing(name: string, qty: string, unit: string, category?: string): DedupableIngredient {
  return {
    name,
    qty,
    unit,
    ingredient_ref_id: name.trim().toLowerCase().replaceAll(" ", "_"),
    ...(category ? { category } : {}),
  };
}

/** Rejoue le plan d'en-têtes sur un texte, en dérivant la cible par ligne. */
function applyPlan(cooklang: string, categoryByRefId: Map<string, string>): string {
  const lines = cooklang.split("\n");
  const targetCategories = lines.map((line) => {
    if (parseSectionHeader(line) !== null) return null;
    for (const m of line.matchAll(/@([^{@#~\n]+)\{([^}]*)\}/g)) {
      const key = ingredientRefKey({
        name: m[1].trim().replaceAll(" ", "_"),
        ingredient_ref_id: "",
      });
      const known = categoryByRefId.get(key);
      if (known !== undefined) return known;
    }
    return null;
  });
  return planSectionHeaders({ lines, targetCategories }).join("\n");
}

describe("lecture des en-têtes de section", () => {
  test("un en-tête rend son nom, une ligne ordinaire rend null", () => {
    assert.equal(parseSectionHeader("== Pour la pâte =="), "Pour la pâte");
    assert.equal(parseSectionHeader("   ==Pour la sauce==  "), "Pour la sauce");
    assert.equal(parseSectionHeader("Mélanger @farine{200%g}."), null);
    assert.equal(parseSectionHeader(">> titre: Tarte"), null);
    assert.equal(parseSectionHeader(""), null);
  });

  test("le format écrit est relu à l'identique", () => {
    assert.equal(parseSectionHeader(formatSectionHeader("Pour la sauce")), "Pour la sauce");
  });
});

describe("catégorie décidée par la liste d'ingrédients", () => {
  test("un ingrédient présent dans deux sections est écarté", () => {
    const map = buildCategoryByRefId([
      ing("farine", "250", "g", "Pour la pâte"),
      ing("farine", "20", "g", "Pour la garniture"),
      ing("beurre", "125", "g", "Pour la pâte"),
    ]);
    assert.equal(map.has("farine"), false, "farine est ambiguë : le texte tranche");
    assert.equal(map.get("beurre"), "Pour la pâte");
  });

  test("une absence de catégorie est une réponse, pas un silence", () => {
    const map = buildCategoryByRefId([ing("sel", "1", "pincée")]);
    assert.equal(map.has("sel"), true);
    assert.equal(map.get("sel"), "");
  });
});

describe("écriture des en-têtes manquants", () => {
  test("une catégorie créée dans l'éditeur entre dans le CookLang", () => {
    const cooklang = [
      ">> titre: Gyoza",
      "Mélangez @porc haché{250%g} et @sauce soja{2%c. à soupe}.",
      "Mélangez @huile de sésame{1%c. à café} et @vinaigre{6%c. à soupe}.",
    ].join("\n");
    const map = new Map([
      ["porc_haché", "Pour les gyozas"],
      ["sauce_soja", "Pour les gyozas"],
      ["huile_de_sésame", "Pour la sauce"],
      ["vinaigre", "Pour la sauce"],
    ]);
    assert.equal(
      applyPlan(cooklang, map),
      [
        ">> titre: Gyoza",
        "== Pour les gyozas ==",
        "Mélangez @porc haché{250%g} et @sauce soja{2%c. à soupe}.",
        "== Pour la sauce ==",
        "Mélangez @huile de sésame{1%c. à café} et @vinaigre{6%c. à soupe}.",
      ].join("\n"),
    );
  });

  test("un texte déjà cohérent n'est pas touché", () => {
    const cooklang = [
      "== Pour la pâte ==",
      "Mélangez @farine{200%g}.",
      "== Pour la garniture ==",
      "Disposez @pomme{4%piece}.",
    ].join("\n");
    const map = new Map([
      ["farine", "Pour la pâte"],
      ["pomme", "Pour la garniture"],
    ]);
    assert.equal(applyPlan(cooklang, map), cooklang);
  });

  test("une catégorie renommée remplace l'en-tête devenu vide, sans le doubler", () => {
    const cooklang = ["== Pâte ==", "Mélangez @farine{200%g}."].join("\n");
    const map = new Map([["farine", "Pour la pâte"]]);
    assert.equal(
      applyPlan(cooklang, map),
      ["== Pour la pâte ==", "Mélangez @farine{200%g}."].join("\n"),
    );
  });

  test("un ingrédient que la liste ne situe pas laisse la ligne intacte", () => {
    const cooklang = ["== Pâte ==", "Mélangez @farine{200%g}."].join("\n");
    assert.equal(applyPlan(cooklang, new Map()), cooklang);
  });

  test("un ingrédient sans catégorie n'ouvre aucune section", () => {
    const cooklang = "Salez avec @sel{1%pincée}.";
    assert.equal(applyPlan(cooklang, new Map([["sel", ""]])), cooklang);
  });

  test("le retour à une catégorie déjà ouverte réémet son en-tête", () => {
    // CookLang n'a pas de marqueur de fin de section : réémettre est le seul
    // moyen de rester relisible quand les catégories s'entrelacent.
    const cooklang = [
      "Mélangez @farine{200%g}.",
      "Fouettez @oeuf{2}.",
      "Saupoudrez de @sucre{50%g}.",
    ].join("\n");
    const map = new Map([
      ["farine", "Pâte"],
      ["oeuf", "Crème"],
      ["sucre", "Pâte"],
    ]);
    assert.equal(
      applyPlan(cooklang, map),
      [
        "== Pâte ==",
        "Mélangez @farine{200%g}.",
        "== Crème ==",
        "Fouettez @oeuf{2}.",
        "== Pâte ==",
        "Saupoudrez de @sucre{50%g}.",
      ].join("\n"),
    );
  });

  test("une ligne vide entre l'en-tête et l'ingrédient n'empêche pas le renommage", () => {
    const cooklang = ["== Pâte ==", "", "Mélangez @farine{200%g}."].join("\n");
    const map = new Map([["farine", "Pour la pâte"]]);
    assert.equal(
      applyPlan(cooklang, map),
      ["== Pour la pâte ==", "", "Mélangez @farine{200%g}."].join("\n"),
    );
  });
});

describe("la résolution d'unité reste un intermédiaire de calcul", () => {
  // Ces champs ne sont plus stockés sur la recette : ils se recalculent depuis
  // le nom et l'unité, partout où ils servent. C'est ce qui a permis de retirer
  // au déclencheur nutrition son écriture sur `ingredients`, laquelle effaçait
  // la catégorie que la sauvegarde venait d'y écrire.
  test("elle se recalcule à l'identique depuis ce que la recette dit", () => {
    const resolved = resolveIngredientUnitFields({ name: "farine", qty: "200", unit: "g" });
    assert.equal(resolved.unit_canonical, "g");
    assert.equal(resolved.unit_resolution_source, "explicit_known");
    assert.equal(resolved.unit_resolution_confidence, 1);
  });

  test("la catégorie traverse la résolution", () => {
    const resolved = resolveIngredientUnitFields({
      name: "farine",
      qty: "200",
      unit: "g",
      category: "Pour la pâte",
    });
    assert.equal(resolved.category, "Pour la pâte");
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
      {
        ...ing("brins de cerfeuil frais", "3", "brin", "Garniture"),
        ingredient_ref_id: "cerfeuil_frais",
      },
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
