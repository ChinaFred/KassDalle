/**
 * Portion usuelle d'un ingrédient écrit sans quantité.
 *
 * Logique pure : aucun appel de modèle, aucun Firestore. Les cas partagés avec
 * Dart (`test-fixtures/unit_to_grams.json`, section `usual_portion`) vivent dans
 * `sharedFixtures.test.ts` ; ce fichier tient ce qui n'existe que côté serveur.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  MAX_USUAL_PORTION_GRAMS,
  buildUsualPortionPrompt,
  sanitizeUsualPortion,
} from "../nutrition/aiEnrichment";
import { isBareIngredientLine } from "../nutrition/quantityConversion";

describe("sanitizeUsualPortion — ce qui est gardé", () => {
  test("garde un nombre de grammes plausible", () => {
    assert.equal(sanitizeUsualPortion(30), 30);
    assert.equal(sanitizeUsualPortion(12.5), 12.5);
  });

  test("accepte un nombre écrit en chaîne, virgule comprise", () => {
    assert.equal(sanitizeUsualPortion("25"), 25);
    assert.equal(sanitizeUsualPortion("7,5"), 7.5);
  });

  test("arrondit au dixième", () => {
    assert.equal(sanitizeUsualPortion(12.34567), 12.3);
  });

  test("garde la borne haute", () => {
    assert.equal(sanitizeUsualPortion(MAX_USUAL_PORTION_GRAMS), MAX_USUAL_PORTION_GRAMS);
  });
});

describe("sanitizeUsualPortion — ce qui est refusé", () => {
  test("refuse zéro, un négatif et ce qui n'est pas un nombre", () => {
    assert.equal(sanitizeUsualPortion(0), null);
    assert.equal(sanitizeUsualPortion(-5), null);
    assert.equal(sanitizeUsualPortion(null), null);
    assert.equal(sanitizeUsualPortion(undefined), null);
    assert.equal(sanitizeUsualPortion("beaucoup"), null);
    assert.equal(sanitizeUsualPortion(Number.NaN), null);
  });

  test("refuse un poids qui n'est plus celui d'une garniture", () => {
    assert.equal(sanitizeUsualPortion(MAX_USUAL_PORTION_GRAMS + 1), null);
    assert.equal(sanitizeUsualPortion(4200), null);
  });
});

describe("buildUsualPortionPrompt", () => {
  const prompt = buildUsualPortionPrompt([
    { id: "roquette", name: "roquette" },
    { id: "parmesan", name: "parmesan" },
  ]);

  test("cite chaque ingrédient avec son identifiant", () => {
    assert.ok(prompt.includes('- "roquette" : roquette'));
    assert.ok(prompt.includes('- "parmesan" : parmesan'));
  });

  test("demande toujours une estimation, jamais un refus", () => {
    assert.ok(prompt.includes("Donne TOUJOURS une estimation"));
  });

  test("ne remplit aucun exemple de réponse", () => {
    // Un exemple rempli est recopié tel quel : le format ne porte que des
    // marqueurs à remplacer.
    assert.ok(prompt.includes('"grams":<grammes>'));
  });
});

describe("isBareIngredientLine — quelle ligne prend une portion", () => {
  test("une ligne sans nombre ni unité est nue", () => {
    assert.equal(isBareIngredientLine("roquette", "", ""), true);
    assert.equal(isBareIngredientLine("parmesan", undefined, undefined), true);
  });

  test("un nombre écrit rend la ligne non nue", () => {
    assert.equal(isBareIngredientLine("oignon", "3", ""), false);
  });

  test("une unité écrite rend la ligne non nue, même sans nombre", () => {
    assert.equal(isBareIngredientLine("basilic", "", "brin"), false);
    assert.equal(isBareIngredientLine("farine", "", "g"), false);
  });

  test("un assaisonnement n'est jamais nu : sa pincée passe avant", () => {
    assert.equal(isBareIngredientLine("sel", "", ""), false);
    assert.equal(isBareIngredientLine("poivre noir", "", ""), false);
  });

  test("« selle d'agneau » n'est pas du sel", () => {
    assert.equal(isBareIngredientLine("selle d'agneau", "", ""), true);
  });

  test("une quantité illisible vaut une quantité absente", () => {
    assert.equal(isBareIngredientLine("roquette", "quelques", ""), true);
  });
});
