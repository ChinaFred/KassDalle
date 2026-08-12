/**
 * Suggestion de tags de recette (Cuisine + Type de plat).
 */

import { extractJsonObject } from "./client";
import { callModel } from "../ai/router";
import { textPart, type ModelCallContext } from "../ai/types";

export interface SuggestTagsInput {
  titre: string;
  cooklang: string;
}

/** Suggère les tags Cuisine et Type de plat pour une recette. */
export async function suggestRecipeTags(
  apiKey: string,
  input: SuggestTagsInput,
  ctx: ModelCallContext,
): Promise<{ cuisines: string[]; dishTypes: string[] }> {
  const content =
    input.cooklang.length > 2000
      ? input.cooklang.slice(0, 2000) + "\n...(tronqué)"
      : input.cooklang;

  const prompt = `Tu es un expert en classification culinaire. Analyse cette recette et suggère des tags de catégorisation.

TITRE: ${input.titre}

CONTENU (format CookLang):
${content}

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

Retourne UNIQUEMENT ce JSON (sans balises markdown, sans commentaire) :
{
  "cuisines": ["Cuisine1"],
  "dish_types": ["type1"]
}

Si la recette n'est pas culinaire ou si tu n'es pas sûr, retourne des tableaux vides.`;

  const result = await callModel({
    parts: [textPart(prompt)],
    geminiApiKey: apiKey,
    ctx: { ...ctx, feature: "suggest_tags", timeoutMs: 30_000 },
  });

  let json: Record<string, unknown> = {};
  try {
    json = JSON.parse(extractJsonObject(result.text || "{}")) as Record<string, unknown>;
  } catch {
    json = {};
  }

  const cuisines = Array.isArray(json?.cuisines)
    ? (json.cuisines as unknown[]).filter((s): s is string => typeof s === "string")
    : [];
  const dishTypes = Array.isArray(json?.dish_types)
    ? (json.dish_types as unknown[]).filter((s): s is string => typeof s === "string")
    : [];

  return { cuisines, dishTypes };
}
