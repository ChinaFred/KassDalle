/**
 * Extraction de recettes depuis un document (image, PDF, DOCX) ou un texte.
 *
 * Porté depuis GeminiService.extractRecipes() et extractRecipeFromText().
 */

import { callGemini, dataPart, textPart, extractJsonObject, GeminiCallContext } from "./client";
import { recordTokenUsage } from "./tokenUsage";
import { GEMINI_CLASSIFY_PROMPT, GEMINI_DOCUMENT_EXTRACT_PROMPT, GEMINI_SCAN_PROMPT, GEMINI_FREE_TEXT_PROMPT, GEMINI_MULTI_PAGE_PREFIX } from "./prompts";

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

// ── Appel 1 : classification de la page ──────────────────────────────────────

export type PageType = "recipe" | "ingredient_note" | "technique" | "equipment" | "other" | "no_recipe";

export interface PageClassification {
  pageType: PageType;
  titre: string;
  page: number | null;
}

/**
 * Classifie une page : recipe ou non-recipe (ingredient_note, technique, etc.).
 * Appel court (60 s max) qui retourne uniquement un JSON.
 */
export async function classifyPage(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: GeminiCallContext,
  additionalPages: ExtraPage[] = [],
): Promise<PageClassification> {
  const parts = [
    dataPart(mimeType, bytes),
    ...additionalPages.map((p) => dataPart(p.mimeType, p.bytes)),
    textPart(GEMINI_CLASSIFY_PROMPT),
  ];

  const result = await callGemini(apiKey, parts, {
    ...ctx,
    feature: "classify_page",
    timeoutMs: 60_000,
  });

  await recordTokenUsage(result, "classify_page", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  try {
    const json = JSON.parse(extractJsonObject(text)) as Record<string, unknown>;
    let pageType: PageType = (json.page_type as PageType) ?? "other";

    // Sanity check : si le reasoning dit EXPLICITEMENT "pas une recette" mais page_type = "recipe", c'est incohérent.
    // On corrige côté serveur uniquement pour les cas non ambigus — on ne surcharge pas le modèle
    // sur des mentions normales ("liste d'ingrédients", "séquence") qui apparaissent aussi dans
    // le reasoning d'une vraie recette.
    if (pageType === "recipe" && json.reasoning) {
      const r = (json.reasoning as string).toLowerCase();
      const reasoningSaysNotRecipe =
        r.includes("n'est pas une recette") ||
        r.includes("pas une recette") ||
        r.includes("ne contient pas de recette") ||
        r.includes("ne présente pas de recette") ||
        r.includes("ce n'est pas") ||
        (r.includes("aucune étape") && r.includes("aucun ingrédient"));
      if (reasoningSaysNotRecipe) {
        pageType = "ingredient_note";
      }
    }

    const classification: PageClassification = {
      pageType,
      titre: (json.titre as string | undefined) ?? "Page sans titre",
      page: json.page != null ? Number(json.page) : null,
    };
    if (json.reasoning) {
      const { logInfo: li } = await import("../logging");
      li({
        message: `Classification reasoning: ${json.reasoning} → page_type corrigé: ${pageType}`,
        moduleType: "IMPORT", ...ctx,
      });
    }
    return classification;
  } catch {
    // En cas d'erreur JSON, on suppose que c'est une recette pour ne pas perdre de contenu.
    return { pageType: "recipe", titre: "Recette", page: null };
  }
}

// ── Appel 2b : extraction verbatim d'un document non-recette ─────────────────

/**
 * Extrait le contenu d'une page non-recette mot pour mot.
 * Retourne une chaîne au format CookLang compatible (métadonnées >> + corps texte)
 * pour être traitée directement par saveRecipeDraft.
 */
export async function extractDocument(
  apiKey: string,
  bytes: Buffer,
  mimeType: string,
  ctx: GeminiCallContext,
  classification: PageClassification,
  additionalPages: ExtraPage[] = [],
): Promise<string> {
  const parts = [
    dataPart(mimeType, bytes),
    ...additionalPages.map((p) => dataPart(p.mimeType, p.bytes)),
    textPart(GEMINI_DOCUMENT_EXTRACT_PROMPT),
  ];

  const result = await callGemini(apiKey, parts, {
    ...ctx,
    feature: "document_extraction",
    timeoutMs: 2 * 60_000,
  });

  await recordTokenUsage(result, "document_extraction", ctx.userId);

  const content = (result.response.text() ?? "").trim();

  // Construit le format attendu par parseCooklangBlocks / saveRecipeDraft
  const lines: string[] = [
    `>> page_type: ${classification.pageType}`,
    `>> titre: ${classification.titre}`,
  ];
  if (classification.page != null) lines.push(`>> page: ${classification.page}`);
  lines.push("");
  lines.push(content);
  return lines.join("\n");
}
