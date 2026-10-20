/**
 * Le plafond de dépense d'un import de livre.
 *
 * L'import du livre de Jamie Oliver (26 septembre 2026) a coûté 59,89 $ affichés
 * sans que rien l'arrête : le plafond du jour du fondateur vaut deux cents euros.
 * Ces cas verrouillent la décision, sans Firestore.
 */

import { test, describe } from "node:test";
import type { Firestore } from "firebase-admin/firestore";
import assert from "node:assert/strict";

import { dispatchScanId } from "../pipeline/jobDispatcher";
import { newScanId } from "../logging";
import {
  DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD,
  EMPTY_SCAN_SPEND,
  ForeignScanError,
  IMPORT_BUDGET_MARGIN,
  MAX_IMPORT_BUDGET_PER_WINDOW_EUR,
  MAX_IMPORT_BUDGET_PER_WINDOW_HARD_USD,
  effectiveImportLimitUsd,
  formatBudgetAmount,
  importBudgetDenial,
  isValidScanId,
  maxImportBudgetPerWindowUsd,
  maxImportBudgetUsd,
  parseBudgetLimit,
  raisedImportLimit,
  raiseImportCeiling,
  readScanSpend,
  scanOwnerConflict,
  setImportCeiling,
  suggestImportBudgetUsd,
  usableRate,
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
    const suggested = suggestImportBudgetUsd({ windows: 77, estimatedCostUsd: 20, usdToEur: 0.8 });
    assert.equal(suggested, Math.ceil(20 * IMPORT_BUDGET_MARGIN));
    assert.equal(suggested, 30);
  });

  test("sans estimation, une décision par tranche plutôt qu'aucune limite", () => {
    const suggested = suggestImportBudgetUsd({
      windows: 77,
      estimatedCostUsd: null,
      usdToEur: 0.8,
    });
    assert.equal(suggested, Math.ceil(77 * DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD));
  });

  test("ne propose jamais moins d'un dollar", () => {
    assert.equal(suggestImportBudgetUsd({ windows: 1, estimatedCostUsd: 0.02, usdToEur: 0.8 }), 1);
    assert.equal(suggestImportBudgetUsd({ windows: 0, estimatedCostUsd: null, usdToEur: 0.8 }), 1);
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

describe("maxImportBudgetUsd — 4 € par tranche, convertis au taux de la facture", () => {
  test("le maximum est fixé en euros", () => {
    assert.equal(MAX_IMPORT_BUDGET_PER_WINDOW_EUR, 4);
  });

  test("avec un taux, 4 € se convertissent en dollars", () => {
    // 0,8 € par dollar : 4 € valent 5 $.
    assert.equal(maxImportBudgetPerWindowUsd(0.8), 5);
    assert.equal(maxImportBudgetUsd(10, 0.8), 50);
  });

  test("arrondi au centime inférieur : le maximum en euros n'est jamais dépassé", () => {
    // 4 / 0,88 = 4,5454… $ par tranche ; 10 tranches = 45,45 $ = 39,996 €.
    const max = maxImportBudgetUsd(10, 0.88);
    assert.equal(max, 45.45);
    assert.ok(max * 0.88 <= 10 * MAX_IMPORT_BUDGET_PER_WINDOW_EUR);
  });

  test("sans taux, aucun taux inventé : 4 s'applique en dollars", () => {
    assert.equal(maxImportBudgetPerWindowUsd(null), 4);
    assert.equal(maxImportBudgetUsd(10, null), 40);
  });

  test("un taux inutilisable ou hors bornes compte comme absent", () => {
    for (const rate of [0, -1, NaN, Infinity, 1e-6, 0.05, 11, 1e6]) {
      assert.equal(usableRate(rate), null, String(rate));
      assert.equal(maxImportBudgetPerWindowUsd(rate), 4, String(rate));
    }
  });

  test("un taux aberrant ne fait jamais exploser le maximum", () => {
    assert.ok(maxImportBudgetPerWindowUsd(1e-6) <= MAX_IMPORT_BUDGET_PER_WINDOW_HARD_USD);
    // 0,1 est plausible mais donnerait 40 $ : la borne dure s'applique.
    assert.equal(maxImportBudgetPerWindowUsd(0.1), MAX_IMPORT_BUDGET_PER_WINDOW_HARD_USD);
    assert.equal(maxImportBudgetUsd(10, 0.1), 10 * MAX_IMPORT_BUDGET_PER_WINDOW_HARD_USD);
  });

  test("un dollar au moins pour un fichier sans tranche", () => {
    assert.equal(maxImportBudgetUsd(0, 0.8), 1);
    assert.equal(maxImportBudgetUsd(NaN, null), 1);
  });
});

describe("effectiveImportLimitUsd — le client ne peut que réduire", () => {
  test("un plafond client plus bas est gardé", () => {
    assert.equal(effectiveImportLimitUsd({ clientLimitUsd: 5, windows: 10, usdToEur: 0.8 }), 5);
  });

  test("un plafond client démesuré est ramené au maximum", () => {
    assert.equal(effectiveImportLimitUsd({ clientLimitUsd: 1e9, windows: 10, usdToEur: 0.8 }), 50);
    assert.equal(effectiveImportLimitUsd({ clientLimitUsd: 1e9, windows: 10, usdToEur: null }), 40);
  });

  test("un job sans plafond reçoit le maximum", () => {
    assert.equal(effectiveImportLimitUsd({ clientLimitUsd: null, windows: 3, usdToEur: 0.8 }), 15);
  });

  test("le plafond proposé reste sous le maximum, avec ou sans taux", () => {
    for (const usdToEur of [0.8, 0.95, null]) {
      for (const windows of [1, 3, 40, 120]) {
        const suggested = suggestImportBudgetUsd({ windows, estimatedCostUsd: null, usdToEur });
        assert.ok(suggested <= maxImportBudgetUsd(windows, usdToEur));
      }
    }
  });

  test("une estimation au-dessus du maximum propose le maximum", () => {
    // 10 tranches mesurées à 10 $ : 150 $ proposés, ramenés au maximum de 50 $.
    assert.equal(suggestImportBudgetUsd({ windows: 10, estimatedCostUsd: 100, usdToEur: 0.8 }), 50);
  });
});

/** Une base réduite à un document : ce que lisent et écrivent les transactions du plafond. */
function fakeDb(initial: Record<string, unknown> | undefined) {
  const state: { data: Record<string, unknown> | undefined; writes: number } = {
    data: initial,
    writes: 0,
  };
  const ref = {};
  const tx = {
    get: async () => ({ data: () => state.data }),
    set: (_ref: unknown, value: Record<string, unknown>) => {
      state.writes++;
      state.data = { ...(state.data ?? {}), ...value };
    },
    update: (_ref: unknown, value: Record<string, unknown>) => {
      state.writes++;
      state.data = { ...(state.data ?? {}), ...value };
    },
  };
  const db = {
    collection: () => ({ doc: () => ref }),
    runTransaction: async <T>(fn: (t: typeof tx) => Promise<T>) => fn(tx),
  } as unknown as Firestore;
  return { db, state };
}

describe("plafond d'import — le scan d'un autre compte", () => {
  test("scanOwnerConflict : seul un user_id posé et différent est un conflit", () => {
    assert.equal(scanOwnerConflict("A", "B"), true);
    assert.equal(scanOwnerConflict("A", "A"), false);
    assert.equal(scanOwnerConflict(undefined, "B"), false);
    assert.equal(scanOwnerConflict("", "B"), false);
  });

  test("setImportCeiling sur le scan d'un autre compte est refusé, sans écriture", async () => {
    const { db, state } = fakeDb({ user_id: "A", limit_usd: 5, step_usd: 5, cost_usd: 1 });
    await assert.rejects(
      setImportCeiling({ scanId: "s1", userId: "B", limitUsd: 1000, db }),
      ForeignScanError,
    );
    assert.equal(state.writes, 0);
    assert.equal(state.data?.limit_usd, 5);
  });

  test("setImportCeiling sur son propre scan, ou un scan neuf, pose le plafond", async () => {
    const own = fakeDb({ user_id: "A", limit_usd: 5, step_usd: 5 });
    await setImportCeiling({ scanId: "s1", userId: "A", limitUsd: 8, db: own.db });
    assert.equal(own.state.data?.limit_usd, 8);
    const fresh = fakeDb(undefined);
    await setImportCeiling({ scanId: "s2", userId: "B", limitUsd: 3, db: fresh.db });
    assert.equal(fresh.state.data?.user_id, "B");
    assert.equal(fresh.state.data?.limit_usd, 3);
  });

  test("raiseImportCeiling sur le scan d'un autre compte est refusé", async () => {
    const { db, state } = fakeDb({ user_id: "A", limit_usd: 5, step_usd: 5, cost_usd: 6 });
    await assert.rejects(raiseImportCeiling({ scanId: "s1", userId: "B", db }), ForeignScanError);
    assert.equal(state.writes, 0);
  });

  test("dispatchScanId : un import de livre reçoit toujours un identifiant serveur", () => {
    const generate = () => "serveur";
    assert.equal(
      dispatchScanId({
        clientScanId: "client",
        jobType: "bookDocumentScan",
        existingOwner: null,
        userId: "B",
        generate,
      }),
      "serveur",
    );
  });

  test("dispatchScanId : un autre job garde son scan_id, sauf s'il est à un autre compte", () => {
    const generate = () => "serveur";
    const client = "scan_1760000000000_1z141z3";
    const base = { clientScanId: client, jobType: "recipeScan", userId: "B", generate };
    assert.equal(dispatchScanId({ ...base, existingOwner: undefined }), client);
    assert.equal(dispatchScanId({ ...base, existingOwner: "B" }), client);
    assert.equal(dispatchScanId({ ...base, existingOwner: "A" }), "serveur");
  });

  test("dispatchScanId : un scan_id mal formé est remplacé par un identifiant serveur", () => {
    const generate = () => "serveur";
    const base = { jobType: "recipeScan", existingOwner: undefined, userId: "B", generate };
    assert.equal(dispatchScanId({ ...base, clientScanId: "client" }), "serveur");
    assert.equal(dispatchScanId({ ...base, clientScanId: "scan_1/../x" }), "serveur");
    assert.equal(dispatchScanId({ ...base, clientScanId: "" }), "serveur");
  });
});

describe("isValidScanId", () => {
  test("accepte la forme du client (`_newScanId`, scan_upload_service.dart)", () => {
    // Millisecondes, puis `nextInt(0x100000000).toRadixString(36)` : 1 à 7 caractères.
    assert.equal(isValidScanId("scan_1760000000000_1z141z3"), true);
    assert.equal(isValidScanId("scan_1760000000000_0"), true);
  });

  test("accepte la forme du serveur (`newScanId`, logging.ts)", () => {
    assert.equal(isValidScanId(newScanId()), true);
    assert.equal(isValidScanId("scan_1760000000000_k3j9x0ab"), true);
  });

  test("refuse un identifiant hors forme", () => {
    for (const bad of [
      "",
      "client",
      "scan_",
      "scan_123",
      "scan__abc",
      "scan_abc_def",
      "scan_123_ABC",
      "scan_123_abc/def",
      "scan_123_abc ",
      " scan_123_abc",
      "scan_12345678901234567_abc",
      "scan_123_abcdefghijklmnopq",
      "../scan_123_abc",
    ]) {
      assert.equal(isValidScanId(bad), false, bad);
    }
  });

  test("refuse une valeur qui n'est pas une chaîne", () => {
    assert.equal(isValidScanId(undefined), false);
    assert.equal(isValidScanId(null), false);
    assert.equal(isValidScanId(123), false);
    assert.equal(isValidScanId({ id: "scan_1_a" }), false);
  });
});
