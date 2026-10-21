/**
 * Client Gemini sur `@google/genai`.
 *
 * Le SDK tourne pour de vrai : seul `fetch` est remplacé, par une fonction qui
 * rend le JSON de l'API REST. Ces tests vérifient donc ce que le SDK envoie
 * (modèle, contenus, plafond de raisonnement, outil de recherche) et ce que
 * [toGeminiResponse] en lit (texte, jetons, image, grounding), sans réseau.
 */

import { test, describe, afterEach } from "node:test";
import assert from "node:assert/strict";

import {
  buildGeminiRequest,
  classifyError,
  createGenerativeModel,
  extractJsonObject,
  groundingOf,
  MIN_ATTEMPT_MS,
  quotaRetryDelayMs,
  thinkingTokensOf,
  toGeminiResponse,
} from "../gemini/client";

const realFetch = globalThis.fetch;

interface Captured {
  url: string;
  body: Record<string, unknown>;
  headers: Headers;
}

/** Remplace `fetch` et rend `status` + `payload` ; consigne chaque requête. */
function stubFetch(status: number, payload: unknown): Captured[] {
  const calls: Captured[] = [];
  globalThis.fetch = (async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({
      url: String(input),
      body: JSON.parse(String(init?.body ?? "{}")) as Record<string, unknown>,
      headers: new Headers(init?.headers),
    });
    return new Response(JSON.stringify(payload), {
      status,
      headers: { "content-type": "application/json" },
    });
  }) as typeof fetch;
  return calls;
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("createGenerativeModel — réponse texte", () => {
  test("lit le texte JSON, les jetons et la raison d'arrêt", async () => {
    const calls = stubFetch(200, {
      candidates: [
        {
          content: {
            role: "model",
            parts: [{ text: '```json\n{"titre": "Rougail' }, { text: ' saucisse"}\n```' }],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: {
        promptTokenCount: 1200,
        candidatesTokenCount: 300,
        thoughtsTokenCount: 500,
        totalTokenCount: 2000,
      },
      modelVersion: "gemini-2.5-flash",
    });

    const raw = await createGenerativeModel("cle-de-test", "gemini-2.5-flash").generateContent({
      contents: [{ role: "user", parts: [{ text: "Extrais la recette." }] }],
    });
    const response = toGeminiResponse(raw);

    assert.equal(calls.length, 1);
    assert.match(calls[0].url, /models\/gemini-2\.5-flash:generateContent/);
    assert.equal(calls[0].headers.get("x-goog-api-key"), "cle-de-test");
    assert.deepEqual(calls[0].body.contents, [
      { role: "user", parts: [{ text: "Extrais la recette." }] },
    ]);

    assert.equal(JSON.parse(extractJsonObject(response.text)).titre, "Rougail saucisse");
    assert.equal(response.candidates[0].finishReason, "STOP");
    assert.equal(response.usageMetadata?.promptTokenCount, 1200);
    assert.equal(response.usageMetadata?.candidatesTokenCount, 300);
    assert.equal(response.usageMetadata?.totalTokenCount, 2000);
    assert.equal(thinkingTokensOf(response.usageMetadata), 500);
    assert.equal(response.grounding, undefined);
  });

  test("une réponse bloquée rend un texte vide sans lever", async () => {
    stubFetch(200, {
      candidates: [{ finishReason: "SAFETY" }],
      usageMetadata: { promptTokenCount: 10, totalTokenCount: 10 },
    });
    const response = toGeminiResponse(
      await createGenerativeModel("k", "gemini-2.5-flash").generateContent({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      }),
    );
    assert.equal(response.text, "");
    assert.equal(response.candidates[0].finishReason, "SAFETY");
  });
});

describe("createGenerativeModel — réponse image", () => {
  test("l'image revient en inlineData, à côté du texte", async () => {
    const calls = stubFetch(200, {
      candidates: [
        {
          content: {
            role: "model",
            parts: [
              { text: "Voici." },
              { inlineData: { mimeType: "image/png", data: "iVBORw==" } },
            ],
          },
          finishReason: "STOP",
        },
      ],
      usageMetadata: { promptTokenCount: 50, candidatesTokenCount: 1290, totalTokenCount: 1340 },
    });

    const response = toGeminiResponse(
      await createGenerativeModel("k", "gemini-3.1-flash-lite-image").generateContent({
        contents: [
          {
            role: "user",
            parts: [
              { inlineData: { mimeType: "image/jpeg", data: "AAAA" } },
              { text: "Embellis." },
            ],
          },
        ],
      }),
    );

    assert.match(calls[0].url, /models\/gemini-3\.1-flash-lite-image:generateContent/);
    const inline = response.candidates[0].content?.parts?.[1]?.inlineData;
    assert.deepEqual(inline, { mimeType: "image/png", data: "iVBORw==" });
    assert.equal(response.text, "Voici.");
    assert.equal(response.usageMetadata?.candidatesTokenCount, 1290);
  });
});

describe("erreurs de l'API", () => {
  test("un 429 est un quota dépassé, et le SDK ne retente pas de lui-même", async () => {
    const calls = stubFetch(429, {
      error: { code: 429, message: "Quota exceeded", status: "RESOURCE_EXHAUSTED" },
    });
    let caught: unknown = null;
    try {
      await createGenerativeModel("k", "gemini-2.5-flash").generateContent({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      });
    } catch (err) {
      caught = err;
    }
    assert.notEqual(caught, null);
    assert.equal(classifyError(caught), "QUOTA_EXCEEDED");
    // Les réessais restent ceux de `callGemini` : un réessai du SDK en plus
    // multiplierait les appels facturés sans trace dans les journaux.
    assert.equal(calls.length, 1);
  });

  test("un 400 n'est pas un quota", async () => {
    stubFetch(400, {
      error: { code: 400, message: "Invalid argument", status: "INVALID_ARGUMENT" },
    });
    let caught: unknown = null;
    try {
      await createGenerativeModel("k", "gemini-2.5-flash").generateContent({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      });
    } catch (err) {
      caught = err;
    }
    assert.equal(classifyError(caught), "ERROR");
  });

  test("un message sans code reste reconnu", () => {
    assert.equal(classifyError(new Error("RESOURCE_EXHAUSTED")), "QUOTA_EXCEEDED");
    assert.equal(classifyError(new Error("fetch failed")), "ERROR");
    assert.equal(classifyError(new Error("Gemini call timeout after 294290ms")), "ERROR");
    assert.equal(classifyError(new Error("got status 429 from upstream")), "QUOTA_EXCEEDED");
  });

  // Corps de l'erreur relevé dans Cloud Logging le 21 octobre 2026.
  const CREDITS_DEPLETED = {
    error: {
      code: 402,
      message:
        "Your prepayment credits are depleted. Please go to AI Studio at https://ai.studio/projects to manage your project and billing.",
      status: "RESOURCE_EXHAUSTED",
    },
  };

  test("un 402 (crédits épuisés) est définitif, pas un quota", async () => {
    const calls = stubFetch(402, CREDITS_DEPLETED);
    let caught: unknown = null;
    try {
      await createGenerativeModel("k", "gemini-2.5-flash").generateContent({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      });
    } catch (err) {
      caught = err;
    }
    assert.notEqual(caught, null);
    assert.equal(classifyError(caught), "CREDITS_EXHAUSTED");
    assert.equal(calls.length, 1);
  });

  test("le message exact d'un 402, sans code HTTP, est reconnu", () => {
    assert.equal(classifyError(new Error(JSON.stringify(CREDITS_DEPLETED))), "CREDITS_EXHAUSTED");
    assert.equal(classifyError({ status: 402, message: "x" }), "CREDITS_EXHAUSTED");
  });
});

describe("quotaRetryDelayMs", () => {
  test("backoff exponentiel quand le temps ne manque pas", () => {
    assert.equal(quotaRetryDelayMs(1, 300_000), 2_000);
    assert.equal(quotaRetryDelayMs(3, 300_000), 8_000);
    assert.equal(quotaRetryDelayMs(10, 300_000), 60_000);
  });

  test("la pause est raccourcie pour laisser une tentative de MIN_ATTEMPT_MS", () => {
    assert.equal(quotaRetryDelayMs(6, 20_000), 20_000 - MIN_ATTEMPT_MS);
  });

  test("plus de relance quand il ne reste pas de quoi tenter", () => {
    assert.equal(quotaRetryDelayMs(1, MIN_ATTEMPT_MS), null);
    assert.equal(quotaRetryDelayMs(1, 0), null);
    assert.equal(quotaRetryDelayMs(1, -4_749), null);
  });
});

describe("buildGeminiRequest", () => {
  test("sans réglage, aucune config n'est envoyée", () => {
    const request = buildGeminiRequest("gemini-2.5-flash", [{ text: "x" }]);
    assert.deepEqual(request, {
      model: "gemini-2.5-flash",
      contents: [{ role: "user", parts: [{ text: "x" }] }],
    });
  });

  test("le plafond de raisonnement passe dans thinkingConfig, zéro compris", () => {
    const request = buildGeminiRequest("gemini-2.5-flash", [{ text: "x" }], { thinkingBudget: 0 });
    assert.deepEqual(request.config, { thinkingConfig: { thinkingBudget: 0 } });
  });

  test("le plafond atteint l'API sous generationConfig.thinkingConfig", async () => {
    const calls = stubFetch(200, { candidates: [] });
    const { model, ...rest } = buildGeminiRequest("gemini-2.5-flash", [{ text: "x" }], {
      thinkingBudget: 512,
      googleSearch: true,
    });
    await createGenerativeModel("k", model).generateContent(rest);
    assert.deepEqual((calls[0].body.generationConfig as Record<string, unknown>).thinkingConfig, {
      thinkingBudget: 512,
    });
    assert.deepEqual(calls[0].body.tools, [{ googleSearch: {} }]);
  });
});

describe("grounding (recherche Google)", () => {
  test("sources dédoublonnées, sans URI écartées, bloc de suggestions conservé", async () => {
    stubFetch(200, {
      candidates: [
        {
          content: { role: "model", parts: [{ text: "Le rougail se sert avec du riz." }] },
          finishReason: "STOP",
          groundingMetadata: {
            webSearchQueries: ["rougail saucisse recette"],
            searchEntryPoint: { renderedContent: "<div>Suggestions Google</div>" },
            groundingChunks: [
              { web: { uri: "https://a.example/rougail", title: "a.example" } },
              { web: { uri: "https://a.example/rougail", title: "a.example" } },
              { web: { title: "sans adresse" } },
              { web: { uri: "https://b.example/riz" } },
            ],
          },
        },
      ],
      usageMetadata: {
        promptTokenCount: 100,
        candidatesTokenCount: 20,
        toolUsePromptTokenCount: 400,
        totalTokenCount: 520,
      },
    });

    const response = toGeminiResponse(
      await createGenerativeModel("k", "gemini-2.5-flash").generateContent({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      }),
    );

    assert.deepEqual(response.grounding, {
      sources: [
        { uri: "https://a.example/rougail", title: "a.example" },
        { uri: "https://b.example/riz" },
      ],
      webSearchQueries: ["rougail saucisse recette"],
      searchEntryPointHtml: "<div>Suggestions Google</div>",
    });
    // Les jetons du résultat de recherche sont de l'entrée, pas du raisonnement.
    assert.equal(thinkingTokensOf(response.usageMetadata), 0);
  });

  test("sans métadonnées, pas de grounding", () => {
    assert.equal(groundingOf(undefined), undefined);
  });
});

describe("getClient — hôte figé", () => {
  test("ignore GOOGLE_GEMINI_BASE_URL et GOOGLE_GENAI_USE_VERTEXAI", async () => {
    const saved = {
      base: process.env.GOOGLE_GEMINI_BASE_URL,
      vertex: process.env.GOOGLE_GENAI_USE_VERTEXAI,
    };
    process.env.GOOGLE_GEMINI_BASE_URL = "https://exemple.invalid";
    process.env.GOOGLE_GENAI_USE_VERTEXAI = "true";
    try {
      const calls = stubFetch(200, {
        candidates: [{ content: { role: "model", parts: [{ text: "ok" }] } }],
      });
      // Clé inédite : force la construction d'un nouveau client.
      await createGenerativeModel("cle-hote-fige", "gemini-2.5-flash").generateContent({
        contents: [{ role: "user", parts: [{ text: "x" }] }],
      });
      assert.equal(calls.length, 1);
      assert.ok(
        calls[0].url.startsWith("https://generativelanguage.googleapis.com/"),
        calls[0].url,
      );
    } finally {
      if (saved.base === undefined) delete process.env.GOOGLE_GEMINI_BASE_URL;
      else process.env.GOOGLE_GEMINI_BASE_URL = saved.base;
      if (saved.vertex === undefined) delete process.env.GOOGLE_GENAI_USE_VERTEXAI;
      else process.env.GOOGLE_GENAI_USE_VERTEXAI = saved.vertex;
    }
  });
});
