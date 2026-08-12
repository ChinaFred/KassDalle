/**
 * Rapprochement d'une graphie d'unité avec la réponse de l'IA.
 *
 * L'enrichissement demande le poids de « cuillerées à soupe » et reçoit
 * « cuillerée à soupe ». Rapprochées par égalité de chaîne, ces deux graphies
 * ne se reconnaissent pas : l'estimation était jetée et l'ingrédient sortait du
 * calcul nutritionnel sans un mot.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { unitMatchKeys } from "../nutrition/aiEnrichment";

describe("unitMatchKeys", () => {
  test("une unité connue se réduit à sa forme canonique", () => {
    assert.deepEqual(unitMatchKeys("cuillerées à soupe"), ["c_a_s"]);
    assert.deepEqual(unitMatchKeys("cuillerée à soupe"), ["c_a_s"]);
  });

  test("le pluriel d'une unité inconnue rejoint son singulier", () => {
    const plural = unitMatchKeys("fines tranches");
    const singular = unitMatchKeys("fine tranche");
    assert.ok(plural.includes("fines_tranches"));
    assert.ok(plural.includes("fine_tranche"));
    assert.ok(
      plural.some((key) => singular.includes(key)),
      "les deux graphies doivent partager au moins une clé",
    );
  });

  test("une forme déjà singulière ne produit qu'une clé", () => {
    assert.deepEqual(unitMatchKeys("louche"), ["louche"]);
  });

  test("une chaîne vide ne produit aucune clé", () => {
    assert.deepEqual(unitMatchKeys("   "), []);
  });
});
