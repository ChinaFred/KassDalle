/**
 * « Chercher sur le web » : l'enchaînement cache, plafond, recherche.
 *
 * Séparé de la callable pour être testé sans Firestore ni réseau : chaque
 * accès passe par [WebSearchDeps], que la callable branche sur Firestore et
 * Gemini, et que `tests/webSearchFlow.test.ts` remplace.
 *
 * Les règles qui comptent pour la facture :
 *
 *  - une recherche servie par le cache n'appelle pas le modèle et ne décompte
 *    rien ;
 *  - la place du jour est **réservée** avant l'appel, atomiquement : deux
 *    appels simultanés ne passent pas tous les deux sur la dernière place ;
 *  - la place n'est **rendue** que si l'appel de modèle lève une erreur
 *    (moteur, quota du fournisseur, plafond de dépense) : rien n'a été
 *    facturé. Dès que le modèle a répondu, la place est gardée — réponse sans
 *    recherche ancrée, page illisible ou aucune page retenue compris : l'appel
 *    a été facturé.
 */

import type { GeminiGrounding, GeminiGroundingSource } from "../gemini/client";
import {
  WEB_SEARCH_MAX_SOURCES,
  pickCards,
  type SourceOutcome,
  type WebRecipeCard,
} from "./webSearchResults";

/** Ce que le cache garde, et ce que la recherche rend. */
export interface WebSearchPayload {
  results: WebRecipeCard[];
  searchEntryPointHtml: string | null;
  webSearchQueries: string[];
}

/** Ce que rend la callable. */
export interface WebSearchResponse extends WebSearchPayload {
  query: string;
  fromCache: boolean;
  limit: number;
  remaining: number;
}

/** Le plafond du jour est atteint. */
export class WebSearchQuotaError extends Error {
  constructor(readonly limit: number) {
    super(`Vous avez fait vos ${limit} recherches web d'aujourd'hui.`);
    this.name = "WebSearchQuotaError";
  }
}

/**
 * La réponse ne porte aucune recherche ancrée : rien à montrer. L'appel a été
 * facturé, la place est gardée.
 */
export class WebSearchUnreadableError extends Error {
  constructor() {
    super("La recherche n'a rendu aucune page : réponse sans recherche Google.");
    this.name = "WebSearchUnreadableError";
  }
}

export interface WebSearchDeps {
  /** Entrée du cache encore valable, `null` sinon (lecture ratée comprise). */
  readCache(): Promise<WebSearchPayload | null>;
  writeCache(payload: WebSearchPayload): Promise<void>;
  /** Recherches déjà faites aujourd'hui, sans rien réserver. */
  readUsed(): Promise<number>;
  /**
   * Réserve une place si `used < limit`, dans une transaction. Rend le
   * nombre de recherches du jour après réservation, ou `null` si le plafond
   * est atteint.
   */
  reserve(limit: number): Promise<number | null>;
  /** Rend une place réservée. */
  refund(): Promise<void>;
  /** Appel de modèle avec l'outil de recherche Google. */
  search(): Promise<GeminiGrounding | undefined>;
  /** Suit un lien de Google jusqu'à sa page. */
  resolve(source: GeminiGroundingSource): Promise<SourceOutcome>;
  /** Pages écartées ou lues en partie — attendu, journalisé en avertissement. */
  reportPartial(details: { degraded: string[]; dropped: string[] }): Promise<void>;
  /**
   * Recherche en erreur. `refunded` dit si la place a été rendue (le modèle
   * a levé une erreur) ou gardée (le modèle a répondu, l'appel est facturé).
   */
  reportFailure(err: unknown, refunded: boolean): Promise<void>;
}

/** Recherches restantes. */
export function remainingSearches(used: number, limit: number): number {
  return Math.max(0, limit - Math.max(0, used));
}

/** Lecture des pages citées par la réponse, et sélection des cartes. */
async function resolveGrounding(
  grounding: GeminiGrounding | undefined,
  deps: WebSearchDeps,
): Promise<WebSearchPayload> {
  if (!grounding || (grounding.sources.length === 0 && grounding.webSearchQueries.length === 0)) {
    throw new WebSearchUnreadableError();
  }
  const outcomes = await Promise.all(
    grounding.sources.slice(0, WEB_SEARCH_MAX_SOURCES).map((s) => deps.resolve(s)),
  );
  const degraded = outcomes.flatMap((o) =>
    o.card && o.degraded ? [`${o.card.site}: ${o.degraded}`] : [],
  );
  const dropped = outcomes.flatMap((o) => (o.card ? [] : [o.dropped]));
  if (degraded.length > 0 || dropped.length > 0) {
    await deps.reportPartial({ degraded, dropped });
  }
  return {
    results: pickCards(outcomes.map((o) => o.card)),
    searchEntryPointHtml: grounding.searchEntryPointHtml ?? null,
    webSearchQueries: grounding.webSearchQueries,
  };
}

/**
 * Cache, réservation, recherche ; place rendue si l'appel de modèle échoue.
 *
 * Lève [WebSearchQuotaError] quand le plafond est atteint. Relance l'erreur
 * de l'appel de modèle après avoir rendu la place, et celle de la lecture de
 * la réponse ([WebSearchUnreadableError] compris) en gardant la place.
 */
export async function runWebSearch(
  query: string,
  limit: number,
  deps: WebSearchDeps,
): Promise<WebSearchResponse> {
  const cached = await deps.readCache();
  if (cached) {
    const used = await deps.readUsed();
    return { query, ...cached, fromCache: true, limit, remaining: remainingSearches(used, limit) };
  }

  const used = await deps.reserve(limit);
  if (used == null) throw new WebSearchQuotaError(limit);

  let grounding: GeminiGrounding | undefined;
  try {
    grounding = await deps.search();
  } catch (err) {
    // Le modèle n'a rien rendu : rien n'est facturé, la place revient.
    await deps.refund();
    await deps.reportFailure(err, true);
    throw err;
  }

  let payload: WebSearchPayload;
  try {
    payload = await resolveGrounding(grounding, deps);
  } catch (err) {
    // Le modèle a répondu : l'appel est facturé, la place reste prise.
    await deps.reportFailure(err, false);
    throw err;
  }

  // Un résultat vide n'est pas mis en cache : il peut venir d'un incident
  // passager, et serait resservi sept jours.
  if (payload.results.length > 0) await deps.writeCache(payload);

  return { query, ...payload, fromCache: false, limit, remaining: remainingSearches(used, limit) };
}
