/**
 * Plausibilité d'une estimation nutritionnelle.
 *
 * `sanitizePer100g` est le juge de paix entre « une approximation vaut mieux que
 * rien » et « un chiffre absurde pollue toutes les recettes ». Elle décide donc
 * de deux choses opposées : ce qu'on récupère d'une réponse incomplète, et ce
 * qu'on refuse d'écrire même si Gemini l'affirme.
 *
 * Logique pure : aucun appel Gemini, aucun Firestore.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { sanitizePer100g, hasPer100gValues } from "../nutrition/per100gEnrichment";

describe("sanitizePer100g — ce qui est récupéré", () => {
  test("garde une estimation normale", () => {
    const values = sanitizePer100g({
      kcal: 417,
      protein_g: 13,
      carbs_g: 1.4,
      fat_g: 39,
      saturated_fat_g: 14,
    });
    assert.equal(values.kcal, 417);
    assert.equal(values.protein_g, 13);
    assert.equal(values.fat_g, 39);
  });

  test("recalcule les calories manquantes depuis les macronutriments", () => {
    // Une réponse sans kcal était jusqu'ici jetée en entier, alors que
    // 4/4/9 la reconstitue exactement.
    const values = sanitizePer100g({ protein_g: 13, carbs_g: 1.4, fat_g: 39 });
    assert.equal(values.kcal, Math.round(13 * 4 + 1.4 * 4 + 39 * 9));
  });

  test("accepte les nombres écrits en chaîne, virgule comprise", () => {
    const values = sanitizePer100g({ kcal: "417", protein_g: "13,5" });
    assert.equal(values.kcal, 417);
    assert.equal(values.protein_g, 13.5);
  });
});

describe("sanitizePer100g — ce qui est refusé", () => {
  test("refuse une réponse entièrement nulle", () => {
    // Le cas « Gemini hésite et remplit des zéros » : rien à écrire, et
    // l'appelant doit relancer plutôt que de croire l'ingrédient enrichi.
    assert.deepEqual(sanitizePer100g({ kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0 }), {});
  });

  test("refuse une réponse vide", () => {
    assert.deepEqual(sanitizePer100g({}), {});
  });

  test("refuse des calories impossibles", () => {
    // Au-delà de l'huile pure (~900 kcal), c'est une erreur d'unité.
    assert.deepEqual(sanitizePer100g({ kcal: 4200, protein_g: 10, fat_g: 5 }), {});
  });

  test("refuse un macronutriment au-delà de 100 g pour 100 g", () => {
    assert.deepEqual(sanitizePer100g({ kcal: 400, protein_g: 250 }), {});
  });
});

describe("hasPer100gValues", () => {
  test("un référentiel fraîchement créé n'a pas de valeurs", () => {
    assert.equal(hasPer100gValues({}), false);
    assert.equal(hasPer100gValues(undefined), false);
    assert.equal(hasPer100gValues({ kcal: 0 }), false);
  });

  test("une seule valeur positive suffit", () => {
    assert.equal(hasPer100gValues({ kcal: 0, protein_g: 12 }), true);
    assert.equal(hasPer100gValues({ kcal: "417" }), true);
  });
});
