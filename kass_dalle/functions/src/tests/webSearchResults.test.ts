/**
 * « Chercher sur le web » : des liens de Google aux cartes.
 *
 * Exclusion des vidéos et réseaux sociaux, adresses https seules, résolution
 * des liens de redirection, page illisible gardée sans vignette, `directImport`,
 * dédoublonnage, clé du cache. Sans réseau : la lecture
 * des pages passe par un faux `fetcher`.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";

import { WebFetchError, type FetchedResource } from "../web/safeFetch";
import {
  WEB_SEARCH_CACHE_TTL_MS,
  WEB_SEARCH_CACHE_VERSION,
  WEB_SEARCH_MAX_RESULTS,
  WEB_SEARCH_URL_MAX_CHARS,
  cardFromCache,
  cleanWebSearchQuery,
  detectPageLanguage,
  extractPageCard,
  httpsUrlOrNull,
  isCacheFresh,
  isExcludedHost,
  orderByLanguage,
  pickCards,
  primaryLanguageCode,
  resolveWebSource,
  sourceTitleIsExcluded,
  urlSuggestsFrench,
  webSearchCacheKey,
  type PageFetcher,
  type WebRecipeCard,
} from "../web/webSearchResults";

function fixture(name: string): string {
  return readFileSync(
    path.join(__dirname, "..", "..", "src", "tests", "fixtures", "web", name),
    "utf8",
  );
}

const REDIRECT = "https://vertexaisearch.cloud.google.com/grounding-api-redirect/AbCdEf123";

function page(finalUrl: string, html: string): FetchedResource {
  return {
    finalUrl,
    status: 200,
    contentType: "text/html",
    charset: "utf-8",
    body: Buffer.from(html, "utf8"),
  };
}

function failing(failure: WebFetchError["failure"], lastUrl: string | null): PageFetcher {
  return async () => {
    const err = new WebFetchError(failure, "échec simulé");
    err.lastUrl = lastUrl;
    throw err;
  };
}

describe("domaines écartés", () => {
  test("vidéos et réseaux sociaux, sous-domaines compris", () => {
    for (const host of [
      "youtube.com",
      "www.youtube.com",
      "m.youtube.com",
      "youtu.be",
      "www.tiktok.com",
      "instagram.com",
      "fr-fr.facebook.com",
      "www.pinterest.fr",
      "pinterest.com",
      "fr.pinterest.co.uk",
      "pin.it",
    ]) {
      assert.equal(isExcludedHost(host), true, host);
    }
  });

  test("un site de cuisine passe, même s'il contient un mot proche", () => {
    for (const host of [
      "www.marmiton.org",
      "cuisine.journaldesfemmes.fr",
      "notyoutube.com",
      "facebookrecettes.fr",
      "pinterestrecettes.fr",
    ]) {
      assert.equal(isExcludedHost(host), false, host);
    }
  });

  test("le titre de Google qui nomme un site écarté évite la lecture", () => {
    assert.equal(sourceTitleIsExcluded("youtube.com"), true);
    assert.equal(sourceTitleIsExcluded("marmiton.org"), false);
    assert.equal(sourceTitleIsExcluded("Blanquette de veau - YouTube"), false);
  });
});

describe("adresses https seules", () => {
  test("http, javascript: et data: sont refusés", () => {
    assert.equal(httpsUrlOrNull("http://exemple.fr/r"), null);
    assert.equal(httpsUrlOrNull("javascript:alert(1)"), null);
    assert.equal(httpsUrlOrNull("data:text/html,x"), null);
    assert.equal(httpsUrlOrNull(null), null);
  });

  test("une adresse relative est refusée, le fragment est retiré", () => {
    assert.equal(httpsUrlOrNull("/recette"), null);
    assert.equal(httpsUrlOrNull("https://exemple.fr/r#etape-2"), "https://exemple.fr/r");
  });

  test(`une adresse de plus de ${WEB_SEARCH_URL_MAX_CHARS} caractères est écartée`, () => {
    const base = "https://exemple.fr/r?q=";
    const atLimit = base + "a".repeat(WEB_SEARCH_URL_MAX_CHARS - base.length);
    assert.equal(httpsUrlOrNull(atLimit), atLimit);
    assert.equal(httpsUrlOrNull(atLimit + "a"), null);
    assert.equal(cardFromCache({ url: atLimit + "a", title: "R" }), null);
  });
});

describe("requête et cache", () => {
  test("la requête est nettoyée sans être coupée", () => {
    assert.equal(cleanWebSearchQuery("  blanquette\n de   veau "), "blanquette de veau");
    assert.equal(cleanWebSearchQuery("   "), null);
    assert.equal(cleanWebSearchQuery(42), null);
  });

  test("casse et espaces ne changent pas la clé, les accents si", () => {
    assert.equal(webSearchCacheKey("Blanquette  de VEAU"), webSearchCacheKey("blanquette de veau"));
    assert.notEqual(webSearchCacheKey("pâte"), webSearchCacheKey("pâté"));
    assert.match(webSearchCacheKey("x"), /^[0-9a-f]{64}$/);
  });

  test("la clé porte la version : une entrée de l'ancien prompt n'est plus servie", () => {
    assert.equal(WEB_SEARCH_CACHE_VERSION, 2);
    const unversioned = createHash("sha256").update("blanquette de veau").digest("hex");
    const v2 = createHash("sha256").update("v2:blanquette de veau").digest("hex");
    assert.notEqual(webSearchCacheKey("Blanquette de veau"), unversioned);
    assert.equal(webSearchCacheKey("Blanquette de veau"), v2);
  });

  test("une entrée sert sept jours, pas un instant de plus", () => {
    const now = Date.parse("2026-10-12T12:00:00Z");
    assert.equal(isCacheFresh(now - 1000, now), true);
    assert.equal(isCacheFresh(now - WEB_SEARCH_CACHE_TTL_MS + 1, now), true);
    assert.equal(isCacheFresh(now - WEB_SEARCH_CACHE_TTL_MS, now), false);
    assert.equal(isCacheFresh(NaN, now), false);
    assert.equal(isCacheFresh(now + 60_000, now), false);
  });

  test("une carte du cache en http est écartée", () => {
    assert.equal(cardFromCache({ url: "http://exemple.fr/r", title: "R" }), null);
  });

  test("une vieille entrée du cache avec vignette se lit, sans la vignette", () => {
    const card = cardFromCache({
      url: "https://www.exemple.fr/r",
      title: "R",
      imageUrl: "https://exemple.fr/i.jpg",
      directImport: true,
    });
    assert.ok(card);
    assert.equal("imageUrl" in card, false);
    assert.equal(card.site, "exemple.fr");
    assert.equal(card?.directImport, true);
  });
});

describe("lecture d'une page", () => {
  test("recette JSON-LD complète : directImport, titre, aucune image", () => {
    const fields = extractPageCard(fixture("graph_howtostep.html"));
    assert.equal(fields.directImport, true);
    assert.equal(fields.title, "Quiche lorraine – Le site");
    assert.equal("imageUrl" in fields, false);
    assert.equal(fields.description, "La vraie, sans fromage.");
  });

  test("page sans données structurées : pas de directImport, meta description", () => {
    const fields = extractPageCard(fixture("no_jsonld_blog.html"));
    assert.equal(fields.directImport, false);
    assert.equal(fields.description, "Blog");
  });
});

describe("langue d'une page", () => {
  const html = (head: string, body = "") =>
    `<!DOCTYPE html><html${head}><head></head><body>${body}</body></html>`;
  const jsonLd = (lang: string) =>
    `<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe",
      name: "R",
      inLanguage: lang,
    })}</script>`;

  test("codes de langue déclarés", () => {
    assert.equal(primaryLanguageCode("fr"), "fr");
    assert.equal(primaryLanguageCode("fr-BE"), "fr");
    assert.equal(primaryLanguageCode("fr_CA"), "fr");
    assert.equal(primaryLanguageCode(" EN-us "), "en");
    assert.equal(primaryLanguageCode("x-default"), null);
    assert.equal(primaryLanguageCode(""), null);
    assert.equal(primaryLanguageCode(null), null);
  });

  test("<html lang>, og:locale, inLanguage", () => {
    const url = "https://example.com/r";
    assert.equal(detectPageLanguage(html(' lang="fr-FR"'), url), "fr");
    assert.equal(detectPageLanguage(html(' lang="en"'), url), "other");
    assert.equal(
      detectPageLanguage(html("", '<meta property="og:locale" content="fr_CA">'), url),
      "fr",
    );
    assert.equal(detectPageLanguage(html(' lang="en"', jsonLd("fr")), url), "fr");
  });

  test("rien de déclaré : l'adresse seule, sinon inconnue", () => {
    assert.equal(detectPageLanguage(html(""), "https://www.cuisine.fr/r"), "fr");
    assert.equal(detectPageLanguage(html(""), "https://fr.example.com/r"), "fr");
    assert.equal(detectPageLanguage(html(""), "https://example.com/fr-be/r"), "fr");
    assert.equal(detectPageLanguage(html(""), "https://example.be/r"), "unknown");
    assert.equal(detectPageLanguage(null, "https://example.com/r"), "unknown");
    // Une déclaration l'emporte sur l'adresse.
    assert.equal(detectPageLanguage(html(' lang="en"'), "https://www.cuisine.fr/r"), "other");
    assert.equal(urlSuggestsFrench("https://example.com/frites/r"), false);
  });

  test("français, puis inconnue, puis autre langue ; tri stable ; rien d'écarté", () => {
    const items = [
      { id: "a", language: "other" as const },
      { id: "b", language: "unknown" as const },
      { id: "c", language: "fr" as const },
      { id: "d", language: "other" as const },
      { id: "e", language: "fr" as const },
    ];
    assert.deepEqual(
      orderByLanguage(items).map((i) => i.id),
      ["c", "e", "b", "a", "d"],
    );
  });
});

describe("résolution d'un lien de Google", () => {
  test("la redirection est suivie jusqu'à la page réelle", async () => {
    const outcome = await resolveWebSource({ uri: REDIRECT, title: "le-site.fr" }, async (url) => {
      assert.equal(url.toString(), REDIRECT);
      return page("https://www.le-site.fr/quiche", fixture("graph_howtostep.html"));
    });
    assert.ok(outcome.card);
    assert.equal(outcome.card.url, "https://www.le-site.fr/quiche");
    assert.equal(outcome.card.site, "le-site.fr");
    assert.equal(outcome.card.directImport, true);
    assert.equal("language" in outcome && outcome.language, "fr");
  });

  test("la langue de la page lue est relevée", async () => {
    const outcome = await resolveWebSource({ uri: REDIRECT }, async () =>
      page("https://www.example.com/r", '<html lang="en-US"><head></head></html>'),
    );
    assert.equal("language" in outcome && outcome.language, "other");
  });

  test("une page qui refuse d'être lue garde sa carte, sans extrait ni directImport", async () => {
    const outcome = await resolveWebSource(
      { uri: REDIRECT, title: "marmiton.org" },
      failing("blocked", "https://www.marmiton.org/recettes/blanquette.aspx"),
    );
    assert.ok(outcome.card);
    assert.equal(outcome.card.url, "https://www.marmiton.org/recettes/blanquette.aspx");
    assert.equal(outcome.card.title, "marmiton.org");
    assert.equal(outcome.card.snippet, null);
    assert.equal(outcome.card.directImport, false);
    assert.equal("degraded" in outcome && outcome.degraded, "blocked");
    assert.equal("language" in outcome && outcome.language, "unknown");
  });

  test("un refus de la garde SSRF ne rend jamais d'adresse", async () => {
    const outcome = await resolveWebSource(
      { uri: REDIRECT },
      failing("refused", "https://interne.example/admin"),
    );
    assert.equal(outcome.card, null);
  });

  test("un lien resté sur la redirection n'est pas rendu", async () => {
    const outcome = await resolveWebSource({ uri: REDIRECT }, failing("timeout", REDIRECT));
    assert.equal(outcome.card, null);
  });

  test("une page finale sur YouTube ou en http est écartée", async () => {
    const yt = await resolveWebSource({ uri: REDIRECT }, async () =>
      page("https://www.youtube.com/watch?v=x", "<html></html>"),
    );
    assert.equal(yt.card, null);
    const http = await resolveWebSource({ uri: REDIRECT }, async () =>
      page("http://exemple.fr/r", "<html></html>"),
    );
    assert.equal(http.card, null);
  });

  test("un titre de Google qui nomme un réseau social n'est pas suivi", async () => {
    let called = false;
    const outcome = await resolveWebSource({ uri: REDIRECT, title: "instagram.com" }, async () => {
      called = true;
      return page("https://instagram.com/p/x", "");
    });
    assert.equal(outcome.card, null);
    assert.equal(called, false);
  });

  test("une erreur inattendue n'est pas avalée", async () => {
    await assert.rejects(
      resolveWebSource({ uri: REDIRECT }, async () => {
        throw new TypeError("bug");
      }),
      TypeError,
    );
  });
});

describe("sélection des cartes", () => {
  const card = (url: string): WebRecipeCard => ({
    url,
    title: url,
    site: new URL(url).hostname,
    snippet: null,
    directImport: false,
  });

  test("dédoublonnées par adresse finale, dans l'ordre de Google", () => {
    const picked = pickCards([
      card("https://a.fr/r"),
      null,
      card("https://a.fr/r/"),
      card("https://b.fr/r"),
    ]);
    assert.deepEqual(
      picked.map((c) => c.url),
      ["https://a.fr/r", "https://b.fr/r"],
    );
  });

  test(`au plus ${WEB_SEARCH_MAX_RESULTS}`, () => {
    const many = Array.from({ length: 12 }, (_, i) => card(`https://s${i}.fr/r`));
    assert.equal(pickCards(many).length, WEB_SEARCH_MAX_RESULTS);
  });
});
