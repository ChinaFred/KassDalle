/**
 * Plafond de dépense — la décision, et rien d'autre.
 *
 * Ce que ces tests verrouillent : un plafond ne s'ouvre pas tout seul. Ni quand
 * la grille tarifaire tombe et que plus rien n'est chiffré, ni quand le taux de
 * change manque et qu'aucun montant ne se convertit, ni quand un réglage vaut
 * zéro.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_AI_BUDGET_POLICY,
  EMPTY_DAILY_SPEND,
  FOUNDER_DAILY_BUDGET_MULTIPLIER,
  budgetDenial,
  dailySpendDocId,
  spendDay,
  type AiBudgetPolicy,
  type DailySpend,
} from "../ai/budget";
import { shouldAlert } from "../scheduled/aiBudgetAlertSchedule";
import { periodsToRead } from "../callable/budgetCallable";

function policy(over: Partial<AiBudgetPolicy> = {}): AiBudgetPolicy {
  return { ...DEFAULT_AI_BUDGET_POLICY, ...over };
}

function spend(over: Partial<DailySpend> = {}): DailySpend {
  return { ...EMPTY_DAILY_SPEND, ...over };
}

/** Un taux plausible, pour que les euros et les dollars ne se confondent pas. */
const RATE = 0.9;

describe("plafond quotidien — montant en euros", () => {
  test("un compte qui n'a rien dépensé passe", () => {
    assert.equal(budgetDenial({ spend: spend(), policy: policy(), usdToEur: RATE }), null);
  });

  test("la dépense est convertie avant d'être comparée", () => {
    // 2 € de plafond, taux 0,9 : la porte se ferme à 2,222… $, pas à 2 $.
    const p = policy({ dailyCostEurPerUser: 2, dailyCallsPerUser: 0 });
    assert.equal(budgetDenial({ spend: spend({ costUsd: 2.2 }), policy: p, usdToEur: RATE }), null);
    assert.equal(
      budgetDenial({ spend: spend({ costUsd: 2.25 }), policy: p, usdToEur: RATE })?.reason,
      "cost",
    );
  });

  test("un plafond à zéro désactive ce seul critère, pas les autres", () => {
    const p = policy({ dailyCostEurPerUser: 0, dailyCallsPerUser: 10 });
    assert.equal(
      budgetDenial({ spend: spend({ costUsd: 1000 }), policy: p, usdToEur: RATE }),
      null,
    );
    assert.equal(
      budgetDenial({ spend: spend({ costUsd: 1000, calls: 10 }), policy: p, usdToEur: RATE })
        ?.reason,
      "calls",
    );
  });
});

describe("quand un chiffre manque", () => {
  test("sans taux de change, le plafond en euros ne s'applique pas", () => {
    // Le taux ne s'invente pas : le plafond monétaire devient inévaluable.
    const p = policy({ dailyCostEurPerUser: 2, dailyCallsPerUser: 0 });
    assert.equal(
      budgetDenial({ spend: spend({ costUsd: 9999 }), policy: p, usdToEur: null }),
      null,
    );
  });

  test("…mais le plafond d'appels, lui, tient toujours", () => {
    const p = policy({ dailyCostEurPerUser: 2, dailyCallsPerUser: 50 });
    assert.equal(
      budgetDenial({ spend: spend({ calls: 50 }), policy: p, usdToEur: null })?.reason,
      "calls",
    );
  });

  test("panne de grille : des appels sans montant restent comptés", () => {
    const p = policy({ dailyCostEurPerUser: 2, dailyCallsPerUser: 50 });
    const enPanne = spend({ costUsd: 0, calls: 50, unpricedCalls: 50 });
    assert.equal(budgetDenial({ spend: enPanne, policy: p, usdToEur: RATE })?.reason, "calls");
  });
});

describe("le fondateur a dix fois le plafond", () => {
  const p = policy({ dailyCostEurPerUser: 2, dailyCallsPerUser: 100 });
  const m = FOUNDER_DAILY_BUDGET_MULTIPLIER;

  test("là où un autre compte est refusé, lui passe encore", () => {
    const s = spend({ costUsd: 3, calls: 300 });
    assert.notEqual(budgetDenial({ spend: s, policy: p, usdToEur: RATE }), null);
    assert.equal(budgetDenial({ spend: s, policy: p, usdToEur: RATE, multiplier: m }), null);
  });

  test("le multiplicateur porte sur les deux plafonds, pas seulement l'argent", () => {
    // Sinon le compteur d'appels bloquerait précisément celui qui a le droit
    // d'en faire dix fois plus. Les seuils suivent le multiplicateur : mille
    // appels passent, mille cinq cents non.
    const s = spend({ costUsd: 0, calls: 300 });
    assert.equal(budgetDenial({ spend: s, policy: p, usdToEur: RATE, multiplier: m }), null);
    assert.equal(
      budgetDenial({
        spend: spend({ calls: 100 * m + 1 }),
        policy: p,
        usdToEur: RATE,
        multiplier: m,
      })?.reason,
      "calls",
    );
  });

  test("il reste plafonné — dix fois plus haut, pas illimité", () => {
    // Le plafond est en EUROS (2 € × 10), la dépense en dollars : il faut donc
    // diviser par le taux pour trouver le montant qui le franchit, pas le
    // multiplier — l'inverse laisse passer et ne teste plus rien.
    const s = spend({ costUsd: (2 * m) / RATE + 1, calls: 10 });
    assert.equal(
      budgetDenial({ spend: s, policy: p, usdToEur: RATE, multiplier: m })?.reason,
      "cost",
    );
  });

  test("un multiplicateur absent ou absurde vaut un", () => {
    const s = spend({ costUsd: 3 });
    assert.notEqual(budgetDenial({ spend: s, policy: p, usdToEur: RATE, multiplier: 0 }), null);
    assert.notEqual(budgetDenial({ spend: s, policy: p, usdToEur: RATE, multiplier: -5 }), null);
  });
});

describe("interrupteur global", () => {
  test("désactivé, plus rien n'est refusé", () => {
    const p = policy({ enabled: false, dailyCostEurPerUser: 0.01, dailyCallsPerUser: 1 });
    assert.equal(
      budgetDenial({ spend: spend({ costUsd: 99, calls: 999 }), policy: p, usdToEur: RATE }),
      null,
    );
  });

  test("les défauts protègent — ils ne sont pas illimités", () => {
    assert.ok(DEFAULT_AI_BUDGET_POLICY.dailyCostEurPerUser > 0);
    assert.ok(DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser > 0);
    assert.equal(DEFAULT_AI_BUDGET_POLICY.enabled, true);
  });

  test("le message dit ce qui est atteint, sans jargon ni code d'erreur", () => {
    const denial = budgetDenial({
      spend: spend({ costUsd: 99 }),
      policy: policy(),
      usdToEur: RATE,
    });
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

describe("périodes lues par l'écran", () => {
  const existants = ["2025-11", "2026-06", "2026-07", "2026-08"];

  test("« depuis le début » rend tout, dans l'ordre", () => {
    assert.deepEqual(periodsToRead(null, existants), ["2025-11", "2026-06", "2026-07", "2026-08"]);
  });

  test("une profondeur ne rend que les mois qui existent vraiment", () => {
    // Trois mois demandés : 2025-11 tombe hors fenêtre, et les mois sans
    // document ne sont pas inventés — une période fantôme se lirait « 0 € ».
    const rendu = periodsToRead(3, existants);
    assert.ok(rendu.every((p) => existants.includes(p)));
    assert.equal(rendu.includes("2025-11"), false);
  });

  test("une profondeur absurde est bornée, jamais rejetée", () => {
    assert.deepEqual(periodsToRead(0, existants), periodsToRead(1, existants));
  });
});

describe("alerte mensuelle", () => {
  const base = {
    monthlyAlertEur: 25,
    spentEur: 30 as number | null,
    alreadyAlertedPeriod: null as string | null,
    period: "2026-08",
  };

  test("elle se déclenche au franchissement", () => {
    assert.equal(shouldAlert(base), true);
    assert.equal(shouldAlert({ ...base, spentEur: 24.99 }), false);
    assert.equal(shouldAlert({ ...base, spentEur: 25 }), true);
  });

  test("sans taux, elle ne se déclenche pas — et l'appelant le journalise", () => {
    assert.equal(shouldAlert({ ...base, spentEur: null }), false);
  });

  test("elle ne se répète pas dans le même mois", () => {
    assert.equal(shouldAlert({ ...base, alreadyAlertedPeriod: "2026-08" }), false);
    // …mais elle revient le mois suivant.
    assert.equal(shouldAlert({ ...base, alreadyAlertedPeriod: "2026-07" }), true);
  });

  test("un seuil à zéro n'alerte jamais", () => {
    assert.equal(shouldAlert({ ...base, monthlyAlertEur: 0 }), false);
  });
});
