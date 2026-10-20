/**
 * Relance d'un dead letter : une seule relance par dead letter (audit #151,
 * ticket #163, point 7). Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { ALREADY_RELAUNCHED_MESSAGE, relaunchDenial } from "../pipeline/deadLetterHandler";

describe("relaunchDenial", () => {
  const dlq = { original_job_id: "job1", relaunched_at: null };

  test("dead letter jamais relancé, job d'origine présent : permis", () => {
    assert.equal(relaunchDenial({ dlq, originalExists: true }), null);
  });

  test("dead letter sans champ relaunched_at (document ancien) : permis", () => {
    assert.equal(relaunchDenial({ dlq: { original_job_id: "job1" }, originalExists: true }), null);
  });

  test("dead letter déjà relancé : failed-precondition", () => {
    const denial = relaunchDenial({
      dlq: { ...dlq, relaunched_at: { seconds: 1 } },
      originalExists: true,
    });
    assert.deepEqual(denial, {
      code: "failed-precondition",
      message: ALREADY_RELAUNCHED_MESSAGE,
    });
    assert.equal(ALREADY_RELAUNCHED_MESSAGE, "Ce job a déjà été relancé.");
  });

  test("le refus « déjà relancé » passe avant le job d'origine supprimé", () => {
    const denial = relaunchDenial({
      dlq: { ...dlq, relaunched_at: { seconds: 1 } },
      originalExists: false,
    });
    assert.equal(denial?.message, ALREADY_RELAUNCHED_MESSAGE);
  });

  test("job d'origine supprimé : failed-precondition", () => {
    const denial = relaunchDenial({ dlq, originalExists: false });
    assert.equal(denial?.code, "failed-precondition");
    assert.notEqual(denial?.message, ALREADY_RELAUNCHED_MESSAGE);
  });

  test("dead letter absent : not-found", () => {
    assert.equal(relaunchDenial({ dlq: null, originalExists: false })?.code, "not-found");
  });
});
