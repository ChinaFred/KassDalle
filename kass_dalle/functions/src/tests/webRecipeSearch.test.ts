/**
 * « Chercher sur le web » : le prompt, ce qui est facturé, la traduction des
 * erreurs et le plafond par compte.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { HttpsError } from "firebase-functions/v2/https";

import { inputTokensOf } from "../gemini/client";
import {
  WEB_RECIPE_SEARCH_FEATURE,
  buildWebRecipeSearchPrompt,
  isGroundedCall,
  recordSearchUsage,
} from "../gemini/webRecipeSearch";
import {
  AI_DAILY_BUDGET_REASON,
  WEB_SEARCH_ENGINE_REASON,
  WEB_SEARCH_QUERY_REASON,
  WEB_SEARCH_QUOTA_REASON,
  readWebSearchQuery,
  webSearchHttpsError,
  webSearchLimit,
} from "../callable/webSearchCallable";
import { WebSearchQuotaError, WebSearchUnreadableError } from "../web/webSearchFlow";
import { BudgetExceededError, FOUNDER_DAILY_BUDGET_MULTIPLIER } from "../ai/budget";
import { builtinPricingTable, missingUnitPriceFields } from "../ai/pricing";

describe("prompt", () => {
  test("la requête est citée, sans ses guillemets", () => {
    const prompt = buildWebRecipeSearchPrompt('blanquette "de veau"');
    assert.ok(prompt.includes("« blanquette  de veau »"));
    assert.match(prompt, /recettes de cuisine/);
    assert.match(prompt, /YouTube, TikTok, Instagram, Facebook, Pinterest/);
  });

  test("le poste porte sa clé de coût", () => {
    assert.equal(WEB_RECIPE_SEARCH_FEATURE, "web_recipe_search");
  });
});

describe("ce qui est facturé", () => {
  test("le résultat de la recherche relu par le modèle compte en entrée", () => {
    assert.equal(inputTokensOf({ promptTokenCount: 120, toolUsePromptTokenCount: 900 }), 1020);
    assert.equal(inputTokensOf({ promptTokenCount: 120 }), 120);
    assert.equal(inputTokensOf(undefined), 0);
  });

  test("un appel ancré = au moins une requête Google ou une page citée", () => {
    assert.equal(isGroundedCall({ sources: [], webSearchQueries: ["q"] }), true);
    assert.equal(isGroundedCall({ sources: [{ uri: "https://a" }], webSearchQueries: [] }), true);
    assert.equal(isGroundedCall({ sources: [], webSearchQueries: [] }), false);
    assert.equal(isGroundedCall(undefined), false);
  });

  test("le prix de la recherche est semé sur une entrée qui ne l'a pas", () => {
    const missing = missingUnitPriceFields(
      { "gemini-2.5-flash": { input_per_million: 0.3, output_per_million: 2.5 } },
      builtinPricingTable(),
    );
    assert.deepEqual(missing, [
      { model: "gemini-2.5-flash", field: "grounded_search_per_unit", value: 0.035 },
    ]);
  });

  test("un zéro saisi depuis l'écran n'est jamais recouvert", () => {
    const missing = missingUnitPriceFields(
      {
        "gemini-2.5-flash": {
          input_per_million: 0.3,
          output_per_million: 2.5,
          grounded_search_per_unit: 0,
        },
      },
      builtinPricingTable(),
    );
    assert.deepEqual(missing, []);
  });
});

describe("plafond et erreurs", () => {
  test("cinquante par jour, cent fois plus pour le fondateur", () => {
    assert.equal(webSearchLimit(1), 50);
    assert.equal(webSearchLimit(FOUNDER_DAILY_BUDGET_MULTIPLIER), 5000);
    assert.equal(webSearchLimit(0), 50);
  });

  test("le plafond atteint porte une raison que le client reconnaît", () => {
    const err = webSearchHttpsError(new WebSearchQuotaError(50));
    assert.equal(err.code, "resource-exhausted");
    assert.deepEqual(err.details, { reason: WEB_SEARCH_QUOTA_REASON, limit: 50, remaining: 0 });
  });

  test("le plafond de dépense d'IA a une autre raison", () => {
    const err = webSearchHttpsError(
      new BudgetExceededError({ reason: "cost", message: "Plafond atteint." }),
    );
    assert.equal(err.code, "resource-exhausted");
    assert.equal((err.details as { reason: string }).reason, AI_DAILY_BUDGET_REASON);
  });

  test("moteur indisponible ou réponse illisible : réessayable, raison du moteur", () => {
    for (const err of [
      webSearchHttpsError(new Error("503")),
      webSearchHttpsError(new WebSearchUnreadableError()),
    ]) {
      assert.equal(err.code, "unavailable");
      assert.deepEqual(err.details, { reason: WEB_SEARCH_ENGINE_REASON });
    }
  });

  test("la requête est refusée vide ou trop longue, jamais coupée", async () => {
    const reported: number[] = [];
    const report = async (length: number) => {
      reported.push(length);
    };
    assert.equal(await readWebSearchQuery({ query: "  quiche  " }, report), "quiche");
    assert.equal((await readWebSearchQuery({ query: "a".repeat(200) }, report)).length, 200);
    assert.deepEqual(reported, []);
    const refused = (err: unknown) => {
      assert.ok(err instanceof HttpsError);
      assert.equal(err.code, "invalid-argument");
      assert.deepEqual(err.details, { reason: WEB_SEARCH_QUERY_REASON });
      return true;
    };
    await assert.rejects(readWebSearchQuery({ query: "  " }, report), refused);
    await assert.rejects(readWebSearchQuery({}, report), refused);
    await assert.rejects(readWebSearchQuery({ query: "a".repeat(201) }, report), refused);
    // Chaque refus est journalisé, par sa longueur seule.
    assert.deepEqual(reported, [0, 0, 201]);
  });
});

describe("consommation d'un appel abouti", () => {
  const entry = {
    feature: WEB_RECIPE_SEARCH_FEATURE,
    provider: "gemini" as const,
    model: "gemini-test",
    userId: "u1",
    correlationId: "c1",
    callId: "k1",
    inputTokens: 1200,
    outputTokens: 80,
    groundedSearchCount: 1,
  };

  test("une écriture réussie ne signale rien", async () => {
    const written: unknown[] = [];
    const reported: unknown[] = [];
    const ok = await recordSearchUsage(
      entry,
      async (e) => {
        written.push(e);
      },
      async (err) => {
        reported.push(err);
      },
    );
    assert.equal(ok, true);
    assert.deepEqual(written, [entry]);
    assert.deepEqual(reported, []);
  });

  test("une écriture en échec est signalée et ne lève pas", async () => {
    const failure = new Error("Firestore indisponible");
    const reported: unknown[] = [];
    const ok = await recordSearchUsage(
      entry,
      async () => {
        throw failure;
      },
      async (err) => {
        reported.push(err);
      },
    );
    // L'appel est facturé : la recherche rend ses pages, et l'échec est
    // journalisé au lieu de lever (sinon la place serait rendue).
    assert.equal(ok, false);
    assert.deepEqual(reported, [failure]);
  });
});
