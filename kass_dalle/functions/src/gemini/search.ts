/**
 * Recherche IA dans les recettes + extraction couverture de livre.
 * Porté depuis GeminiService.searchRecipes() et extractBookCover().
 */

import { callGemini, dataPart, textPart, extractJsonObject, GeminiCallContext } from "./client";
import { recordTokenUsage } from "./tokenUsage";
import { GEMINI_BOOK_COVER_PROMPT } from "./prompts";

export interface SearchRecipesInput {
  query: string;
  recipes: Array<Record<string, string>>;
  ratedRecipes?: Array<Record<string, string>>;
}

export interface SearchRecipesResult {
  results: Array<{ id: string; raison: string }>;
  suggestion: string | null;
  preference_insight: string | null;
}

export async function searchRecipes(
  apiKey: string,
  input: SearchRecipesInput,
  ctx: GeminiCallContext,
): Promise<SearchRecipesResult> {
  if (input.recipes.length === 0) {
    return { results: [], suggestion: null, preference_insight: null };
  }

  const recipesJson = JSON.stringify(input.recipes);
  const rated = input.ratedRecipes ?? [];
  const preferencesSection = rated.length === 0
    ? ""
    : `
Préférences connues de l'utilisateur — recettes notées (note sur 10) :
${JSON.stringify(rated)}
(Interprétation : ≥8 = aime beaucoup, 5–7 = apprécie, ≤4 = n'aime pas)

Déduis ses goûts depuis ces notes et tiens-en compte dans la sélection.
`;

  const prompt = `Tu es un assistant culinaire expert qui connaît les goûts de l'utilisateur.

Requête de l'utilisateur : "${input.query}"
${preferencesSection}
Collection de recettes disponibles (JSON, "note" = note /10 ou "non notée") :
${recipesJson}

Analyse chaque recette et détermine si elle correspond à la requête.
Sois généreux : si une recette contient les ingrédients ou correspond au thème, inclus-la.
Classe les résultats par pertinence décroissante : la recette dont le titre ou les ingrédients correspondent le mieux à la requête doit apparaître en premier.

Retourne UNIQUEMENT un JSON valide, sans markdown :
{
  "results": [{"id": "id_recette", "raison": "Explication courte"}],
  "suggestion": null,
  "preference_insight": null
}

Si AUCUNE recette ne correspond, "results" = [] et "suggestion" = "reformulation".
Si pattern de goût clair, remplis "preference_insight". Sinon null.
`;

  const result = await callGemini(apiKey, [textPart(prompt)], {
    ...ctx,
    feature: "search",
    timeoutMs: 60_000,
  });
  await recordTokenUsage(result, "search", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  if (!text) return { results: [], suggestion: null, preference_insight: null };

  return JSON.parse(extractJsonObject(text)) as SearchRecipesResult;
}

export interface BookCoverExtraction {
  titre: string;
  sous_titre: string | null;
  auteur: string;
  editeur: string | null;
  serie: string | null;
  annee: number | null;
  langue: "fr" | "en" | "nl";
  isbn: string | null;
  description: string | null;
  tags: string[];
}

export async function extractBookCover(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: GeminiCallContext,
): Promise<BookCoverExtraction> {
  const result = await callGemini(
    apiKey,
    [dataPart(mimeType, bytes), textPart(GEMINI_BOOK_COVER_PROMPT)],
    { ...ctx, feature: "book_cover", timeoutMs: 2 * 60 * 1000 },
  );
  await recordTokenUsage(result, "book_cover", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  if (!text) throw new Error("Réponse vide pour la couverture du livre");

  return JSON.parse(extractJsonObject(text)) as BookCoverExtraction;
}

/**
 * Génère une requête Google optimisée à partir d'une demande libre.
 * Porté depuis GeminiService.generateWebSearchQuery().
 */
export async function generateWebSearchQuery(
  apiKey: string,
  userQuery: string,
  ctx: GeminiCallContext,
): Promise<string> {
  const prompt = `Tu es un expert SEO spécialisé en cuisine.
L'utilisateur veut chercher une recette sur Google avec la demande suivante : "${userQuery}"

Génère UNE SEULE requête Google optimisée pour trouver cette recette.
Règles strictes :
- Corrige les fautes d'orthographe
- Garde uniquement les mots-clés culinaires essentiels (nom du plat, type de cuisine, contraintes clés)
- N'ajoute PAS le mot "recette" (il sera ajouté automatiquement)
- Ne dépasse pas 6 mots
- Réponds UNIQUEMENT avec la requête, sans guillemets, sans explication
`;
  const result = await callGemini(apiKey, [textPart(prompt)], {
    ...ctx, feature: "web_search_query", timeoutMs: 15_000,
  });
  await recordTokenUsage(result, "web_search_query", ctx.userId);
  const query = (result.response.text() ?? "").trim();
  if (!query) throw new Error("Réponse Gemini vide");
  return query;
}
