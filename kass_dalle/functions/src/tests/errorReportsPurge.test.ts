/**
 * Purge des rapports d'erreur (ticket #162, point 3) : échéance à 90 jours et
 * boucle de suppression par lots. Logique pure, sans émulateur.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  ERROR_REPORTS_RETENTION_DAYS,
  errorReportsCutoff,
  purgeInBatches,
} from "../scheduled/errorReportsPurgeSchedule";

describe("errorReportsCutoff", () => {
  test("90 jours avant l'instant de la passe", () => {
    assert.equal(ERROR_REPORTS_RETENTION_DAYS, 90);
    const now = new Date("2026-10-22T04:00:00.000Z");
    assert.equal(errorReportsCutoff(now).toISOString(), "2026-07-24T04:00:00.000Z");
  });
});

/** Une file de N documents, lue par lots, supprimée par lots. */
function fakeCollection(count: number, failDeleteAt: number | null = null) {
  let remaining = Array.from({ length: count }, (_, i) => i);
  let deleteCalls = 0;
  return {
    read: async (limit: number) => remaining.slice(0, limit),
    remove: async (items: number[]) => {
      deleteCalls += 1;
      if (failDeleteAt !== null && deleteCalls === failDeleteAt) throw new Error("commit refusé");
      remaining = remaining.filter((x) => !items.includes(x));
    },
    left: () => remaining.length,
  };
}

describe("purgeInBatches", () => {
  test("rien à supprimer : passe complète, zéro", async () => {
    const c = fakeCollection(0);
    const out = await purgeInBatches(c.read, c.remove, 10, 5);
    assert.deepEqual(out, { deleted: 0, batches: 0, complete: true, failure: null });
  });

  test("supprime par lots jusqu'au dernier lot incomplet", async () => {
    const c = fakeCollection(25);
    const out = await purgeInBatches(c.read, c.remove, 10, 5);
    assert.deepEqual(out, { deleted: 25, batches: 3, complete: true, failure: null });
    assert.equal(c.left(), 0);
  });

  test("plafond de lots atteint : passe incomplète, le reste attend le lendemain", async () => {
    const c = fakeCollection(100);
    const out = await purgeInBatches(c.read, c.remove, 10, 3);
    assert.deepEqual(out, { deleted: 30, batches: 3, complete: false, failure: null });
    assert.equal(c.left(), 70);
  });

  test("un lot en échec arrête la passe et garde le compte déjà supprimé", async () => {
    const d = fakeCollection(30, 2);
    const failed = await purgeInBatches(d.read, d.remove, 10, 5);
    assert.deepEqual(failed, {
      deleted: 10,
      batches: 1,
      complete: false,
      failure: "commit refusé",
    });
  });

  test("une lecture en échec arrête la passe", async () => {
    const out = await purgeInBatches(
      async () => {
        throw new Error("lecture refusée");
      },
      async () => undefined,
      10,
      5,
    );
    assert.deepEqual(out, { deleted: 0, batches: 0, complete: false, failure: "lecture refusée" });
  });
});
