/**
 * Plafond de dépense — la décision, et rien d'autre.
 *
 * Ce que ces tests verrouillent : un plafond ne s'ouvre pas tout seul. Ni quand
 * la grille tarifaire tombe et que plus rien n'est chiffré, ni quand un réglage
 * vaut zéro, ni quand la politique est illisible.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_AI_BUDGET_POLICY,
  EMPTY_DAILY_SPEND,
  budgetDenial,
  dailySpendDocId,
  spendDay,
  type AiBudgetPolicy,
  type DailySpend,
} from "../ai/budget";
import { shouldAlert } from "../scheduled/aiBudgetAlertSchedule";

function policy(over: Partial<AiBudgetPolicy> = {}): AiBudgetPolicy {
  return { ...DEFAULT_AI_BUDGET_POLICY, ...over };
}

function spend(over: Partial<DailySpend> = {}): DailySpend {
  return { ...EMPTY_DAILY_SPEND, ...over };
}

describe("plafond quotidien — montant", () => {
  test("un compte qui n'a rien dépensé passe", () => {
    assert.equal(budgetDenial(spend(), policy()), null);
  });

  test("sous le plafond, ça passe ; au plafond, ça ne passe plus", () => {
    const p = policy({ dailyCostUsdPerUser: 2, dailyCallsPerUser: 0 });
    assert.equal(budgetDenial(spend({ costUsd: 1.99 }), p), null);
    assert.equal(budgetDenial(spend({ costUsd: 2 }), p)?.reason, "cost");
    assert.equal(budgetDenial(spend({ costUsd: 40 }), p)?.reason, "cost");
  });

  test("un plafond à zéro désactive ce seul critère, pas les autres", () => {
    const p = policy({ dailyCostUsdPerUser: 0, dailyCallsPerUser: 10 });
    assert.equal(budgetDenial(spend({ costUsd: 1000 }), p), null);
    assert.equal(budgetDenial(spend({ costUsd: 1000, calls: 10 }), p)?.reason, "calls");
  });
});

describe("plafond quotidien — nombre d'appels", () => {
  test("il tient quand la grille tarifaire est en panne", () => {
    // Panne de grille : les appels sont enregistrés sans montant. Un plafond
    // uniquement monétaire s'ouvrirait en grand exactement pendant l'incident.
    const p = policy({ dailyCostUsdPerUser: 2, dailyCallsPerUser: 50 });
    const enPanne = spend({ costUsd: 0, calls: 50, unpricedCalls: 50 });
    assert.equal(budgetDenial(enPanne, p)?.reason, "calls");
  });

  test("le montant l'emporte quand les deux sont atteints", () => {
    const p = policy({ dailyCostUsdPerUser: 1, dailyCallsPerUser: 1 });
    assert.equal(budgetDenial(spend({ costUsd: 5, calls: 5 }), p)?.reason, "cost");
  });
});

describe("interrupteur global", () => {
  test("désactivé, plus rien n'est refusé", () => {
    const p = policy({ enabled: false, dailyCostUsdPerUser: 0.01, dailyCallsPerUser: 1 });
    assert.equal(budgetDenial(spend({ costUsd: 99, calls: 999 }), p), null);
  });

  test("les défauts protègent — ils ne sont pas illimités", () => {
    assert.ok(DEFAULT_AI_BUDGET_POLICY.dailyCostUsdPerUser > 0);
    assert.ok(DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser > 0);
    assert.equal(DEFAULT_AI_BUDGET_POLICY.enabled, true);
  });

  test("le message dit ce qui est atteint, sans jargon ni code d'erreur", () => {
    const denial = budgetDenial(spend({ costUsd: 99 }), policy());
    assert.match(denial?.message ?? "", /plafond/i);
    assert.match(denial?.message ?? "", /demain/i);
  });
});

describe("identifiant de la dépense du jour", () => {
  test("le jour est en UTC, comme la période mensuelle", () => {
    // 00 h 30 à Paris le 18 est encore le 17 en UTC : les deux comptages
    // doivent tomber du même côté, sans quoi un mois ne serait pas la somme de
    // ses jours.
    assert.equal(spendDay(new Date("2026-08-17T22:30:00Z")), "2026-08-17");
    assert.equal(spendDay(new Date("2026-08-18T00:30:00Z")), "2026-08-18");
  });

  test("un compte et un jour donnent un document, et un seul", () => {
    assert.equal(dailySpendDocId("uid-1", "2026-08-17"), "uid-1_2026-08-17");
    assert.notEqual(dailySpendDocId("uid-1", "2026-08-17"), dailySpendDocId("uid-1", "2026-08-18"));
  });
});

describe("alerte mensuelle", () => {
  const base = { monthlyAlertUsd: 25, spentUsd: 30, alreadyAlertedPeriod: null, period: "2026-08" };

  test("elle se déclenche au franchissement", () => {
    assert.equal(shouldAlert(base), true);
    assert.equal(shouldAlert({ ...base, spentUsd: 24.99 }), false);
    assert.equal(shouldAlert({ ...base, spentUsd: 25 }), true);
  });

  test("elle ne se répète pas dans le même mois", () => {
    assert.equal(shouldAlert({ ...base, alreadyAlertedPeriod: "2026-08" }), false);
    // …mais elle revient le mois suivant.
    assert.equal(shouldAlert({ ...base, alreadyAlertedPeriod: "2026-07" }), true);
  });

  test("un seuil à zéro n'alerte jamais", () => {
    assert.equal(shouldAlert({ ...base, monthlyAlertUsd: 0 }), false);
  });
});
