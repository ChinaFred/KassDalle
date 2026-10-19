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

import { sandboxFn } from "../sandbox/callable";

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
