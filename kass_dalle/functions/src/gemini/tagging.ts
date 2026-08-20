/**
 * Passe 2 — balisage CookLang et normalisation de la liste d'ingrédients.
 *
 * Cette passe ne voit jamais l'image : elle travaille sur ce que la passe 1 a
 * recopié. C'est ce qui rend la fidélité VÉRIFIABLE — on peut confronter sa
 * sortie à son entrée, ligne à ligne, sans appeler personne (voir `fidelity`).
 *
 * Elle rend aussi la liste normalisée, une entrée par ligne du livre, avec la
 * note explicative que le balisage inline ne pouvait pas porter : « 1 filet de
 * saumon de 1,8 kg avec la peau mais écaillée » devient un ingrédient de 1,8 kg
 * et une note « avec la peau mais écaillée », sans que la phrase du livre soit
 * touchée.
 */

import { extractJsonObject } from "./client";
import { logAiText, logError } from "../logging";
import { callModel } from "../ai/router";
import { textPart, type ModelCallContext } from "../ai/types";
import { TAGGING_PROMPT } from "./promptsExtraction";
import type { TranscribedRecipe } from "./transcription";

const TAGGING_MAX_TOKENS = 24_000;

/** Une ligne d'ingrédient du livre, séparée en ce qui se compte et ce qui se dit. */
export interface NormalizedIngredientLine {
  /** La ligne du livre, inchangée — la pièce à conviction. */
  brut: string;
  /** Titre de la section d'ingrédients d'où vient la ligne, ou vide. */
  section: string;
  nom: string;
  qte: string;
  unite: string;
  /** « avec la peau mais écaillée », « dégermées » — vide s'il n'y a rien à dire. */
  note: string;
}

export interface TaggedRecipe {
  cooklang: string;
  ingredients: NormalizedIngredientLine[];
  cuisines: string[];
  dishTypes: string[];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function asStringList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(asString).filter((s) => s.length > 0);
}

/** Toutes les lignes d'ingrédients de la transcription, sections aplaties. */
export function ingredientLinesOf(recipe: TranscribedRecipe): string[] {
  return recipe.sectionsIngredients.flatMap((s) => s.lignes);
}

/** Le nombre d'étapes recopiées, toutes sections confondues. */
export function stepCountOf(recipe: TranscribedRecipe): number {
  return recipe.sectionsEtapes.reduce((total, s) => total + s.etapes.length, 0);
}

/** Met la transcription sous une forme que le modèle relit sans ambiguïté. */
export function renderTranscriptionForTagging(recipe: TranscribedRecipe): string {
  const out: string[] = [];
  out.push(`TITRE : ${recipe.titre}`);
  if (recipe.page != null) out.push(`PAGE : ${recipe.page}`);
  if (recipe.portions != null) out.push(`PORTIONS : ${recipe.portions}`);
  if (recipe.tempsPreparation) out.push(`TEMPS DE PRÉPARATION : ${recipe.tempsPreparation}`);
  if (recipe.tempsCuisson) out.push(`TEMPS DE CUISSON : ${recipe.tempsCuisson}`);
  if (recipe.difficulte) out.push(`DIFFICULTÉ : ${recipe.difficulte}`);

  out.push("");
  out.push("═══ LISTE D'INGRÉDIENTS ═══");
  // Numérotées : le modèle doit rendre autant d'entrées, dans le même ordre, et
  // un numéro rend l'écart immédiatement lisible dans les journaux.
  let n = 0;
  for (const section of recipe.sectionsIngredients) {
    out.push(section.titre ? `-- section : ${section.titre}` : "-- section : (sans titre)");
    for (const ligne of section.lignes) {
      n += 1;
      out.push(`${n}. ${ligne}`);
    }
  }

  out.push("");
  out.push("═══ ÉTAPES ═══");
  let e = 0;
  for (const section of recipe.sectionsEtapes) {
    out.push(section.titre ? `-- section : ${section.titre}` : "-- section : (sans titre)");
    for (const etape of section.etapes) {
      e += 1;
      out.push(`${e}. ${etape}`);
    }
  }

  if (recipe.notes.length > 0) {
    out.push("");
    out.push("═══ NOTES ═══");
    for (const note of recipe.notes) {
      out.push(`${note.genre || "Note"} : ${note.texte}`);
    }
  }

  return out.join("\n");
}

/** Reconstruit le résultat depuis le JSON du modèle, sans rien inventer. */
export function parseTagged(json: Record<string, unknown>): TaggedRecipe {
  const ingredientsRaw = Array.isArray(json.ingredients) ? json.ingredients : [];
  return {
    cooklang: typeof json.cooklang === "string" ? json.cooklang.trim() : "",
    ingredients: ingredientsRaw
      .filter((i): i is Record<string, unknown> => !!i && typeof i === "object")
      .map((i) => ({
        brut: asString(i.brut),
        section: asString(i.section),
        nom: asString(i.nom),
        qte: asString(i.qte),
        unite: asString(i.unite),
        note: asString(i.note),
      }))
      .filter((i) => i.nom.length > 0),
    cuisines: asStringList(json.cuisines),
    dishTypes: asStringList(json.dish_types),
  };
}

/**
 * Balise une recette transcrite et normalise sa liste d'ingrédients.
 *
 * Un seul appel rend le texte balisé, la liste, et les tags — ces derniers
 * coûtaient un appel séparé pour une question à laquelle le texte répond déjà.
 */
export async function tagAndNormalize(
  recipe: TranscribedRecipe,
  ctx: ModelCallContext,
): Promise<TaggedRecipe> {
  const transcription = renderTranscriptionForTagging(recipe);

  const result = await callModel({
    parts: [
      textPart(`${TAGGING_PROMPT}\n\n═══════════ TRANSCRIPTION ═══════════\n${transcription}`),
    ],
    ctx: { ...ctx, feature: "recipe_tagging", timeoutMs: 3 * 60 * 1000 },
    maxTokens: TAGGING_MAX_TOKENS,
  });

  const text = result.text.trim();
  await logAiText({
    stage: "balisage",
    text,
    message: "Recette balisée et liste normalisée",
    feature: "recipe_tagging",
    provider: result.provider,
    model: result.model,
    moduleType: "IMPORT",
    correlationId: ctx.correlationId,
    jobId: ctx.jobId,
    userId: ctx.userId,
    extra: {
      titre: recipe.titre,
      lignesRecues: ingredientLinesOf(recipe).length,
      etapesRecues: stepCountOf(recipe),
    },
  });

  try {
    return parseTagged(JSON.parse(extractJsonObject(text)) as Record<string, unknown>);
  } catch (err) {
    await logError({
      message: "tagAndNormalize: réponse illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      extra: { titre: recipe.titre, longueur: text.length },
    });
    throw new Error("Le balisage de la recette n'a pas pu être lu.");
  }
}
