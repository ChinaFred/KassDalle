/**
 * « Chercher sur le web » : des liens de Google aux cartes de l'Explorer.
 *
 * La recherche ancrée de Gemini rend des pages citées sous forme de liens de
 * redirection (`vertexaisearch.cloud.google.com/grounding-api-redirect/…`).
 * Ce module suit chaque lien jusqu'à la page réelle, par `fetchPublicResource`
 * (garde SSRF, redirections revérifiées), et en tire ce que la carte affiche :
 * titre, site, extrait. `directImport` dit si la page décrit sa recette en
 * `schema.org/Recipe` complet : le client ne l'affiche pas, la callable le
 * compte dans son journal.
 *
 * La langue de chaque page est relevée aussi (`<html lang>`, `og:locale`,
 * `inLanguage` du JSON-LD) : les pages en français passent devant, sans que
 * les autres soient écartées.
 *
 * Aucune image n'est relevée : la carte montre une icône. Une vignette tierce
 * chargée par l'appareil donnerait l'adresse IP du lecteur au site, et
 * afficherait une image qui n'est pas passée par la modération.
 *
 * Le texte des pages est **non fiable** : il ne sert qu'à remplir ces champs
 * courts, renvoyés tels quels au client, et n'entre jamais dans un prompt.
 *
 * Tout ce qui ne touche pas le réseau est pur et testé par
 * `tests/webSearchResults.test.ts`.
 */

import { createHash } from "node:crypto";

import type { GeminiGroundingSource } from "../gemini/client";
import {
  cleanText,
  extractJsonLdRecipes,
  htmlLangOf,
  isCompleteRecipe,
  metaContent,
  pageTitleOf,
} from "./recipePage";
import {
  WebFetchError,
  decodeHtml,
  fetchPublicResource,
  type FetchOptions,
  type FetchedResource,
  type FetchFailure,
} from "./safeFetch";

/** Cartes rendues au plus. */
export const WEB_SEARCH_MAX_RESULTS = 8;

/**
 * Liens de Google suivis au plus. Un peu plus que les cartes rendues : une
 * partie tombe (réseau social, page illisible, doublon).
 */
export const WEB_SEARCH_MAX_SOURCES = 12;

/** Longueur maximale d'une requête, en caractères. */
export const WEB_SEARCH_QUERY_MAX_CHARS = 200;

/**
 * Longueur maximale d'une adresse rendue au client, en caractères. Au-delà,
 * l'adresse est écartée : aucune page de recette n'en a besoin, et une
 * adresse démesurée gonfle la réponse et le cache.
 */
export const WEB_SEARCH_URL_MAX_CHARS = 2048;

/** Longueur maximale d'un extrait et d'un titre renvoyés au client. */
export const WEB_SEARCH_SNIPPET_MAX_CHARS = 300;
export const WEB_SEARCH_TITLE_MAX_CHARS = 160;

/** Durée de vie d'une entrée du cache partagé. */
export const WEB_SEARCH_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/**
 * Lecture d'une page de résultat : 1,5 Mo, 6 s.
 *
 * Plus serré que l'import (3 Mo, 10 s) : on ne lit que l'en-tête et le
 * JSON-LD, et huit pages partent en même temps pendant que l'utilisateur
 * attend.
 */
export const WEB_SEARCH_PAGE_FETCH_OPTIONS: FetchOptions = {
  accept: ["text/html", "application/xhtml+xml"],
  maxBytes: 1_500_000,
  timeoutMs: 6_000,
  acceptHeader: "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1",
};

/** Hôte des liens de redirection de la recherche ancrée. */
export const GROUNDING_REDIRECT_HOST = "vertexaisearch.cloud.google.com";

/** Vidéos et réseaux sociaux : écartés, domaine et sous-domaines. */
export const EXCLUDED_WEB_DOMAINS: readonly string[] = [
  "youtube.com",
  "youtu.be",
  "tiktok.com",
  "instagram.com",
  "facebook.com",
  "fb.com",
  "fb.watch",
  "pin.it",
];

/** Pinterest publie sous un domaine par pays : pinterest.fr, pinterest.co.uk… */
const PINTEREST = /(^|\.)pinterest\.[a-z]{2,3}(\.[a-z]{2})?$/;

/** Une carte, telle que le client la reçoit. Toutes les adresses sont en https. */
export interface WebRecipeCard {
  url: string;
  title: string;
  site: string;
  snippet: string | null;
  directImport: boolean;
}

// ── Requête ──────────────────────────────────────────────────────────────────

/**
 * Requête lisible : caractères de contrôle retirés, espaces resserrées, forme
 * NFC. `null` si rien ne reste.
 */
export function cleanWebSearchQuery(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  let out = "";
  for (const ch of raw.normalize("NFC")) out += ch.charCodeAt(0) < 32 ? " " : ch;
  const cleaned = out.replace(/\s+/g, " ").trim();
  return cleaned.length > 0 ? cleaned : null;
}

/**
 * Version des entrées du cache, entrée dans le hash de la clé.
 *
 * À incrémenter quand le prompt ou l'ordre des résultats change : les
 * entrées écrites avant ne sont plus servies, et s'effacent à leur
 * expiration (`expires_at`). Version 2 : pages en français d'abord.
 */
export const WEB_SEARCH_CACHE_VERSION = 2;

/**
 * Clé du cache : la version, puis la requête en minuscules, espaces
 * resserrées.
 *
 * Les accents restent : « pâte » et « pâté » sont deux plats, et Google ne
 * rend pas les mêmes pages pour l'un et l'autre.
 */
export function webSearchCacheKey(query: string): string {
  const normalized = (cleanWebSearchQuery(query) ?? "").toLocaleLowerCase("fr");
  return createHash("sha256").update(`v${WEB_SEARCH_CACHE_VERSION}:${normalized}`).digest("hex");
}

/** Vrai si l'entrée du cache, écrite à `cachedAtMs`, sert encore à `nowMs`. */
export function isCacheFresh(cachedAtMs: number, nowMs: number): boolean {
  return (
    Number.isFinite(cachedAtMs) &&
    cachedAtMs <= nowMs &&
    nowMs - cachedAtMs < WEB_SEARCH_CACHE_TTL_MS
  );
}

// ── Adresses ─────────────────────────────────────────────────────────────────

/** Vrai si l'hôte est une vidéo ou un réseau social écarté. */
export function isExcludedHost(host: string): boolean {
  const h = host.toLowerCase().replace(/\.$/, "");
  if (PINTEREST.test(h)) return true;
  return EXCLUDED_WEB_DOMAINS.some((d) => h === d || h.endsWith(`.${d}`));
}

/**
 * Adresse https absolue, sans fragment, d'au plus [WEB_SEARCH_URL_MAX_CHARS]
 * caractères, ou `null`.
 *
 * Le client n'ouvre que de l'https : une page en http resterait lisible par
 * quiconque sur le réseau, et une adresse `javascript:` ou `data:` ne doit
 * jamais atteindre un `launchUrl`.
 */
export function httpsUrlOrNull(href: string | null | undefined): string | null {
  if (!href || !URL.canParse(href)) return null;
  const url = new URL(href);
  if (url.protocol !== "https:" || !url.hostname) return null;
  url.hash = "";
  const out = url.toString();
  return out.length > WEB_SEARCH_URL_MAX_CHARS ? null : out;
}

/** Site affiché : l'hôte sans « www. ». */
export function siteOf(url: string): string {
  return new URL(url).hostname.replace(/^www\./i, "");
}

/** Vrai si l'adresse finale peut être rendue au client. */
export function isDisplayableFinalUrl(url: string | null): url is string {
  if (!url) return false;
  const https = httpsUrlOrNull(url);
  if (!https) return false;
  const host = new URL(https).hostname.toLowerCase();
  return host !== GROUNDING_REDIRECT_HOST && !isExcludedHost(host);
}

/**
 * Vrai si le titre d'une source de Google nomme déjà un site écarté.
 *
 * La recherche ancrée met le plus souvent le domaine dans le titre
 * (« youtube.com ») : on évite alors de suivre le lien pour rien.
 */
export function sourceTitleIsExcluded(title: string | undefined): boolean {
  const t = (title ?? "").trim().toLowerCase();
  return /^[a-z0-9.-]+\.[a-z]{2,}$/.test(t) && isExcludedHost(t);
}

// ── Langue ───────────────────────────────────────────────────────────────────

/**
 * Langue d'une page, pour l'ordre des cartes : français, autre langue, ou
 * inconnue (rien de déclaré, page illisible).
 */
export type PageLanguage = "fr" | "other" | "unknown";

/**
 * Code de langue principal d'une valeur déclarée (`fr`, `fr-BE`, `fr_CA`,
 * `en-US`) ; `null` si la valeur n'en porte pas (`x-default`, vide).
 */
export function primaryLanguageCode(value: string | null | undefined): string | null {
  const m = /^\s*([a-z]{2,3})(?:[-_][a-z0-9]+)*\s*$/i.exec(value ?? "");
  return m ? m[1].toLowerCase() : null;
}

/**
 * Indice tiré de l'adresse quand la page ne déclare rien : domaine en `.fr`,
 * sous-domaine `fr.`, ou chemin qui commence par `/fr/` ou `/fr-xx/`. Rien
 * d'autre : `.be`, `.ch` et `.ca` publient aussi en néerlandais, en allemand
 * et en anglais.
 */
export function urlSuggestsFrench(url: string): boolean {
  if (!URL.canParse(url)) return false;
  const u = new URL(url);
  const host = u.hostname.toLowerCase().replace(/\.$/, "");
  return (
    host.endsWith(".fr") || host.startsWith("fr.") || /^\/fr(?:[-_][a-z]{2})?\//i.test(u.pathname)
  );
}

/**
 * Langue d'une page : `inLanguage` de la recette JSON-LD, puis
 * `<html lang>`, puis `og:locale`, puis l'indice de l'adresse. Le texte de
 * la page n'est pas analysé.
 */
export function detectPageLanguage(html: string | null, url: string): PageLanguage {
  if (html != null) {
    const { recipes } = extractJsonLdRecipes(html);
    const declared = [
      ...recipes.map((r) => r.inLanguage),
      htmlLangOf(html),
      metaContent(html, "og:locale"),
    ];
    for (const value of declared) {
      const code = primaryLanguageCode(value);
      if (code) return code === "fr" ? "fr" : "other";
    }
  }
  return urlSuggestsFrench(url) ? "fr" : "unknown";
}

const LANGUAGE_RANK: Record<PageLanguage, number> = { fr: 0, unknown: 1, other: 2 };

/**
 * Pages en français d'abord, puis de langue inconnue, puis dans une autre
 * langue. Tri stable : l'ordre de Google est gardé dans chaque groupe.
 * Aucune page n'est écartée.
 */
export function orderByLanguage<T extends { language: PageLanguage }>(items: readonly T[]): T[] {
  return items
    .map((item, index) => ({ item, index }))
    .sort(
      (a, b) =>
        LANGUAGE_RANK[a.item.language] - LANGUAGE_RANK[b.item.language] || a.index - b.index,
    )
    .map((e) => e.item);
}

// ── Page ─────────────────────────────────────────────────────────────────────

function clip(text: string | null | undefined, max: number): string | null {
  const t = cleanText(text ?? "");
  if (!t) return null;
  return t.length > max ? `${t.slice(0, max - 1).trimEnd()}…` : t;
}

/** Ce qu'une page donne à sa carte. */
export interface PageCardFields {
  title: string | null;
  description: string | null;
  directImport: boolean;
}

/**
 * Titre, description et `directImport` d'une page.
 *
 * `directImport` suit la règle de l'import : une recette JSON-LD complète
 * (titre, ingrédients, étapes) se projette sans modèle.
 */
export function extractPageCard(html: string): PageCardFields {
  const { recipes } = extractJsonLdRecipes(html);
  const recipe = recipes[0] ?? null;
  const title = clip(pageTitleOf(html) ?? recipe?.name, WEB_SEARCH_TITLE_MAX_CHARS);
  const description = clip(
    metaContent(html, "description") ??
      metaContent(html, "og:description") ??
      recipe?.description ??
      null,
    WEB_SEARCH_SNIPPET_MAX_CHARS,
  );
  return {
    title,
    description,
    directImport: recipes.some(isCompleteRecipe),
  };
}

// ── Résolution d'une source ──────────────────────────────────────────────────

/**
 * Issue de la résolution d'une source : une carte et la langue de sa page, ou
 * la raison de l'écarter.
 */
export type SourceOutcome =
  | { card: WebRecipeCard; language: PageLanguage; degraded: FetchFailure | null }
  | { card: null; dropped: string };

export type PageFetcher = (url: URL, opts: FetchOptions) => Promise<FetchedResource>;

/**
 * Suit le lien de Google jusqu'à la page, et en fait une carte.
 *
 * Une page qui refuse d'être lue (403, délai, type inattendu) garde sa carte,
 * sans extrait, `directImport` à faux, à condition que son adresse réelle soit connue et
 * sûre. Un refus de la garde SSRF (`refused`) ne rend jamais d'adresse.
 */
export async function resolveWebSource(
  source: GeminiGroundingSource,
  fetcher: PageFetcher = fetchPublicResource,
): Promise<SourceOutcome> {
  if (sourceTitleIsExcluded(source.title)) return { card: null, dropped: "excluded" };
  if (!URL.canParse(source.uri)) return { card: null, dropped: "bad_uri" };
  const start = new URL(source.uri);
  if (start.protocol !== "https:") return { card: null, dropped: "not_https" };

  try {
    const page = await fetcher(start, WEB_SEARCH_PAGE_FETCH_OPTIONS);
    const finalUrl = httpsUrlOrNull(page.finalUrl);
    if (!isDisplayableFinalUrl(finalUrl)) {
      return { card: null, dropped: finalUrl ? "excluded" : "not_https" };
    }
    const html = decodeHtml(page.body, page.charset);
    const fields = extractPageCard(html);
    const site = siteOf(finalUrl);
    return {
      card: {
        url: finalUrl,
        title: fields.title ?? site,
        site,
        snippet: fields.description,
        directImport: fields.directImport,
      },
      language: detectPageLanguage(html, finalUrl),
      degraded: null,
    };
  } catch (err) {
    if (!(err instanceof WebFetchError)) throw err;
    if (err.failure === "refused") return { card: null, dropped: "refused" };
    const finalUrl = httpsUrlOrNull(err.lastUrl);
    if (!isDisplayableFinalUrl(finalUrl)) {
      return { card: null, dropped: `unresolved_${err.failure}` };
    }
    const site = siteOf(finalUrl);
    const sourceTitle = clip(source.title, WEB_SEARCH_TITLE_MAX_CHARS);
    return {
      card: {
        url: finalUrl,
        // Le titre de Google est souvent le seul domaine : il ne vaut que s'il
        // dit autre chose que le site.
        title: sourceTitle && sourceTitle.toLowerCase() !== site ? sourceTitle : site,
        site,
        snippet: null,
        directImport: false,
      },
      // Page non lue : seule l'adresse peut donner un indice.
      language: detectPageLanguage(null, finalUrl),
      degraded: err.failure,
    };
  }
}

/** Adresse de dédoublonnage : sans fragment ni barre finale. */
export function dedupKey(url: string): string {
  const u = new URL(url);
  u.hash = "";
  const s = u.toString();
  return s.endsWith("/") ? s.slice(0, -1) : s;
}

/**
 * Garde les cartes dans l'ordre reçu — celui de Google, ou celui de
 * [orderByLanguage] —, dédoublonnées par adresse finale,
 * jusqu'à [WEB_SEARCH_MAX_RESULTS].
 */
export function pickCards(cards: Array<WebRecipeCard | null>): WebRecipeCard[] {
  const seen = new Set<string>();
  const out: WebRecipeCard[] = [];
  for (const card of cards) {
    if (!card) continue;
    const key = dedupKey(card.url);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(card);
    if (out.length >= WEB_SEARCH_MAX_RESULTS) break;
  }
  return out;
}

/**
 * Lit une carte du cache ; `null` si son adresse n'est plus affichable.
 *
 * Une entrée écrite avant le retrait des vignettes porte encore `imageUrl` :
 * le champ est ignoré.
 */
export function cardFromCache(raw: unknown): WebRecipeCard | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const url = httpsUrlOrNull(typeof o.url === "string" ? o.url : null);
  if (!isDisplayableFinalUrl(url)) return null;
  const str = (v: unknown) => (typeof v === "string" && v.trim() ? v : null);
  return {
    url,
    title: str(o.title) ?? siteOf(url),
    site: siteOf(url),
    snippet: str(o.snippet),
    directImport: o.directImport === true,
  };
}
