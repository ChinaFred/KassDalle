/**
 * « Chercher sur le web » (Explorer) : l'entrée HTTPS.
 *
 * `searchWebRecipesFn` est ouverte à tous les rôles approuvés, lecteur
 * compris. Elle rend jusqu'à huit pages de recettes trouvées par la recherche
 * ancrée de Gemini, chacune résolue jusqu'à son adresse réelle, et le bloc de
 * suggestions de Google à afficher tel quel.
 *
 * L'enchaînement — cache partagé, réservation du plafond, recherche, place
 * rendue si l'appel de modèle échoue — vit dans `web/webSearchFlow.ts`. Ce fichier le branche
 * sur Firestore (`web_search_cache`, `web_search_daily`) et sur Gemini, et
 * traduit les erreurs pour le client.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_WEB_SEARCH_CACHE,
  COLL_WEB_SEARCH_DAILY,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { requireAuth, type AuthContext } from "./_auth";
import { BudgetExceededError, budgetMultiplierFor, spendDay } from "../ai/budget";
import { GeminiQuotaExceededError } from "../gemini/client";
import { WEB_RECIPE_SEARCH_FEATURE, searchRecipePagesWithGemini } from "../gemini/webRecipeSearch";
import { logError, logInfo, logWarn } from "../logging";
import {
  WEB_SEARCH_CACHE_TTL_MS,
  WEB_SEARCH_QUERY_MAX_CHARS,
  cardFromCache,
  cleanWebSearchQuery,
  isCacheFresh,
  resolveWebSource,
  webSearchCacheKey,
  type WebRecipeCard,
} from "../web/webSearchResults";
import {
  WebSearchQuotaError,
  WebSearchUnreadableError,
  runWebSearch,
  type WebSearchPayload,
  type WebSearchResponse,
} from "../web/webSearchFlow";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const opts = {
  region: REGION,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
  memory: "512MiB" as const,
  timeoutSeconds: 90,
  secrets: [GEMINI_API_KEY],
};

/** Recherches web autorisées par jour et par compte, avant multiplicateur. */
export const WEB_SEARCH_DAILY_LIMIT = 50;

/** Raison portée par le refus de plafond : le client affiche sa carte dédiée. */
export const WEB_SEARCH_QUOTA_REASON = "web_search_daily_quota";

/** Raison portée par le refus du plafond de dépense d'IA du jour. */
export const AI_DAILY_BUDGET_REASON = "ai_daily_budget";

/**
 * Raison portée par une panne du moteur : le client montre le message du
 * serveur, et distingue cette panne d'une coupure réseau, qui arrive aussi en
 * `unavailable`.
 */
export const WEB_SEARCH_ENGINE_REASON = "web_search_engine";

/** Raison portée par le refus d'une requête : le client montre le message. */
export const WEB_SEARCH_QUERY_REASON = "web_search_query";

/** Le plafond d'un compte : cinquante, multiplié pour le fondateur. */
export function webSearchLimit(multiplier: number): number {
  return WEB_SEARCH_DAILY_LIMIT * Math.max(1, Math.floor(multiplier));
}

/**
 * Lit la requête. Refuse un texte vide ou trop long, sans le couper : une
 * requête coupée chercherait autre chose que ce qui a été demandé.
 *
 * Un refus passe d'abord par [reportRefused], qui le journalise : seule la
 * longueur mesurée part, jamais le texte de l'utilisateur.
 */
export async function readWebSearchQuery(
  data: unknown,
  reportRefused: (length: number) => Promise<void>,
): Promise<string> {
  const raw = (data ?? {}) as Record<string, unknown>;
  const query = cleanWebSearchQuery(raw.query);
  if (!query) {
    await reportRefused(0);
    throw new HttpsError("invalid-argument", "Écrivez ce que vous cherchez sur le web.", {
      reason: WEB_SEARCH_QUERY_REASON,
    });
  }
  if (query.length > WEB_SEARCH_QUERY_MAX_CHARS) {
    await reportRefused(query.length);
    throw new HttpsError(
      "invalid-argument",
      `La recherche dépasse ${WEB_SEARCH_QUERY_MAX_CHARS} caractères.`,
      { reason: WEB_SEARCH_QUERY_REASON },
    );
  }
  return query;
}

/** Traduit une erreur de la recherche pour le client. */
export function webSearchHttpsError(err: unknown): HttpsError {
  if (err instanceof HttpsError) return err;
  if (err instanceof WebSearchQuotaError) {
    return new HttpsError("resource-exhausted", err.message, {
      reason: WEB_SEARCH_QUOTA_REASON,
      limit: err.limit,
      remaining: 0,
    });
  }
  // Plafond de dépense d'IA du jour : un autre plafond que celui des
  // recherches, avec son propre message.
  if (err instanceof BudgetExceededError) {
    return new HttpsError("resource-exhausted", err.message, {
      reason: AI_DAILY_BUDGET_REASON,
      budget: err.reason,
    });
  }
  const engine = { reason: WEB_SEARCH_ENGINE_REASON };
  if (err instanceof GeminiQuotaExceededError) {
    return new HttpsError(
      "unavailable",
      "Le moteur de recherche est saturé. Réessayez plus tard.",
      engine,
    );
  }
  if (err instanceof WebSearchUnreadableError) {
    return new HttpsError("unavailable", "La recherche n'a pas abouti. Réessayez.", engine);
  }
  return new HttpsError(
    "unavailable",
    "Le moteur de recherche est indisponible. Réessayez.",
    engine,
  );
}

function readCount(data: FirebaseFirestore.DocumentData | undefined): number {
  const n = data?.count;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
}

/** Une entrée du cache, relue ; `null` si périmée, vide ou mal formée. */
function payloadFromCache(data: FirebaseFirestore.DocumentData): WebSearchPayload | null {
  const cachedAt = data.cached_at instanceof Timestamp ? data.cached_at.toMillis() : NaN;
  if (!isCacheFresh(cachedAt, Date.now())) return null;
  const results = (Array.isArray(data.results) ? data.results : [])
    .map(cardFromCache)
    .filter((c): c is WebRecipeCard => c != null);
  if (results.length === 0) return null;
  return {
    results,
    searchEntryPointHtml:
      typeof data.search_entry_point_html === "string" ? data.search_entry_point_html : null,
    webSearchQueries: Array.isArray(data.web_search_queries)
      ? data.web_search_queries.filter((q: unknown): q is string => typeof q === "string")
      : [],
  };
}

function logContext(ctx: AuthContext) {
  return {
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    feature: WEB_RECIPE_SEARCH_FEATURE,
    moduleType: "SEARCH" as const,
  };
}

export const searchWebRecipesFn = onCall(opts, async (req): Promise<WebSearchResponse> => {
  const ctx = await requireAuth(req, WEB_RECIPE_SEARCH_FEATURE);
  const query = await readWebSearchQuery(req.data, (length) =>
    logWarn({
      ...logContext(ctx),
      message: "Recherche web refusée : requête vide ou trop longue",
      extra: { queryLength: length, maxChars: WEB_SEARCH_QUERY_MAX_CHARS },
    }),
  );
  const limit = webSearchLimit(await budgetMultiplierFor(ctx.userId));
  const db = getFirestore();
  const cacheRef = db.collection(COLL_WEB_SEARCH_CACHE).doc(webSearchCacheKey(query));
  const day = spendDay(new Date());
  const counter = db.collection(COLL_WEB_SEARCH_DAILY).doc(`${ctx.userId}_${day}`);

  let failureReported = false;
  let response: WebSearchResponse;
  try {
    response = await runWebSearch(query, limit, {
      async readCache() {
        try {
          const snap = await cacheRef.get();
          return snap.exists ? payloadFromCache(snap.data() ?? {}) : null;
        } catch (err) {
          // Best-effort : sans cache, la recherche part, et elle est décomptée.
          await logError({
            ...logContext(ctx),
            message: "Recherche web : lecture du cache impossible, recherche lancée",
            errorDescription: err instanceof Error ? err.message : String(err),
          });
          return null;
        }
      },
      async writeCache(payload) {
        try {
          // Rien de propre à un compte : la requête normalisée, les pages, le
          // bloc de Google. Ni uid, ni compteur.
          await cacheRef.set({
            query: query.toLocaleLowerCase("fr"),
            results: payload.results,
            search_entry_point_html: payload.searchEntryPointHtml,
            web_search_queries: payload.webSearchQueries,
            cached_at: Timestamp.now(),
            expires_at: Timestamp.fromMillis(Date.now() + WEB_SEARCH_CACHE_TTL_MS),
          });
        } catch (err) {
          await logError({
            ...logContext(ctx),
            message: "Recherche web : écriture du cache impossible",
            errorDescription: err instanceof Error ? err.message : String(err),
          });
        }
      },
      async readUsed() {
        return readCount((await counter.get()).data());
      },
      reserve(max) {
        return db.runTransaction(async (tx) => {
          const used = readCount((await tx.get(counter)).data());
          if (used >= max) return null;
          tx.set(
            counter,
            { uid: ctx.userId, day, count: FieldValue.increment(1), updated_at: Timestamp.now() },
            { merge: true },
          );
          return used + 1;
        });
      },
      async refund() {
        // Un remboursement raté laisse le compteur plus haut d'une unité : le
        // plafond devient plus strict, jamais plus large.
        try {
          await db.runTransaction(async (tx) => {
            const used = readCount((await tx.get(counter)).data());
            if (used <= 0) return;
            tx.set(counter, { count: used - 1, updated_at: Timestamp.now() }, { merge: true });
          });
        } catch (err) {
          await logError({
            ...logContext(ctx),
            message: "Recherche web : place non rendue après une erreur",
            errorDescription: err instanceof Error ? err.message : String(err),
          });
        }
      },
      search() {
        return searchRecipePagesWithGemini(GEMINI_API_KEY.value(), query, {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
        });
      },
      resolve(source) {
        return resolveWebSource(source);
      },
      async reportPartial(details) {
        // Attendu : une page qui refuse d'être lue garde sa carte, sans
        // vignette ; une vidéo ou un réseau social est écarté.
        await logWarn({
          ...logContext(ctx),
          message: "Recherche web : pages écartées ou lues en partie",
          extra: details,
        });
      },
      async reportFailure(err, refunded) {
        failureReported = true;
        await logError({
          ...logContext(ctx),
          message: refunded
            ? "Recherche web échouée : place rendue"
            : "Recherche web inexploitable : appel facturé, place gardée",
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { queryLength: query.length, refunded },
        });
      },
    });
  } catch (err) {
    if (err instanceof WebSearchQuotaError) {
      await logWarn({
        ...logContext(ctx),
        message: "Recherche web refusée : plafond du jour atteint",
        extra: { limit },
      });
    } else if (!failureReported) {
      // Compteur ou réservation en panne : rien ne l'a encore journalisé.
      await logError({
        ...logContext(ctx),
        message: "Recherche web échouée avant l'appel du modèle",
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { queryLength: query.length },
      });
    }
    throw webSearchHttpsError(err);
  }

  await logInfo({
    ...logContext(ctx),
    message: response.fromCache
      ? `Recherche web servie par le cache : ${response.results.length} page(s)`
      : `Recherche web : ${response.results.length} page(s)`,
    extra: {
      fromCache: response.fromCache,
      results: response.results.length,
      directImport: response.results.filter((r) => r.directImport).length,
      remaining: response.remaining,
    },
  });
  return response;
});
