/**
 * Suggestion de tags de recette : cuisine, type de plat, et rôle dans un repas.
 */

import { extractJsonObject } from "./client";
import { callModel } from "../ai/router";
import { textPart, type ModelCallContext } from "../ai/types";
import { logError } from "../logging";
import {
  MAIN_PROTEIN_STARCH_JSON_KEYS,
  MAIN_PROTEIN_STARCH_PROMPT,
  MEAL_ROLE_JSON_KEYS,
  MEAL_ROLE_PROMPT,
  parseMainProteinStarch,
  parseMealRoleFields,
  type MainProteinStarch,
  type MealRole,
  type MealRoleFields,
} from "./mealRole";

export interface SuggestTagsInput {
  titre: string;
  cooklang: string;
}

/** Ce que rend la suggestion : les tags historiques, plus le rôle dans un repas. */
export interface SuggestedTags extends MealRoleFields {
  cuisines: string[];
  dishTypes: string[];
}

/** Le CookLang envoyé au modèle, borné : la classification n'a pas besoin de tout. */
function truncatedContent(cooklang: string): string {
  return cooklang.length > 2000 ? cooklang.slice(0, 2000) + "\n...(tronqué)" : cooklang;
}

/** Lit l'objet JSON de la réponse ; vide, et journalisé, quand elle est illisible. */
async function readJson(text: string, ctx: ModelCallContext, feature: string) {
  try {
    return JSON.parse(extractJsonObject(text || "{}")) as Record<string, unknown>;
  } catch (e) {
    // Une réponse illisible rend des tags vides : sans ce journal, l'écran
    // dirait « aucune suggestion » pour une panne de lecture.
    await logError("Classification d'une recette — réponse du modèle illisible", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      geminiStatus: "ERROR",
      feature,
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { responsePreview: (text || "").slice(0, 300) },
    });
    return {} as Record<string, unknown>;
  }
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

/** Suggère cuisine, type de plat et rôle dans un repas pour une recette. */
export async function suggestRecipeTags(
  apiKey: string,
  input: SuggestTagsInput,
  ctx: ModelCallContext,
): Promise<SuggestedTags> {
  const prompt = `Tu es un expert en classification culinaire. Analyse cette recette et suggère des tags de catégorisation.

TITRE: ${input.titre}

CONTENU (format CookLang):
${truncatedContent(input.cooklang)}

Règles de classification :

"cuisines" = style ou origine culinaire.
Exemples : Mexicain, Asiatique, Français, Belge, Méditerranéen, Américain, Indien, Japonais, Street food, Junk food, Gastro, Terroir, Rapide, Végétalien...
- "Street food" = style de cuisine urbain/ambulant → c'est une Cuisine, pas un type de plat
- "plat complet" ou "tout-en-un" → appartient aux dish_types, pas aux cuisines
- Première lettre en majuscule
- 1 à 3 valeurs

"dish_types" = structure du plat, UNIQUEMENT parmi ces valeurs exactes (en minuscules) :
viande | volaille | poisson | fruits de mer | végétarien | vegan | dessert | pâtisserie | soupe | entrée | plat complet | snack
- "plat complet" = plat contenant protéines + féculents + légumes (tout-en-un)
- 1 à 2 valeurs

${MEAL_ROLE_PROMPT}

Retourne UNIQUEMENT ce JSON (sans balises markdown, sans commentaire) :
{
  "cuisines": ["Cuisine1"],
  "dish_types": ["type1"],
  ${MEAL_ROLE_JSON_KEYS}
}

Si la recette n'est pas culinaire ou si tu n'es pas sûr, retourne des tableaux vides et "meal_role" vide.`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, feature: "suggest_tags", timeoutMs: 30_000 },
  });

  const json = await readJson(result.text, ctx, "suggest_tags");
  return {
    cuisines: asStrings(json.cuisines),
    dishTypes: asStrings(json.dish_types),
    ...parseMealRoleFields(json),
  };
}

/**
 * Le rôle dans un repas, seul.
 *
 * Pour le backfill « Rôle des recettes » : les cuisines et types de plat
 * existants ne sont pas redemandés, ils ont pu être corrigés à la main. Le
 * poste de coût est celui de l'appelant (`ctx.feature`), pas celui de la
 * suggestion de tags : une reprise en masse se lit à part dans les comptes.
 */
export async function suggestMealRole(
  apiKey: string,
  input: { titre: string; cooklang: string; dishTypes: string[] },
  ctx: ModelCallContext,
): Promise<MealRoleFields> {
  const dishTypes = input.dishTypes.filter((t) => t.trim().length > 0);
  const prompt = `Tu es un expert en classification culinaire. Dis quel rôle cette recette tient dans un repas.

TITRE: ${input.titre}
${dishTypes.length > 0 ? `TYPES DE PLAT DÉJÀ CONNUS: ${dishTypes.join(", ")}\n` : ""}
CONTENU (format CookLang):
${truncatedContent(input.cooklang)}

${MEAL_ROLE_PROMPT}

Retourne UNIQUEMENT ce JSON (sans balises markdown, sans commentaire) :
{
  ${MEAL_ROLE_JSON_KEYS}
}

Si la recette n'est pas culinaire ou si tu n'es pas sûr, laisse "meal_role" vide.`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, timeoutMs: 30_000 },
  });

  const json = await readJson(result.text, ctx, ctx.feature);
  return parseMealRoleFields(json);
}

/**
 * La protéine et le féculent principaux, seuls, d'une recette dont le rôle
 * est connu.
 *
 * Pour le backfill « Protéine et féculent des plats » : le rôle, ce que la
 * recette apporte et ses accompagnements ont pu être corrigés à la main, ils
 * ne sont ni redemandés ni réécrits. Le rôle est donné au modèle, pas
 * demandé. Le poste de coût est celui de l'appelant (`ctx.feature`).
 */
export async function suggestMainProteinStarch(
  input: { titre: string; cooklang: string; mealRole: MealRole; dishTypes: string[] },
  ctx: ModelCallContext,
): Promise<MainProteinStarch> {
  const dishTypes = input.dishTypes.filter((t) => t.trim().length > 0);
  const prompt = `Tu es un expert en classification culinaire. Dis quelle est la protéine principale et le féculent principal de cette recette.

TITRE: ${input.titre}
RÔLE DANS UN REPAS: ${input.mealRole}
${dishTypes.length > 0 ? `TYPES DE PLAT DÉJÀ CONNUS: ${dishTypes.join(", ")}\n` : ""}
CONTENU (format CookLang):
${truncatedContent(input.cooklang)}

${MAIN_PROTEIN_STARCH_PROMPT}

Retourne UNIQUEMENT ce JSON (sans balises markdown, sans commentaire) :
{
  ${MAIN_PROTEIN_STARCH_JSON_KEYS}
}

Si tu n'es pas sûr d'une valeur, laisse-la vide.`;

  const result = await callModel({
    parts: [textPart(prompt)],
    ctx: { ...ctx, timeoutMs: 30_000 },
  });

  const json = await readJson(result.text, ctx, ctx.feature);
  return parseMainProteinStarch(json);
}
