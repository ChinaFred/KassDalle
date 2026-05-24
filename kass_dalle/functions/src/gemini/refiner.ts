/**
 * Polish CookLang, refine recipe, generate recipe.
 * Porté depuis GeminiService.polishCooklang() / refineRecipe() / generateRecipe().
 */

import { callGemini, textPart, extractJsonObject, GeminiCallContext } from "./client";
import { recordTokenUsage } from "./tokenUsage";
import { GEMINI_POLISH_PROMPT, COOKLANG_RULES } from "./prompts";

/** Correction orthographique/sémantique d'un CookLang existant. */
export async function polishCooklang(
  apiKey: string,
  cooklang: string,
  ctx: GeminiCallContext,
): Promise<string | null> {
  const result = await callGemini(
    apiKey,
    [textPart(`${GEMINI_POLISH_PROMPT}\n\n---\n${cooklang}`)],
    { ...ctx, feature: "polish_cooklang", timeoutMs: 2 * 60 * 1000 },
  );
  await recordTokenUsage(result, "polish_cooklang", ctx.userId);
  const out = (result.response.text() ?? "").trim();
  return out || null;
}

export interface RefineInput {
  currentTitre: string;
  currentCooklang: string;
  currentIngredients: Array<{ name?: string; qty?: string; unit?: string }>;
  currentTags: Record<string, unknown>;
  currentPortions: number | null;
  instruction: string;
}

/** Modifie une recette existante d'après l'instruction utilisateur. */
export async function refineRecipe(
  apiKey: string,
  input: RefineInput,
  ctx: GeminiCallContext,
): Promise<Record<string, unknown>> {
  const ingredientsList = input.currentIngredients
    .map((i) => {
      const parts = [i.qty, i.unit, i.name].filter((s) => s && String(s).length > 0);
      return `- ${parts.join(" ").trim()}`;
    })
    .join("\n");

  const portions = input.currentPortions != null ? `\nPortions : ${input.currentPortions}` : "";

  const prompt = `Tu es un chef cuisinier expert francophone. Voici une recette existante :

TITRE: ${input.currentTitre}${portions}
INGRÉDIENTS:
${ingredientsList}

RECETTE AU FORMAT COOKLANG:
${input.currentCooklang}

L'utilisateur souhaite modifier cette recette avec la consigne suivante :
"${input.instruction}"

Applique EXACTEMENT cette consigne en modifiant la recette. Conserve tout ce qui n'est pas concerné par la consigne.

RÈGLE ABSOLUE SUR LES TEMPS :
- "prep_time" = durée totale de préparation AVANT cuisson (épluchage, découpe, marinade, etc.) en minutes.
- "cook_time" = somme EXACTE de TOUS les timers ~{...} de cuisson présents dans le CookLang, en minutes.
- Ces deux valeurs DOIVENT être cohérentes avec les timers ~{} réels de la recette CookLang générée.
- Si tu modifies des étapes, recalcule prep_time et cook_time en conséquence.
- N'invente JAMAIS un cook_time différent de la somme des timers ~{} de cuisson.

Retourne la recette MODIFIÉE en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [{"name": "ingredient", "qty": "200", "unit": "g"}],
  "tags": {"themes": [], "cuisines": [], "occasions": [], "dish_types": [], "difficulty": "facile", "prep_time": 20, "cook_time": 40},
  "portions": 4
}
===COOKLANG===
Contenu CookLang modifié
===END===

${COOKLANG_RULES}`;

  const result = await callGemini(apiKey, [textPart(prompt)], {
    ...ctx,
    feature: "refine",
    timeoutMs: 2 * 60 * 1000,
  });
  await recordTokenUsage(result, "refine", ctx.userId);

  return parseMetadataCooklang(result.response.text() ?? "");
}

/** Génère une nouvelle recette originale à partir d'une requête utilisateur. */
export async function generateRecipe(
  apiKey: string,
  query: string,
  preferenceInsight: string | null,
  ctx: GeminiCallContext,
): Promise<Record<string, unknown>> {
  const prefSection = preferenceInsight
    ? `\nTiens compte des préférences connues de l'utilisateur : ${preferenceInsight}\n`
    : "";

  const prompt = `Tu es un chef cuisinier expert francophone. L'utilisateur cherche une recette : "${query}"${prefSection}
Génère une recette originale complète qui répond exactement à cette demande.

RÈGLE ABSOLUE SUR LES TEMPS :
- "prep_time" = durée totale de préparation AVANT cuisson (épluchage, découpe, marinade, etc.) en minutes.
- "cook_time" = somme EXACTE de TOUS les timers ~{...} de cuisson présents dans le CookLang, en minutes.
- Ces deux valeurs DOIVENT être cohérentes avec les timers ~{} réels de la recette CookLang générée.
- N'invente JAMAIS un cook_time différent de la somme des timers ~{} de cuisson.

Retourne la réponse en DEUX sections exactement dans ce format (rien d'autre) :

===METADATA===
{
  "titre": "Nom de la recette",
  "langue": "fr",
  "ingredients_index": ["ingredient1", "ingredient2"],
  "ingredients": [{"name": "ingredient", "qty": "200", "unit": "g"}],
  "tags": {"themes": [], "cuisines": [], "occasions": [], "dish_types": [], "difficulty": "facile", "prep_time": 20, "cook_time": 40},
  "portions": 4
}
===COOKLANG===
Contenu CookLang complet
===END===

${COOKLANG_RULES}`;

  const result = await callGemini(apiKey, [textPart(prompt)], {
    ...ctx,
    feature: "generate",
    timeoutMs: 2 * 60 * 1000,
  });
  await recordTokenUsage(result, "generate", ctx.userId);

  return parseMetadataCooklang(result.response.text() ?? "");
}

/**
 * Répare les erreurs JSON courantes générées par Gemini :
 * - Clé sans valeur : `"unit" }` ou `"unit" ,` → `"unit": "" }` / `"unit": "" ,`
 */
function repairJson(json: string): string {
  // Détecte les clés en position objet (après { ou ,) NON suivies de ':'
  return json.replace(/([{,]\s*"(?:[^"\\]|\\.)*")(?!\s*:)(\s*[,}])/g, '$1: ""$2');
}

/** Parse les sections ===METADATA=== / ===COOKLANG=== / ===END=== retournées par Gemini. */
function parseMetadataCooklang(text: string): Record<string, unknown> {
  const trimmed = text.trim();
  if (!trimmed) throw new Error("Réponse Gemini vide");

  const metaMarker = "===METADATA===";
  const cooklangMarker = "===COOKLANG===";
  const endMarker = "===END===";

  const metaStart = trimmed.indexOf(metaMarker);
  const cooklangStart = trimmed.indexOf(cooklangMarker);
  if (metaStart === -1 || cooklangStart === -1) {
    throw new Error("Format de réponse Gemini invalide (marqueurs manquants)");
  }

  const metaJson = trimmed.substring(metaStart + metaMarker.length, cooklangStart).trim();
  const endIdx = trimmed.indexOf(endMarker);
  const cooklang = (endIdx === -1
    ? trimmed.substring(cooklangStart + cooklangMarker.length)
    : trimmed.substring(cooklangStart + cooklangMarker.length, endIdx)
  ).trim();

  const rawJson = extractJsonObject(metaJson);
  let data: Record<string, unknown>;
  try {
    data = JSON.parse(rawJson) as Record<string, unknown>;
  } catch (firstErr) {
    // Tentative de réparation du JSON malformé
    try {
      data = JSON.parse(repairJson(rawJson)) as Record<string, unknown>;
    } catch {
      throw firstErr;
    }
  }
  data.cooklang = cooklang;
  return data;
}
