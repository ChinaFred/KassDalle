/**
 * « Purger les rapports d'erreur anciens » (`retention`) : âge de coupure,
 * lecture d'un chemin de capture, et capture orpheline. Logique pure : ni
 * Firestore, ni Storage.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  ERROR_REPORT_RETENTION_DAYS,
  isOrphanScreenshot,
  parseScreenshotPath,
  reportCutoff,
  summarizeRetention,
  type RetentionResponse,
} from "../callable/retentionBackfillCallable";

describe("reportCutoff", () => {
  test("quatre-vingt-dix jours avant maintenant", () => {
    const now = Date.UTC(2026, 9, 22, 12);
    assert.equal(ERROR_REPORT_RETENTION_DAYS, 90);
    assert.equal(reportCutoff(now).toISOString(), "2026-07-24T12:00:00.000Z");
  });
});

describe("parseScreenshotPath", () => {
  test("chemin d'une capture", () => {
    assert.deepEqual(parseScreenshotPath("tickets/u1/t1/screenshot.png"), {
      uid: "u1",
      ticketId: "t1",
      fileName: "screenshot.png",
    });
  });

  test("autres chemins : ignorés", () => {
    assert.equal(parseScreenshotPath("tickets/u1/screenshot.png"), null);
    assert.equal(parseScreenshotPath("tickets/u1/t1/a/b.png"), null);
    assert.equal(parseScreenshotPath("users/u1/t1/screenshot.png"), null);
    assert.equal(parseScreenshotPath("tickets//t1/screenshot.png"), null);
  });
});

describe("isOrphanScreenshot", () => {
  const path = "tickets/u1/t1/screenshot.png";

  test("rattachée à son ticket : gardée", () => {
    assert.equal(
      isOrphanScreenshot(path, "u1", { author_uid: "u1", screenshot_path: path }),
      false,
    );
  });

  test("ticket absent : orpheline", () => {
    assert.equal(isOrphanScreenshot(path, "u1", undefined), true);
  });

  test("ticket d'un autre compte : orpheline", () => {
    assert.equal(isOrphanScreenshot(path, "u1", { author_uid: "u2", screenshot_path: path }), true);
  });

  test("capture remplacée ou jamais rattachée : orpheline", () => {
    assert.equal(
      isOrphanScreenshot(path, "u1", {
        author_uid: "u1",
        screenshot_path: "tickets/u1/t1/screenshot.jpg",
      }),
      true,
    );
    assert.equal(isOrphanScreenshot(path, "u1", { author_uid: "u1", screenshot_path: null }), true);
  });
});

describe("summarizeRetention", () => {
  const base: RetentionResponse = {
    rapportsSupprimes: 12,
    rapportsParcourus: true,
    capturesExaminees: 3,
    capturesSupprimees: 1,
    capturesRecentes: 0,
    capturesEchouees: 0,
    capturesParcourues: true,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };

  test("passage complet : rien ne reste", () => {
    const s = summarizeRetention(base);
    assert.equal(s.complete, true);
    assert.equal(s.remaining, 0);
  });

  test("passage arrêté : reste inconnu", () => {
    const s = summarizeRetention({ ...base, completed: false, stoppedByBudget: true });
    assert.equal(s.complete, false);
    assert.equal(s.remaining, null);
  });
});
