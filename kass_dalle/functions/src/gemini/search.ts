/**
 * Recherche IA dans les recettes + extraction couverture de livre.
 * Porté depuis GeminiService.searchRecipes() et extractBookCover().
 */

import { extractJsonObject } from "./client";
import { callModel } from "../ai/router";
import { attachmentPart } from "../ai/attachment";
import { textPart, type ModelCallContext } from "../ai/types";
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
  ctx: ModelCallContext,
): Promise<SearchRecipesResult> {
  if (input.recipes.length === 0) {
    return { results: [], suggestion: null, preference_insight: null };
  }

  const recipesJson = JSON.stringify(input.recipes);
  const rated = input.ratedRecipes ?? [];
  // Les notes départagent, elles ne sélectionnent pas : une recette bien notée
  // qui ne répond pas à la demande remontait devant celle qui y répond.
  const preferencesSection =
    rated.length === 0
      ? ""
      : `
Recettes notées par l'utilisateur (note sur 10) :
${JSON.stringify(rated)}
`;

  const prompt = `Tu es un assistant culinaire qui cherche dans la collection de l'utilisateur.

Requête de l'utilisateur : "${input.query}"
${preferencesSection}
Collection de recettes disponibles (JSON) :
${recipesJson}

Champs d'une recette :
- "role" : place dans un repas (plat, accompagnement, entree, dessert, snack) ; vide si inconnue.
- "proteine" : protéine principale (boeuf, porc, volaille, agneau, poisson, fruits_de_mer, oeuf, vegetarien, legumineuses) ; vide si inconnue.
- "feculent" : féculent principal déjà intégré à la recette (pates, riz, pommes_de_terre, semoule, pain, aucun) ; vide si inconnu.
- "note" : note de l'utilisateur sur 10, ou "non notee".

Règles de sélection :
1. Repère les éléments explicites de la requête : ingrédient, protéine, féculent, type de plat, cuisine.
2. Exclus une recette qui contredit un élément explicite : une autre protéine principale que celle demandée, ou un autre féculent déjà intégré que celui demandé (une requête « avec des frites » exclut un plat servi sur du riz ou des pâtes).
3. Une recette sans féculent ("aucun") qui a la bonne protéine reste pertinente : le féculent demandé peut l'accompagner.
4. Un champ vide ne permet pas d'exclure : juge alors sur le titre et les ingrédients.
5. N'inclus pas une recette sur un simple rapprochement de thème ou de cuisine si elle ne partage aucun élément explicite de la requête.

Classement :
- D'abord la pertinence : une recette qui réunit tous les éléments de la requête passe devant une recette qui n'en réunit qu'une partie.
- La note ne sert qu'à départager deux recettes de même pertinence, jamais à en inclure une. Une recette "non notee" compte comme 7/10 : note ≥ 8 devant, note ≤ 6 derrière.

Retourne UNIQUEMENT un JSON valide, sans markdown :
{
  "results": [{"id": "id_recette", "raison": "Explication courte"}],
  "suggestion": null,
  "preference_insight": null
}

"raison" dit quels éléments de la requête la recette réunit, et ce qui manque (par exemple : le féculent à servir à côté).
Si AUCUNE recette ne correspond, "results" = [] et "suggestion" = "reformulation".
"preference_insight" : une phrase sur les goûts tirée des notes, seulement si elle aide à choisir parmi les résultats. Sinon null.
`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, feature: "search", timeoutMs: 60_000 },
  });

  const text = result.text.trim();
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
  ctx: ModelCallContext,
): Promise<BookCoverExtraction> {
  const result = await callModel({
    parts: [await attachmentPart(mimeType, bytes, ctx), textPart(GEMINI_BOOK_COVER_PROMPT)],
    ctx: { ...ctx, feature: "book_cover", timeoutMs: 2 * 60 * 1000 },
  });

  const text = result.text.trim();
  if (!text) throw new Error("Réponse vide pour la couverture du livre");

  return JSON.parse(extractJsonObject(text)) as BookCoverExtraction;
}
