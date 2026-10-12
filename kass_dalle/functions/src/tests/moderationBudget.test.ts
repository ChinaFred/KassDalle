/**
 * Plafond quotidien appliqué à la modération d'images (audit sécurité,
 * « Moyenne ») : chaque analyse Cloud Vision est facturée, et un compte qui
 * rappelait la fonction en boucle sur sa quarantaine n'avait aucune limite.
 * Logique pure : la décision du plafond, la réservation au coût connu, et la
 * traduction du refus pour le client.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  BudgetExceededError,
  DEFAULT_AI_BUDGET_POLICY,
  reservationDecision,
  reservedEstimateUsd,
  type DailySpend,
} from "../ai/budget";
import { moderationRefusal } from "../callable/moderationCallables";
import { estimateAiCostUsd, builtinPricingTable } from "../ai/pricing";
import { VISION_MODEL_ID, VISION_UNITS_PER_IMAGE } from "../moderation/vision";

const NOW = 1_800_000_000_000;

describe("modération — plafond quotidien", () => {
  test("compte au plafond d'appels : refus, traduit en resource-exhausted", () => {
    const spend: DailySpend = {
      costUsd: 0,
      calls: DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser,
      unpricedCalls: 0,
    };
    const decision = reservationDecision({
      spend,
      reservations: {},
      policy: DEFAULT_AI_BUDGET_POLICY,
      usdToEur: null,
      nowMs: NOW,
      interactive: true,
    });
    assert.equal(decision.denial?.reason, "calls");

    const refusal = moderationRefusal(new BudgetExceededError(decision.denial!));
    assert.equal(refusal?.code, "resource-exhausted");
    assert.match(refusal?.message ?? "", /aujourd'hui/);
  });

  test("compte au plafond en euros : refus, traduit en resource-exhausted", () => {
    const decision = reservationDecision({
      spend: { costUsd: 10, calls: 3, unpricedCalls: 0 },
      reservations: {},
      policy: DEFAULT_AI_BUDGET_POLICY,
      usdToEur: 0.9,
      nowMs: NOW,
      interactive: true,
    });
    assert.equal(decision.denial?.reason, "cost");
    assert.equal(
      moderationRefusal(new BudgetExceededError(decision.denial!))?.code,
      "resource-exhausted",
    );
  });

  test("sous le plafond : la place est donnée", () => {
    const decision = reservationDecision({
      spend: { costUsd: 0, calls: 1, unpricedCalls: 0 },
      reservations: {},
      policy: DEFAULT_AI_BUDGET_POLICY,
      usdToEur: 0.9,
      nowMs: NOW,
      interactive: true,
    });
    assert.equal(decision.denial, null);
  });

  test("une autre erreur n'est pas traduite ici", () => {
    assert.equal(moderationRefusal(new Error("panne")), null);
  });
});

describe("reservedEstimateUsd", () => {
  test("le coût connu d'une analyse prime sur la moyenne du jour", () => {
    const visionUsd = estimateAiCostUsd({
      model: VISION_MODEL_ID,
      inputTokens: 0,
      outputTokens: 0,
      analyzedImageUnits: VISION_UNITS_PER_IMAGE,
      table: builtinPricingTable(),
    });
    assert.ok(visionUsd > 0);
    assert.equal(reservedEstimateUsd(0.0001, visionUsd), visionUsd);
  });

  test("coût inconnu (grille illisible), nul ou invalide : la moyenne du jour", () => {
    assert.equal(reservedEstimateUsd(0.002, null), 0.002);
    assert.equal(reservedEstimateUsd(0.002, undefined), 0.002);
    assert.equal(reservedEstimateUsd(0.002, 0), 0.002);
    assert.equal(reservedEstimateUsd(0.002, Number.NaN), 0.002);
  });
});
