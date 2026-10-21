/**
 * Erreurs des callables d'IA vers le client (audit #151, ticket #170) : un
 * refus du plafond d'IA porte `details.reason` et `details.scope`, pour que le
 * client affiche le message rédigé pour le membre. Un quota du fournisseur,
 * sous le même code, n'en porte pas : son message est le texte brut du
 * fournisseur. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { BudgetExceededError, budgetDenial, DEFAULT_AI_BUDGET_POLICY } from "../ai/budget";
import {
  AI_BUDGET_SCOPE,
  PROVIDER_ERROR_CALLABLE_MESSAGE,
  PROVIDER_QUOTA_CALLABLE_MESSAGE,
  UNEXPECTED_CALLABLE_MESSAGE,
  toHttpsError,
} from "../callable/_callableErrors";
import { moderationRefusal } from "../callable/moderationCallables";
import { GeminiError, GeminiQuotaExceededError } from "../gemini/client";
import { StoragePathRefusedError } from "../utils/storagePath";

function denialFor(reason: "cost" | "calls") {
  const denial = budgetDenial({
    spend:
      reason === "cost"
        ? { costUsd: 1_000, calls: 0, unpricedCalls: 0 }
        : { costUsd: 0, calls: DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser, unpricedCalls: 0 },
    policy: DEFAULT_AI_BUDGET_POLICY,
    usdToEur: 0.9,
  });
  assert.equal(denial?.reason, reason);
  return denial!;
}

describe("toHttpsError — plafond d'IA", () => {
  for (const reason of ["cost", "calls"] as const) {
    test(`plafond ${reason} : resource-exhausted, details.reason et details.scope posés`, async () => {
      const denial = denialFor(reason);
      const err = await toHttpsError(new BudgetExceededError(denial));
      assert.equal(err.code, "resource-exhausted");
      assert.equal(err.message, denial.message);
      assert.deepEqual(err.details, { reason, scope: AI_BUDGET_SCOPE });
    });
  }

  test("le message du plafond dit quand l'IA revient, sans montant ni identifiant", () => {
    for (const reason of ["cost", "calls"] as const) {
      const message = denialFor(reason).message;
      assert.match(message, /demain/);
      assert.doesNotMatch(message, /\d/);
      assert.doesNotMatch(message, /[€$]/);
    }
  });

  test("quota du fournisseur : même code, sans details, texte fixe", async () => {
    const err = await toHttpsError(new GeminiQuotaExceededError("429 RESOURCE_EXHAUSTED: quota"));
    assert.equal(err.code, "resource-exhausted");
    assert.equal(err.details, undefined);
    assert.equal(err.message, PROVIDER_QUOTA_CALLABLE_MESSAGE);
  });
});

describe("toHttpsError — aucun texte brut vers le client", () => {
  test("erreur du fournisseur : internal, texte fixe", async () => {
    const err = await toHttpsError(new GeminiError("500 INTERNAL: upstream connect error"));
    assert.equal(err.code, "internal");
    assert.equal(err.message, PROVIDER_ERROR_CALLABLE_MESSAGE);
  });

  test("erreur non typée : internal, texte fixe", async () => {
    for (const raw of [
      new Error("13 INTERNAL: RST_STREAM"),
      new TypeError("x is undefined"),
      "texte",
    ]) {
      const err = await toHttpsError(raw);
      assert.equal(err.code, "internal");
      assert.equal(err.message, UNEXPECTED_CALLABLE_MESSAGE);
    }
  });

  test("chemin refusé : permission-denied, message rédigé gardé", async () => {
    const err = await toHttpsError(new StoragePathRefusedError("x", "Fichier refusé."));
    assert.equal(err.code, "permission-denied");
    assert.equal(err.message, "Fichier refusé.");
  });
});

describe("moderationRefusal — plafond d'IA", () => {
  test("même details que les callables d'IA", () => {
    const err = moderationRefusal(new BudgetExceededError(denialFor("calls")));
    assert.equal(err?.code, "resource-exhausted");
    assert.deepEqual(err?.details, { reason: "calls", scope: AI_BUDGET_SCOPE });
  });
});
