/**
 * Extraction de recettes depuis un document (image, PDF, DOCX) ou un texte.
 *
 * Porté depuis GeminiService.extractRecipes() et extractRecipeFromText().
 */

import { callGemini, dataPart, textPart, GeminiCallContext } from "./client";
import { recordTokenUsage } from "./tokenUsage";
import { GEMINI_SCAN_PROMPT, GEMINI_FREE_TEXT_PROMPT, GEMINI_MULTI_PAGE_PREFIX } from "./prompts";

export interface ExtraPage {
  bytes: Buffer;
  mimeType: string;
}

/**
 * Envoie un fichier (PDF, DOCX, image) à Gemini et retourne le CookLang extrait.
 * Retourne une liste de strings CookLang (une par recette détectée), vide si aucune.
 *
 * @param additionalPages pages supplémentaires (multi-page scan)
 */
export async function extractRecipes(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: GeminiCallContext,
  additionalPages: ExtraPage[] = [],
): Promise<string[]> {
  const prompt = additionalPages.length > 0
    ? GEMINI_MULTI_PAGE_PREFIX + GEMINI_SCAN_PROMPT
    : GEMINI_SCAN_PROMPT;

  const parts = [
    dataPart(mimeType, bytes),
    ...additionalPages.map((p) => dataPart(p.mimeType, p.bytes)),
    textPart(prompt),
  ];

  const result = await callGemini(apiKey, parts, {
    ...ctx,
    feature: ctx.feature || "scan_extraction",
    timeoutMs: 5 * 60 * 1000,
  });

  await recordTokenUsage(result, "scan_extraction", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  if (!text || text === "NO_RECIPE") return [];

  return text
    .split(/\n-{3,}\n/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/**
 * Convertit un texte libre en CookLang.
 * Retourne null si Gemini répond NO_RECIPE.
 */
export async function extractRecipeFromText(
  apiKey: string,
  freeText: string,
  ctx: GeminiCallContext,
): Promise<string | null> {
  const result = await callGemini(
    apiKey,
    [textPart(`${GEMINI_FREE_TEXT_PROMPT}\n\n---\n${freeText}`)],
    { ...ctx, feature: ctx.feature || "text_extraction", timeoutMs: 2 * 60 * 1000 },
  );

  await recordTokenUsage(result, "text_extraction", ctx.userId);

  const out = (result.response.text() ?? "").trim();
  if (!out || out === "NO_RECIPE") return null;
  return out;
}
