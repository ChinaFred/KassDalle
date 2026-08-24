/**
 * Conversion d'un texte libre en CookLang.
 *
 * Ce fichier portait aussi trois étapes de l'ancien import : l'extraction
 * depuis une image ou un PDF (`extractRecipes`), la classification de la page
 * (`classifyPage`) et l'extraction verbatim d'un document non-recette
 * (`extractDocument`). La transcription en deux passes les a remplacées —
 * `transcription_page` rend le type de page ET le texte, `recipe_tagging`
 * normalise — et plus rien ne les appelait depuis.
 *
 * Leurs trois postes de coût restent au catalogue comptable : les mois déjà
 * comptabilisés doivent continuer de les nommer. Ils ont en revanche quitté
 * `ROUTABLE_FEATURES` : un sélecteur de moteur qui ne commande aucun appel est
 * pire qu'une absence, il fait croire à un réglage.
 */

import { callModel } from "../ai/router";
import { textPart, type ModelCallContext } from "../ai/types";
import { GEMINI_FREE_TEXT_PROMPT } from "./prompts";

/** Plafond de sortie d'une extraction : une recette collée peut être longue. */
const EXTRACTION_MAX_TOKENS = 16_000;

/**
 * Convertit un texte libre en CookLang.
 * Retourne null si le modèle répond NO_RECIPE.
 */
export async function extractRecipeFromText(
  apiKey: string,
  freeText: string,
  ctx: ModelCallContext,
): Promise<string | null> {
  const result = await callModel({
    parts: [textPart(`${GEMINI_FREE_TEXT_PROMPT}\n\n---\n${freeText}`)],
    ctx: { ...ctx, feature: "text_extraction", timeoutMs: 2 * 60 * 1000 },
    maxTokens: EXTRACTION_MAX_TOKENS,
  });

  const out = result.text.trim();
  if (!out || out === "NO_RECIPE") return null;
  return out;
}
