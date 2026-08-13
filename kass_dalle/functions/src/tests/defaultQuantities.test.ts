/**
 * Quantité de repli pour un ingrédient laissé sans quantité.
 *
 * Deux exigences opposées se rencontrent ici. D'un côté, « huile pour graisser
 * le fond du plat » n'aura jamais de quantité écrite, et sans repli elle sort
 * du calcul : une centaine de kilocalories manquantes que rien ne signale. De
 * l'autre, une absence de quantité a souvent un sens — un « poulet » listé sans
 * quantité peut être un intitulé dont la découpe est chiffrée plus bas, et lui
 * inventer un poids fausserait la recette entière.
 *
 * D'où une liste courte et assumée : les matières grasses de fond de plat, et
 * rien d'autre. Ces tests gardent cette frontière.
 *
 * Logique pure : aucun appel d'IA, aucun Firestore.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { defaultQuantityForMissing } from "../nutrition/unitDisplay";

describe("defaultQuantityForMissing — ce qui reçoit une quantité", () => {
  test("l'huile se verse à la cuillère à soupe", () => {
    assert.deepEqual(defaultQuantityForMissing("huile"), {
      qty: "1",
      unit: "c.à.s.",
    });
  });

  test("les huiles qualifiées suivent la même règle", () => {
    for (const name of ["huile d'olive", "huile de tournesol", "huile pepins de raisins"]) {
      assert.deepEqual(
        defaultQuantityForMissing(name),
        { qty: "1", unit: "c.à.s." },
        `attendu pour « ${name} »`,
      );
    }
  });

  test("le beurre se dépose en noisette, pas à la cuillère", () => {
    assert.deepEqual(defaultQuantityForMissing("beurre"), {
      qty: "1",
      unit: "noisette",
    });
  });

  test("les autres corps gras de cuisson sont couverts", () => {
    for (const name of ["saindoux", "graisse de canard", "ghee", "margarine"]) {
      assert.notEqual(
        defaultQuantityForMissing(name),
        null,
        `attendu une quantité par défaut pour « ${name} »`,
      );
    }
  });
});

describe("defaultQuantityForMissing — ce qui garde son silence", () => {
  test("une viande sans quantité n'en reçoit pas", () => {
    // Le cas qui a motivé la limite : « Poulet » sans quantité désignait la
    // pièce dont les blancs étaient chiffrés plus bas. Lui inventer un poids
    // aurait double-compté la recette.
    assert.equal(defaultQuantityForMissing("poulet"), null);
    assert.equal(defaultQuantityForMissing("côte de veau"), null);
  });

  test("un aromate sans quantité n'en reçoit pas", () => {
    assert.equal(defaultQuantityForMissing("thym"), null);
    assert.equal(defaultQuantityForMissing("sel"), null);
    assert.equal(defaultQuantityForMissing("poivre"), null);
  });

  test("un nom vide ne produit rien", () => {
    assert.equal(defaultQuantityForMissing(""), null);
    assert.equal(defaultQuantityForMissing("   "), null);
  });
});
