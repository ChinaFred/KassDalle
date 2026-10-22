/**
 * Plafond de coût d'une génération de planning : estimation du coût plafond
 * d'un appel sur une grille reçue en argument, jamais sur un prix du code.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { builtinPricingTable, estimateAiCostUsd } from "../ai/pricing";
import {
  PLANNING_CONCEPT_MAX_TOKENS,
  PLANNING_MAX_TOKENS,
  estimateCallCeilingUsd,
  estimateInputTokens,
  degradedNotice,
  formatEur,
  generationCapCause,
} from "../gemini/planning";

describe("coût plafond d'un appel", () => {
  const table = builtinPricingTable();
  const at = new Date("2026-10-10T12:00:00Z");

  test("trois caractères par jeton d'entrée, arrondi au-dessus", () => {
    assert.equal(estimateInputTokens(0), 0);
    assert.equal(estimateInputTokens(1), 1);
    assert.equal(estimateInputTokens(3_000), 1_000);
  });

  test("le plafond se calcule sur la grille passée, comme le coût réel", () => {
    const model = Object.keys(table)[0];
    const ceiling = estimateCallCeilingUsd({
      model,
      promptChars: 15_000,
      maxOutputTokens: PLANNING_MAX_TOKENS,
      table,
      at,
    });
    const expected = estimateAiCostUsd({
      model,
      inputTokens: 5_000,
      outputTokens: PLANNING_MAX_TOKENS,
      table,
      at,
    });
    assert.equal(ceiling, expected);
  });

  test("une conception a un plafond positif sur la grille d’amorçage", () => {
    const model = Object.keys(table)[0];
    const withTable = estimateCallCeilingUsd({
      model,
      promptChars: 3_000,
      maxOutputTokens: PLANNING_CONCEPT_MAX_TOKENS,
      table,
      at,
    });
    assert.ok(withTable > 0);
  });

  test("plafonds de sortie : 16 000 pour le planning, 6 000 pour une conception", () => {
    assert.equal(PLANNING_MAX_TOKENS, 16_000);
    assert.equal(PLANNING_CONCEPT_MAX_TOKENS, 6_000);
  });
});

describe("message du plafond par génération", () => {
  test("montant en euros, virgule décimale", () => {
    assert.equal(formatEur(0.5), "0,50 €");
    const cause = generationCapCause(0.5);
    assert.equal(
      degradedNotice(cause.lead, cause.nothingBilled, []),
      "Cette génération aurait coûté plus de 0,50 € en IA. Kass'Dalle a choisi les plats selon vos contraintes. Rien n'a été facturé.",
    );
    assert.equal(
      degradedNotice(cause.lead, cause.nothingBilled, ["pas trop gras"]),
      "Cette génération aurait coûté plus de 0,50 € en IA. Kass'Dalle a choisi les plats selon vos critères vérifiés. Rien n'a été facturé. Ces consignes n'ont pas été suivies : « pas trop gras ».",
    );
  });
});
