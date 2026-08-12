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

import { buildUnitWeightPrompt, stripUnitContext, unitMatchKeys } from "../nutrition/aiEnrichment";

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

describe("stripUnitContext", () => {
  test("le contexte recollé par le modèle est retiré", () => {
    // Cas réellement observé en production : le prompt collait le contexte au
    // libellé, le modèle le renvoyait tel quel, et l'estimation était perdue.
    assert.equal(
      stripUnitContext("cuiller à soupe (utilisée pour : farine, celeri, carotte)"),
      "cuiller à soupe",
    );
  });

  test("le libellé nettoyé se rapproche de l'unité demandée", () => {
    const answered = "cuillerée à soupe (utilisée pour : farine)";
    assert.deepEqual(unitMatchKeys(stripUnitContext(answered)), ["c_a_s"]);
  });

  test("un libellé sans contexte est rendu inchangé", () => {
    assert.equal(stripUnitContext("louche"), "louche");
  });

  test("un libellé entièrement parenthésé n'est pas vidé", () => {
    assert.equal(stripUnitContext("(pincée)"), "(pincée)");
  });
});

describe("buildUnitWeightPrompt", () => {
  test("le contexte est séparé du nom de l'unité", () => {
    const prompt = buildUnitWeightPrompt([
      { canonical: "c_a_s", label: "cuiller à soupe", ingredients: ["farine", "celeri"] },
    ]);

    assert.ok(prompt.includes("id: c_a_s"), "l'identifiant doit être fourni");
    assert.ok(
      prompt.includes("unité : cuiller à soupe\n  contexte : farine, celeri"),
      "le contexte doit vivre sur sa propre ligne, jamais accolé au libellé",
    );
    assert.ok(
      !prompt.includes("cuiller à soupe (utilisée pour"),
      "l'ancienne forme collée est précisément ce qui cassait le rapprochement",
    );
  });

  test("une unité sans contexte reste demandée", () => {
    const prompt = buildUnitWeightPrompt([
      { canonical: "louche", label: "louche", ingredients: [] },
    ]);
    assert.ok(prompt.includes("id: louche"));
    // On vise la ligne de contexte de l'unité, pas la règle générale du prompt
    // qui emploie le même mot.
    assert.ok(!prompt.includes("\n  contexte :"));
  });
});
