/**
 * Le plafond de dépense d'un import de livre.
 *
 * L'import du livre de Jamie Oliver (26 septembre 2026) a coûté 59,89 $ affichés
 * sans que rien l'arrête : le plafond du jour du fondateur vaut deux cents euros.
 * Ces cas verrouillent la décision, sans Firestore.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD,
  EMPTY_SCAN_SPEND,
  IMPORT_BUDGET_MARGIN,
  formatBudgetAmount,
  importBudgetDenial,
  parseBudgetLimit,
  raisedImportLimit,
  readScanSpend,
  suggestImportBudgetUsd,
  type ScanSpend,
} from "../ai/importBudget";

function spend(over: Partial<ScanSpend>): ScanSpend {
  return { ...EMPTY_SCAN_SPEND, ...over };
}

describe("parseBudgetLimit", () => {
  test("lit un nombre positif, en nombre ou en chaîne", () => {
    assert.equal(parseBudgetLimit(12.5), 12.5);
    assert.equal(parseBudgetLimit("15"), 15);
  });

  test("refuse zéro, un négatif, un texte, une valeur absente", () => {
    assert.equal(parseBudgetLimit(0), null);
    assert.equal(parseBudgetLimit(-3), null);
    assert.equal(parseBudgetLimit("beaucoup"), null);
    assert.equal(parseBudgetLimit(undefined), null);
    assert.equal(parseBudgetLimit(null), null);
    assert.equal(parseBudgetLimit(NaN), null);
    assert.equal(parseBudgetLimit(Infinity), null);
  });
});

describe("readScanSpend", () => {
  test("un document absent ne dépense rien et n'a pas de plafond", () => {
    assert.deepEqual(readScanSpend(undefined), EMPTY_SCAN_SPEND);
  });

  test("relit le compteur et le plafond", () => {
    const s = readScanSpend({
      cost_usd: 4.2,
      calls: 17,
      unpriced_calls: 1,
      limit_usd: 10,
      step_usd: 10,
    });
    assert.deepEqual(s, { costUsd: 4.2, calls: 17, unpricedCalls: 1, limitUsd: 10, stepUsd: 10 });
  });

  test("un plafond illisible vaut aucun plafond, jamais zéro", () => {
    const s = readScanSpend({ cost_usd: 3, limit_usd: "x", step_usd: -1 });
    assert.equal(s.limitUsd, null);
    assert.equal(s.stepUsd, null);
    assert.equal(s.costUsd, 3);
  });
});

describe("importBudgetDenial", () => {
  test("un scan sans plafond passe, quelle que soit sa dépense", () => {
    assert.equal(importBudgetDenial({ spend: spend({ costUsd: 900 }), usdToEur: 0.88 }), null);
  });

  test("sous le plafond, l'appel passe", () => {
    const s = spend({ costUsd: 9.99, limitUsd: 10 });
    assert.equal(importBudgetDenial({ spend: s, usdToEur: 0.88 }), null);
  });

  test("au plafond, l'appel est refusé, et le message chiffre en euros avec un taux", () => {
    const denial = importBudgetDenial({
      spend: spend({ costUsd: 10, limitUsd: 10 }),
      usdToEur: 0.9,
    });
    assert.ok(denial);
    assert.equal(denial.reason, "import");
    assert.match(denial.message, /9,00 €/);
    assert.match(denial.message, /Relancer une tranche/);
  });

  test("sans taux, le message reste en dollars : aucun taux n'est inventé", () => {
    const denial = importBudgetDenial({
      spend: spend({ costUsd: 10.5, limitUsd: 10 }),
      usdToEur: null,
    });
    assert.ok(denial);
    assert.match(denial.message, /10,50 \$/);
    assert.doesNotMatch(denial.message, /€/);
  });

  test("les appels non chiffrés n'avancent pas le compteur : ils ne déclenchent pas le plafond", () => {
    const s = spend({ costUsd: 2, unpricedCalls: 400, limitUsd: 10 });
    assert.equal(importBudgetDenial({ spend: s, usdToEur: 0.9 }), null);
  });
});

describe("raisedImportLimit", () => {
  test("le plafond atteint s'ouvre d'un palier au-dessus de la dépense", () => {
    const s = spend({ costUsd: 12, limitUsd: 10, stepUsd: 10 });
    assert.equal(raisedImportLimit(s), 22);
  });

  test("un plafond non atteint ne bouge pas : relancer ne donne pas de budget en plus", () => {
    const s = spend({ costUsd: 6, limitUsd: 10, stepUsd: 10 });
    assert.equal(raisedImportLimit(s), null);
  });

  test("plusieurs relances de suite convergent : la première relève, les suivantes non", () => {
    const atteint = spend({ costUsd: 10.4, limitUsd: 10, stepUsd: 10 });
    const limit = raisedImportLimit(atteint);
    assert.equal(limit, 20.4);
    const apres = spend({ costUsd: 10.4, limitUsd: limit, stepUsd: 10 });
    assert.equal(raisedImportLimit(apres), null);
  });

  test("sans plafond ni palier, rien à relever", () => {
    assert.equal(raisedImportLimit(spend({ costUsd: 50 })), null);
    assert.equal(raisedImportLimit(spend({ costUsd: 50, limitUsd: 10 })), null);
  });
});

describe("suggestImportBudgetUsd", () => {
  test("avec une estimation, elle plus la moitié, arrondie au dollar supérieur", () => {
    const suggested = suggestImportBudgetUsd({ windows: 77, estimatedCostUsd: 20 });
    assert.equal(suggested, Math.ceil(20 * IMPORT_BUDGET_MARGIN));
    assert.equal(suggested, 30);
  });

  test("sans estimation, une décision par tranche plutôt qu'aucune limite", () => {
    const suggested = suggestImportBudgetUsd({ windows: 77, estimatedCostUsd: null });
    assert.equal(suggested, Math.ceil(77 * DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD));
  });

  test("ne propose jamais moins d'un dollar", () => {
    assert.equal(suggestImportBudgetUsd({ windows: 1, estimatedCostUsd: 0.02 }), 1);
    assert.equal(suggestImportBudgetUsd({ windows: 0, estimatedCostUsd: null }), 1);
  });
});

describe("formatBudgetAmount", () => {
  test("euros avec un taux, virgule décimale", () => {
    assert.equal(formatBudgetAmount(10, 0.877799), "8,78 €");
  });

  test("dollars sans taux, ou avec un taux inutilisable", () => {
    assert.equal(formatBudgetAmount(10, null), "10,00 $");
    assert.equal(formatBudgetAmount(10, 0), "10,00 $");
  });
});
