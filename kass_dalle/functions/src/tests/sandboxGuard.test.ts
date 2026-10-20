/**
 * `sandboxFn` — la garde administrateur passe avant l'aiguillage (ticket #155).
 *
 * Un appel sans compte est refusé « unauthenticated » quel que soit
 * `experiment` : connu, inconnu ou absent. Avant le correctif, une expérience
 * absente ou inconnue répondait « invalid-argument » sans passer par la garde.
 * Le refus a lieu avant toute lecture Firestore (`baseContext`), donc sans
 * émulateur.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import type { CallableRequest } from "firebase-functions/v2/https";

import { readSandboxImage, sandboxFn } from "../sandbox/callable";
import { PAGE_IMAGE_MAX_BYTES } from "../callable/_inputBounds";

type SandboxCall = { run: (req: CallableRequest<unknown>) => Promise<unknown> };

function anonymousCall(data: unknown): CallableRequest<unknown> {
  return { data, rawRequest: { headers: {} } } as unknown as CallableRequest<unknown>;
}

describe("sandboxFn — garde unique avant le switch", () => {
  const experiments: unknown[] = [
    "image_import.detect_page",
    "image_import.detect_orientation",
    "image_import.detect_regions",
    "experience_inconnue",
    "__proto__",
    undefined,
  ];
  for (const experiment of experiments) {
    test(`appel sans compte refusé — experiment=${String(experiment)}`, async () => {
      await assert.rejects(
        (sandboxFn as unknown as SandboxCall).run(anonymousCall({ experiment })),
        (err: { code?: string }) => err.code === "unauthenticated",
      );
    });
  }
});

describe("readSandboxImage — image bornée (ticket #163)", () => {
  test("une image sous le plafond est décodée", () => {
    const { bytes, mimeType } = readSandboxImage({
      bytesBase64: Buffer.from([1, 2, 3]).toString("base64"),
      mimeType: "image/jpeg",
    });
    assert.deepEqual([...bytes], [1, 2, 3]);
    assert.equal(mimeType, "image/jpeg");
  });

  test("une image au plafond passe, un octet de plus est refusé", () => {
    const atMax = Buffer.alloc(PAGE_IMAGE_MAX_BYTES).toString("base64");
    assert.equal(
      readSandboxImage({ bytesBase64: atMax, mimeType: "image/png" }).bytes.length,
      PAGE_IMAGE_MAX_BYTES,
    );
    const over = Buffer.alloc(PAGE_IMAGE_MAX_BYTES + 1).toString("base64");
    assert.throws(
      () => readSandboxImage({ bytesBase64: over, mimeType: "image/png" }),
      (err: { code?: string }) => err.code === "invalid-argument",
    );
  });

  test("image ou type absent, ou d'un autre type : invalid-argument", () => {
    for (const data of [
      undefined,
      {},
      { bytesBase64: "AQID" },
      { mimeType: "image/png" },
      { bytesBase64: 12, mimeType: "image/png" },
      { bytesBase64: "AQID", mimeType: ["image/png"] },
    ]) {
      assert.throws(
        () => readSandboxImage(data as never),
        (err: { code?: string }) => err.code === "invalid-argument",
        JSON.stringify(data),
      );
    }
  });
});
