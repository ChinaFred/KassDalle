/**
 * « Retirer les ustensiles des ingrédients » (`utensils_cleanup`) : ce qu'une
 * recette deviendrait, quelles fiches sont visées, et ce qu'on cherche dans
 * `ingredients_index` avant de supprimer une fiche. Logique pure : ni
 * Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  cleanupRecipe,
  isUtensilSheet,
  sheetUsageValues,
  summarizeUtensilsCleanup,
  type UtensilsCleanupResponse,
} from "../callable/utensilsCleanupBackfillCallable";

describe("cleanupRecipe", () => {
  test("réécrit @ en #, retire l'ustensile de la liste et de l'index", () => {
    const { patch, removed } = cleanupRecipe({
      raw_cooklang: "Étaler @papier sulfurisé{1%feuille} puis @beurre{20%g}.",
      draft_cooklang: "Étaler @papier sulfurisé{1%feuille} puis @beurre{20%g}.",
      ingredients: [
        { name: "papier sulfurisé", qty: "1", unit: "feuille" },
        { name: "beurre", qty: "20", unit: "g" },
      ],
      ingredients_index: ["papier sulfurisé", "beurre"],
    });
    assert.equal(patch.raw_cooklang, "Étaler #papier sulfurisé{1%feuille} puis @beurre{20%g}.");
    assert.equal(patch.draft_cooklang, patch.raw_cooklang);
    assert.deepEqual(patch.ingredients, [{ name: "beurre", qty: "20", unit: "g" }]);
    assert.deepEqual(patch.ingredients_index, ["beurre"]);
    assert.deepEqual(removed, ["papier sulfurisé"]);
  });

  test("recette propre : aucun champ à écrire", () => {
    const { patch, removed } = cleanupRecipe({
      raw_cooklang: "Poser sur #papier sulfurisé{}. Ajouter @moules{1%kg}.",
      ingredients: [{ name: "moules", qty: "1", unit: "kg" }],
      ingredients_index: ["moules"],
    });
    assert.deepEqual(patch, {});
    assert.deepEqual(removed, []);
  });

  test("un nom normalisé dans la liste seule est retiré, le texte n'est pas touché", () => {
    const { patch, removed } = cleanupRecipe({
      raw_cooklang: "Cuire.",
      ingredients: [
        { name: "film alimentaire", qty: "", unit: "" },
        { name: "feuille de brick", qty: "4", unit: "" },
      ],
    });
    assert.equal(patch.raw_cooklang, undefined);
    assert.deepEqual(patch.ingredients, [{ name: "feuille de brick", qty: "4", unit: "" }]);
    assert.deepEqual(removed, ["film alimentaire"]);
  });

  test("champs absents ou d'un autre type : ignorés", () => {
    assert.deepEqual(cleanupRecipe({ raw_cooklang: 3, ingredients: "x" }).patch, {});
  });
});

describe("fiches du référentiel", () => {
  test("une fiche est visée par son identifiant ou son nom canonique", () => {
    assert.equal(isUtensilSheet("papier_sulfurise", {}), true);
    assert.equal(isUtensilSheet("abc", { canonical_name: "film alimentaire" }), true);
    assert.equal(isUtensilSheet("moule", { canonical_name: "moule" }), false);
    assert.equal(isUtensilSheet("feuille_de_brick", {}), false);
  });

  test("valeurs cherchées : nom canonique, identifiant, alias, sans doublon", () => {
    assert.deepEqual(
      sheetUsageValues("papier_sulfurise", {
        canonical_name: "Papier sulfurisé",
        aliases: ["papier sulfurisé", "feuille de papier sulfurisé", 4],
      }),
      ["papier sulfurisé", "papier sulfurise", "feuille de papier sulfurisé"],
    );
  });

  test("au plus trente valeurs", () => {
    const aliases = Array.from({ length: 40 }, (_, i) => `alias ${i}`);
    assert.equal(sheetUsageValues("x", { aliases }).length, 30);
  });
});

describe("summarizeUtensilsCleanup", () => {
  const base: UtensilsCleanupResponse = {
    essaiABlanc: false,
    examinees: 10,
    corrigees: 2,
    dejaPropres: 8,
    echouees: 0,
    fichesTrouvees: 1,
    fichesSupprimees: 1,
    fichesEncoreCitees: 0,
    fichesEchouees: 0,
    recettesParcourues: true,
    fichesParcourues: true,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };

  test("passage complet sans reste : rien ne reste", () => {
    const s = summarizeUtensilsCleanup(base);
    assert.equal(s.complete, true);
    assert.equal(s.remaining, 0);
    assert.equal(s.toReview, 0);
  });

  test("essai à blanc qui trouve : des éléments à revoir, donc pas terminé", () => {
    const s = summarizeUtensilsCleanup({
      ...base,
      essaiABlanc: true,
      aRevoir: { items: [], total: 3 },
    });
    assert.equal(s.toReview, 3);
  });

  test("passage incomplet : reste inconnu", () => {
    const s = summarizeUtensilsCleanup({ ...base, completed: false });
    assert.equal(s.remaining, null);
  });
});
