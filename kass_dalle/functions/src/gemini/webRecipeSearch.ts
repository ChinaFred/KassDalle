/**
 * « Chercher sur le web » : l'appel de modèle.
 *
 * Gemini cherche dans Google (outil `googleSearch`) des pages de recettes pour
 * le texte de l'Explorer. On ne lit pas sa réponse rédigée : seules comptent
 * les pages citées (`grounding.sources`), les requêtes lancées et le bloc
 * « Suggestions de recherche » que Google impose d'afficher.
 *
 * L'appel ne passe pas par `callModel`. Le routeur sait se replier sur Claude,
 * qui n'a ni l'outil de recherche Google ni ce bloc ; son résultat ne porte pas
 * non plus les pages citées. Ce qui reste commun avec `callModel`, et doit le
 * rester :
 *
 * - le plafond de dépense quotidien (`withDailyBudget`), réservé avant l'appel ;
 * - la comptabilité (`recordUsage`), appel échoué compris ;
 * - le plafond de raisonnement réglé dans Admin → Moteur d'IA pour ce poste.
 *
 * Coût : jetons d'entrée (prompt et résultat de la recherche relu par le
 * modèle), de sortie et de raisonnement, plus un appel ancré facturé à l'unité
 * (`groundedSearchCount`, prix `grounded_search_per_unit` de la grille).
 */

import { GEMINI_MODEL } from "../config";
import { logError, newCallId, type ModuleType } from "../logging";
import { withDailyBudget } from "../ai/budget";
import { getAiRoutingPolicy, resolveThinkingBudget } from "../ai/router";
import { recordUsage, type UsageEntry } from "../ai/usage";
import {
  callGemini,
  inputTokensOf,
  textPart,
  thinkingTokensOf,
  type GeminiGrounding,
  type GeminiResponse,
} from "./client";

/** Poste de coût, aux trois endroits (voir le skill `nouveau-poste-ia`). */
export const WEB_RECIPE_SEARCH_FEATURE = "web_recipe_search";

/**
 * Plafond de raisonnement par défaut : aucun.
 *
 * Lister des pages trouvées ne demande pas de délibération, et le
 * raisonnement se facture au tarif de sortie. Un plafond posé pour ce poste
 * dans Admin → Moteur d'IA l'emporte.
 */
export const WEB_RECIPE_SEARCH_DEFAULT_THINKING = 0;

/** Délai de l'appel de modèle, recherche comprise. */
export const WEB_RECIPE_SEARCH_TIMEOUT_MS = 40_000;

/**
 * Le prompt. La requête vient de l'utilisateur et ne sort pas de son propre
 * compte : guillemets retirés pour qu'elle reste une citation.
 */
export function buildWebRecipeSearchPrompt(query: string): string {
  const quoted = query.replace(/["«»“”]/g, " ").trim();
  return [
    "Cherche sur le web des pages de recettes de cuisine pour la demande suivante :",
    `« ${quoted} »`,
    "",
    "Règles :",
    "- Une page = une recette précise, avec ses ingrédients et ses étapes. Pas de page de liste, de catégorie ni d'accueil.",
    "- Pages en français de préférence ; à défaut, en anglais.",
    "- Sites de cuisine, blogs culinaires, magazines. Pas de vidéo ni de réseau social (YouTube, TikTok, Instagram, Facebook, Pinterest).",
    "- Jusqu'à huit pages, de sites différents si possible.",
    "",
    "Réponds en une ligne par page : le titre de la recette et le site.",
  ].join("\n");
}

/** Vrai si l'appel a interrogé Google : c'est ce que Google facture. */
export function isGroundedCall(grounding: GeminiGrounding | undefined): boolean {
  return (grounding?.webSearchQueries.length ?? 0) > 0 || (grounding?.sources.length ?? 0) > 0;
}

export interface WebSearchCallContext {
  correlationId: string;
  userId: string;
  moduleType?: ModuleType;
}

/** Écrit une ligne `ai_usage` — remplaçable dans les tests. */
export type UsageRecorder = (entry: UsageEntry) => Promise<unknown>;

/**
 * Note la consommation d'un appel **abouti**, sans jamais lever.
 *
 * L'appel est déjà facturé : lever ici rendrait la place de recherche au
 * compte, et le coût ne serait noté nulle part. Une écriture en échec est
 * journalisée (`logError`, avec les jetons et l'appel ancré, pour la
 * réconciliation) et la recherche rend quand même ses pages. Rend `false`
 * si la ligne n'a pas pu être écrite.
 */
export async function recordSearchUsage(
  entry: UsageEntry,
  record: UsageRecorder = recordUsage,
  report: (err: unknown) => Promise<void> = (err) =>
    logError({
      message: "Recherche web : consommation non enregistrée après un appel facturé",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: entry.correlationId ?? undefined,
      userId: entry.userId ?? undefined,
      feature: entry.feature,
      provider: entry.provider,
      model: entry.model,
      callId: entry.callId ?? undefined,
      moduleType: "SEARCH",
      extra: {
        inputTokens: entry.inputTokens ?? 0,
        outputTokens: entry.outputTokens ?? 0,
        thinkingTokens: entry.thinkingTokens ?? 0,
        groundedSearchCount: entry.groundedSearchCount ?? 0,
      },
    }),
): Promise<boolean> {
  try {
    await record(entry);
    return true;
  } catch (err) {
    await report(err);
    return false;
  }
}

/** Ce qu'il faut pour appeler Gemini — remplaçable dans les tests. */
export type GeminiCaller = typeof callGemini;

/**
 * Lance la recherche et rend ce que Google a apporté, ou `undefined` si la
 * réponse n'en porte rien.
 *
 * Lève les erreurs du fournisseur et `BudgetExceededError` ; l'appelant les
 * traduit.
 */
export async function searchRecipePagesWithGemini(
  apiKey: string,
  query: string,
  ctx: WebSearchCallContext,
  caller: GeminiCaller = callGemini,
): Promise<GeminiGrounding | undefined> {
  const policy = await getAiRoutingPolicy();
  const thinkingBudget =
    resolveThinkingBudget(policy, WEB_RECIPE_SEARCH_FEATURE) ?? WEB_RECIPE_SEARCH_DEFAULT_THINKING;

  return withDailyBudget(ctx.userId, WEB_RECIPE_SEARCH_FEATURE, async () => {
    const callId = newCallId();
    let result: GeminiResponse;
    try {
      result = await caller(apiKey, [textPart(buildWebRecipeSearchPrompt(query))], {
        correlationId: ctx.correlationId,
        callId,
        userId: ctx.userId,
        feature: WEB_RECIPE_SEARCH_FEATURE,
        moduleType: ctx.moduleType ?? "SEARCH",
        timeoutMs: WEB_RECIPE_SEARCH_TIMEOUT_MS,
        thinkingBudget,
        googleSearch: true,
      });
    } catch (err) {
      // Un appel échoué après avoir atteint le fournisseur reste visible dans
      // le suivi, comme dans `callModel` : sans jetons, mais compté.
      await recordUsage({
        feature: WEB_RECIPE_SEARCH_FEATURE,
        provider: "gemini",
        model: GEMINI_MODEL,
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        callId,
        status: "error",
      });
      throw err;
    }

    const usage = result.usageMetadata;
    await recordSearchUsage({
      feature: WEB_RECIPE_SEARCH_FEATURE,
      provider: "gemini",
      model: GEMINI_MODEL,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      callId,
      // Le résultat de la recherche relu par le modèle est facturé en entrée.
      inputTokens: inputTokensOf(usage),
      outputTokens: usage?.candidatesTokenCount ?? 0,
      thinkingTokens: thinkingTokensOf(usage),
      groundedSearchCount: isGroundedCall(result.grounding) ? 1 : 0,
    });
    return result.grounding;
  });
}
