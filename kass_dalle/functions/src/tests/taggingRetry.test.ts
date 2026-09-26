/**
 * Le balisage ne se rejoue pas à l'identique quand sa réponse est coupée.
 *
 * Sur l'import du livre de Jamie Oliver (26 septembre 2026), 40 appels de
 * balisage sur 75 s'arrêtaient au plafond de sortie et ne rendaient rien de
 * lisible. Le job échouait, Cloud Tasks le rejouait depuis le début, et chaque
 * reprise refaisait la même réflexion au même prix.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  TAGGING_EFFORT,
  TAGGING_RETRY_EFFORT,
  TaggingTruncatedError,
  isTruncatedStop,
  runTaggingAttempts,
  taggingEfforts,
} from "../gemini/tagging";

type Effort = "low" | "medium" | "high";

describe("isTruncatedStop", () => {
  test("reconnaît le plafond de Claude et celui de Gemini", () => {
    assert.equal(isTruncatedStop("max_tokens"), true);
    assert.equal(isTruncatedStop("MAX_TOKENS"), true);
  });

  test("une fin normale, un refus ou l'absence de raison ne sont pas une coupure", () => {
    assert.equal(isTruncatedStop("end_turn"), false);
    assert.equal(isTruncatedStop("STOP"), false);
    assert.equal(isTruncatedStop("refusal"), false);
    assert.equal(isTruncatedStop(undefined), false);
  });
});

describe("taggingEfforts", () => {
  test("le premier effort est celui du balisage, le second celui de la reprise", () => {
    const efforts = taggingEfforts();
    assert.equal(efforts[0], TAGGING_EFFORT);
    if (TAGGING_EFFORT !== TAGGING_RETRY_EFFORT) assert.equal(efforts[1], TAGGING_RETRY_EFFORT);
  });

  test("ne répète pas deux fois le même effort", () => {
    const efforts = taggingEfforts();
    assert.equal(new Set(efforts).size, efforts.length);
  });

  test("la reprise ne réfléchit pas plus que le premier essai", () => {
    const order: Record<Effort, number> = { low: 0, medium: 1, high: 2 };
    assert.ok(order[TAGGING_RETRY_EFFORT] <= order[TAGGING_EFFORT]);
  });
});

describe("runTaggingAttempts", () => {
  test("une réponse complète ne demande qu'un appel", async () => {
    const calls: Effort[] = [];
    const result = await runTaggingAttempts({
      efforts: ["medium", "low"],
      call: async (effort) => {
        calls.push(effort);
        return { text: "ok", stopReason: "end_turn" };
      },
    });
    assert.deepEqual(calls, ["medium"]);
    assert.equal(result.text, "ok");
  });

  test("une réponse coupée est refaite une fois, à l'effort suivant", async () => {
    const calls: Effort[] = [];
    const truncated: Effort[] = [];
    const result = await runTaggingAttempts({
      efforts: ["medium", "low"],
      call: async (effort) => {
        calls.push(effort);
        return effort === "medium"
          ? { text: '{"cooklang": "', stopReason: "max_tokens" }
          : { text: "{}", stopReason: "end_turn" };
      },
      onTruncated: (effort) => {
        truncated.push(effort);
      },
    });
    assert.deepEqual(calls, ["medium", "low"]);
    assert.deepEqual(truncated, ["medium"]);
    assert.equal(result.text, "{}");
  });

  test("coupée à chaque effort, elle lève l'erreur dédiée", async () => {
    const calls: Effort[] = [];
    await assert.rejects(
      runTaggingAttempts({
        efforts: ["medium", "low"],
        call: async (effort) => {
          calls.push(effort);
          return { text: "", stopReason: "max_tokens" };
        },
      }),
      (err: unknown) => err instanceof TaggingTruncatedError,
    );
    assert.deepEqual(calls, ["medium", "low"]);
  });

  test("un effort unique n'est essayé qu'une fois", async () => {
    let calls = 0;
    await assert.rejects(
      runTaggingAttempts({
        efforts: ["low"],
        call: async () => {
          calls += 1;
          return { text: "", stopReason: "max_tokens" };
        },
      }),
      TaggingTruncatedError,
    );
    assert.equal(calls, 1);
  });

  test("une erreur de l'appel remonte telle quelle, sans essai suivant", async () => {
    const calls: Effort[] = [];
    await assert.rejects(
      runTaggingAttempts({
        efforts: ["medium", "low"],
        call: async (effort) => {
          calls.push(effort);
          throw new Error("réseau");
        },
      }),
      /réseau/,
    );
    assert.deepEqual(calls, ["medium"]);
  });
});
