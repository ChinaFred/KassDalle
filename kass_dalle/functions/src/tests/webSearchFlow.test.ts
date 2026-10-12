/**
 * « Chercher sur le web » : cache, plafond du jour, place rendue sur erreur.
 *
 * Ce qui compte pour la facture et pour l'utilisateur : une recherche servie
 * par le cache n'appelle pas le modèle et ne décompte rien ; un appel de
 * modèle en erreur rend sa place ; un appel qui a répondu la garde, même sans
 * recherche ancrée ni page retenue : il a été facturé.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import type { GeminiGrounding } from "../gemini/client";
import {
  WebSearchQuotaError,
  WebSearchUnreadableError,
  runWebSearch,
  type WebSearchDeps,
  type WebSearchPayload,
} from "../web/webSearchFlow";
import type { WebRecipeCard } from "../web/webSearchResults";

const CARD: WebRecipeCard = {
  url: "https://www.le-site.fr/quiche",
  title: "Quiche lorraine",
  site: "le-site.fr",
  snippet: null,
  directImport: true,
};

const GROUNDING: GeminiGrounding = {
  sources: [{ uri: "https://vertexaisearch.cloud.google.com/grounding-api-redirect/a" }],
  webSearchQueries: ["quiche lorraine recette"],
  searchEntryPointHtml: "<div>Google</div>",
};

/** Un faux branchement : un compteur en mémoire, et le journal des appels. */
function fakeDeps(over: Partial<WebSearchDeps> & { used?: number; cached?: WebSearchPayload }) {
  const calls: string[] = [];
  let used = over.used ?? 0;
  let cache: WebSearchPayload | null = over.cached ?? null;
  const deps: WebSearchDeps = {
    readCache: async () => {
      calls.push("readCache");
      return cache;
    },
    writeCache: async (p) => {
      calls.push("writeCache");
      cache = p;
    },
    readUsed: async () => used,
    reserve: async (limit) => {
      calls.push("reserve");
      if (used >= limit) return null;
      used += 1;
      return used;
    },
    refund: async () => {
      calls.push("refund");
      used -= 1;
    },
    search: async () => {
      calls.push("search");
      return GROUNDING;
    },
    resolve: async () => ({ card: CARD, language: "fr", degraded: null }),
    reportPartial: async () => {
      calls.push("reportPartial");
    },
    reportFailure: async (_err, refunded) => {
      calls.push(`reportFailure:${refunded}`);
    },
    ...over,
  };
  return { deps, calls, used: () => used };
}

describe("recherche web — enchaînement", () => {
  test("succès : une place prise, résultat mis en cache, restant rendu", async () => {
    const f = fakeDeps({ used: 3 });
    const res = await runWebSearch("quiche", 50, f.deps);
    assert.equal(res.fromCache, false);
    assert.equal(res.remaining, 46);
    assert.equal(res.results.length, 1);
    assert.equal(res.searchEntryPointHtml, "<div>Google</div>");
    assert.equal(f.used(), 4);
    assert.deepEqual(f.calls, ["readCache", "reserve", "search", "writeCache"]);
  });

  test("cache : ni modèle, ni décompte", async () => {
    const f = fakeDeps({
      used: 7,
      cached: { results: [CARD], searchEntryPointHtml: null, webSearchQueries: [] },
    });
    const res = await runWebSearch("quiche", 50, f.deps);
    assert.equal(res.fromCache, true);
    assert.equal(res.remaining, 43);
    assert.equal(f.used(), 7);
    assert.ok(!f.calls.includes("search"));
    assert.ok(!f.calls.includes("reserve"));
  });

  test("cache servi même plafond atteint", async () => {
    const f = fakeDeps({
      used: 50,
      cached: { results: [CARD], searchEntryPointHtml: null, webSearchQueries: [] },
    });
    const res = await runWebSearch("quiche", 50, f.deps);
    assert.equal(res.fromCache, true);
    assert.equal(res.remaining, 0);
  });

  test("plafond atteint : refus distinct, aucun appel de modèle", async () => {
    const f = fakeDeps({ used: 50 });
    await assert.rejects(runWebSearch("quiche", 50, f.deps), (err: unknown) => {
      assert.ok(err instanceof WebSearchQuotaError);
      assert.equal(err.limit, 50);
      return true;
    });
    assert.ok(!f.calls.includes("search"));
    assert.equal(f.used(), 50);
  });

  test("moteur indisponible : la place est rendue, l'erreur remonte", async () => {
    const f = fakeDeps({
      used: 10,
      search: async () => {
        throw new Error("503");
      },
    });
    await assert.rejects(runWebSearch("quiche", 50, f.deps), /503/);
    assert.equal(f.used(), 10);
    assert.ok(f.calls.includes("refund"));
    assert.ok(f.calls.includes("reportFailure:true"));
    assert.ok(!f.calls.includes("writeCache"));
  });

  test("réponse sans recherche ancrée : facturée, place gardée", async () => {
    const f = fakeDeps({
      used: 0,
      search: async () => ({ sources: [], webSearchQueries: [] }),
    });
    await assert.rejects(runWebSearch("quiche", 50, f.deps), WebSearchUnreadableError);
    assert.equal(f.used(), 1);
    assert.ok(!f.calls.includes("refund"));
    assert.ok(f.calls.includes("reportFailure:false"));
    assert.ok(!f.calls.includes("writeCache"));
  });

  test("réponse vide (undefined) : facturée, place gardée", async () => {
    const f = fakeDeps({ used: 2, search: async () => undefined });
    await assert.rejects(runWebSearch("quiche", 50, f.deps), WebSearchUnreadableError);
    assert.equal(f.used(), 3);
    assert.ok(!f.calls.includes("refund"));
  });

  test("lecture d'une page en erreur inattendue : place gardée, erreur remontée", async () => {
    const f = fakeDeps({
      used: 0,
      resolve: async () => {
        throw new TypeError("bug");
      },
    });
    await assert.rejects(runWebSearch("quiche", 50, f.deps), TypeError);
    assert.equal(f.used(), 1);
    assert.ok(!f.calls.includes("refund"));
    assert.ok(f.calls.includes("reportFailure:false"));
  });

  test("recherche aboutie sans page retenue : décomptée, pas mise en cache", async () => {
    const f = fakeDeps({
      used: 0,
      resolve: async () => ({ card: null, dropped: "excluded" }),
    });
    const res = await runWebSearch("quiche", 50, f.deps);
    assert.equal(res.results.length, 0);
    assert.equal(res.remaining, 49);
    assert.equal(f.used(), 1);
    assert.ok(!f.calls.includes("writeCache"));
    assert.ok(!f.calls.includes("refund"));
    assert.ok(f.calls.includes("reportPartial"));
  });

  test("pages en français d'abord, avant la coupe à huit, ordre de Google gardé", async () => {
    const langs: Array<"fr" | "other" | "unknown"> = [
      "other",
      "unknown",
      "fr",
      "other",
      "fr",
      "unknown",
      "other",
      "other",
      "other",
      "fr",
    ];
    const sources = langs.map((_, i) => ({ uri: `https://g.example/${i}` }));
    const f = fakeDeps({
      used: 0,
      search: async () => ({ ...GROUNDING, sources }),
      resolve: async (s) => {
        const i = Number(s.uri.split("/").pop());
        return {
          card: { ...CARD, url: `https://s${i}.example/r`, site: `s${i}.example` },
          language: langs[i],
          degraded: null,
        };
      },
    });
    const res = await runWebSearch("quiche", 50, f.deps);
    assert.deepEqual(
      res.results.map((c) => c.site),
      [2, 4, 9, 1, 5, 0, 3, 6].map((i) => `s${i}.example`),
    );
  });

  test("le plafond du fondateur multiplie, sans changer la règle", async () => {
    const f = fakeDeps({ used: 4999 });
    const res = await runWebSearch("quiche", 5000, f.deps);
    assert.equal(res.remaining, 0);
    await assert.rejects(
      runWebSearch("tarte", 5000, fakeDeps({ used: 5000 }).deps),
      WebSearchQuotaError,
    );
  });
});
