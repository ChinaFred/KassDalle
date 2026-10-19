/**
 * Pages supplémentaires d'un job d'import (ticket #156) : borne de 20,
 * refus net au-delà, téléchargement en séquence, et concordance avec la
 * règle `processing_jobs` de `firestore.rules`.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as path from "node:path";

import {
  ImportTooLargeError,
  MAX_ADDITIONAL_FILE_URLS,
  MAX_IMPORT_TOTAL_BYTES,
  assertImportSizeWithin,
  TooManyPagesError,
  downloadInSequence,
  readAdditionalFileUrls,
} from "../pipeline/jobPages";

const urls = (n: number) => Array.from({ length: n }, (_, i) => `scans/u/page-${i}.jpg`);

describe("readAdditionalFileUrls", () => {
  test("à la borne : la liste passe telle quelle", () => {
    assert.deepEqual(readAdditionalFileUrls(urls(20)), urls(20));
  });

  test("au-delà : refus net, message lisible", () => {
    assert.throws(
      () => readAdditionalFileUrls(urls(21)),
      (err: unknown) =>
        err instanceof TooManyPagesError &&
        err.count === 21 &&
        err.message.includes("20 au plus") &&
        err.message.includes("21 pages par import"),
    );
  });

  test("absente ou d'un autre type : aucune page", () => {
    assert.deepEqual(readAdditionalFileUrls(undefined), []);
    assert.deepEqual(readAdditionalFileUrls(null), []);
    assert.deepEqual(readAdditionalFileUrls("scans/u/a.jpg"), []);
  });
});

describe("downloadInSequence", () => {
  test("une page à la fois, dans l'ordre des chemins", async () => {
    let inFlight = 0;
    let maxInFlight = 0;
    const order: string[] = [];
    const result = await downloadInSequence(["a", "b", "c"], async (p) => {
      inFlight++;
      maxInFlight = Math.max(maxInFlight, inFlight);
      await new Promise((r) => setTimeout(r, 2));
      order.push(p);
      inFlight--;
      return Buffer.from(p);
    });
    assert.equal(maxInFlight, 1);
    assert.deepEqual(order, ["a", "b", "c"]);
    assert.deepEqual(
      result.map((b) => b.toString()),
      ["a", "b", "c"],
    );
  });
});

test("la borne de firestore.rules est celle du processeur", () => {
  // __dirname vaut functions/lib/tests une fois compilé → remonter à kass_dalle/.
  const rules = readFileSync(path.join(__dirname, "..", "..", "..", "firestore.rules"), "utf8");
  const match = /additional_file_urls\.size\(\) <= (\d+)/.exec(rules);
  assert.ok(match, "borne de additional_file_urls absente de firestore.rules");
  assert.equal(Number(match[1]), MAX_ADDITIONAL_FILE_URLS);
});

describe("assertImportSizeWithin — 200 Mo par import", () => {
  const MB = 1024 * 1024;
  const sizes =
    (table: Record<string, unknown>) =>
    async (p: string): Promise<unknown> =>
      table[p];

  test("la borne vaut 200 Mo", () => {
    assert.equal(MAX_IMPORT_TOTAL_BYTES, 200 * MB);
  });

  test("à la borne : passe, total rendu (tailles en chaîne, comme Storage)", async () => {
    const total = await assertImportSizeWithin(
      ["a", "b"],
      sizes({ a: String(150 * MB), b: 50 * MB }),
      MAX_IMPORT_TOTAL_BYTES,
    );
    assert.equal(total, 200 * MB);
  });

  test("au-delà : refus lisible, sans lire la suite", async () => {
    const read: string[] = [];
    await assert.rejects(
      assertImportSizeWithin(
        ["a", "b", "c"],
        async (p) => {
          read.push(p);
          return p === "a" ? 150 * MB : 51 * MB;
        },
        MAX_IMPORT_TOTAL_BYTES,
      ),
      (err: unknown) =>
        err instanceof ImportTooLargeError &&
        err.message.includes("201 Mo au total") &&
        err.message.includes("200 Mo au plus"),
    );
    assert.deepEqual(read, ["a", "b"]);
  });

  test("taille illisible : refusée", async () => {
    for (const bad of [undefined, "abc", -1, 1.5]) {
      await assert.rejects(
        assertImportSizeWithin(["a"], sizes({ a: bad }), MAX_IMPORT_TOTAL_BYTES),
        (err: unknown) => err instanceof ImportTooLargeError && err.totalBytes === null,
        String(bad),
      );
    }
  });
});
