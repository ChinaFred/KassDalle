/**
 * Suggestion de planning de repas via Gemini.
 * Porté depuis PlanningAiService.suggestMealPlan().
 */

import { callGemini, textPart, extractJsonArray, GeminiCallContext } from "./client";
import { recordTokenUsage } from "./tokenUsage";

export interface RecipeConceptInput {
  slotDate: string;
  globalConstraints: string;
  dayConstraint?: DayConstraint;
}

export interface RecipeConceptResult {
  titre: string;
  cooklang: string;
  justification: string;
}

export interface PlanningRecipeSummary {
  id: string;
  titre: string;
  prepTime?: number | null;
  cookTime?: number | null;
}

export interface DayConstraint {
  maxPrepMinutes?: number;
  isBatchCooking?: boolean;
  notes?: string;
}

export interface PlanningInput {
  recipes: PlanningRecipeSummary[];
  /** ISO 8601 dates pour chaque slot. */
  slotDates: string[];
  /** Map weekday (1=lundi … 7=dimanche) → contraintes. */
  dailyConstraints: Record<number, DayConstraint>;
  globalConstraints: string;
  /** Jour de la semaine dédié au batch cooking (1=lundi…7=dimanche). */
  batchCookingDay?: number;
  /** Recettes déjà assignées dans le cycle (pour éviter les répétitions). */
  alreadyAssigned?: Array<{ slot: number; recipeId: string }>;
}

export interface PlanningSlotResult {
  slot: number;
  recipeId: string;
  /** Justification de la suggestion : critères respectés ou enfreints. */
  justification?: string;
  /** ISO date (YYYY-MM-DD) du jour de préparation à l'avance, si applicable. */
  prepDate?: string;
}

/**
 * Retourne les suggestions sous forme de paires {slot, recipeId}.
 * Le client est responsable de la résolution recipeId → Recipe pleine.
 */
/** Calcule la date ISO du jour de batch cooking le plus récent avant slotDate. */
function computePrepDate(slotDateStr: string, batchCookingWeekday: number): string {
  const date = new Date(slotDateStr);
  const slotWeekday = ((date.getUTCDay() + 6) % 7) + 1; // 1=lundi
  let daysBack = (slotWeekday - batchCookingWeekday + 7) % 7;
  if (daysBack === 0) daysBack = 7; // même jour → semaine précédente
  const prepDate = new Date(date);
  prepDate.setUTCDate(date.getUTCDate() - daysBack);
  return prepDate.toISOString().slice(0, 10);
}

export async function suggestMealPlan(
  apiKey: string,
  input: PlanningInput,
  ctx: GeminiCallContext,
): Promise<PlanningSlotResult[]> {
  if (input.recipes.length === 0) return [];

  const lines: string[] = [];
  lines.push("Tu es un assistant culinaire expert. Tu dois proposer un planning de repas en choisissant parmi les recettes disponibles.");
  lines.push("Tu dois IMPÉRATIVEMENT respecter toutes les contraintes (globales et quotidiennes) et justifier chaque suggestion.");
  lines.push("");
  lines.push("=== RECETTES DISPONIBLES ===");
  for (const r of input.recipes) {
    const times: string[] = [];
    if (r.prepTime) times.push(`${r.prepTime}min prép`);
    if (r.cookTime) times.push(`${r.cookTime}min cuisson`);
    lines.push(`- ID: ${r.id} | Titre: ${r.titre}${times.length ? " | " + times.join(", ") : ""}`);
  }
  lines.push("");

  if (input.globalConstraints.trim()) {
    lines.push("=== PRÉFÉRENCES GÉNÉRALES (s'appliquent à TOUS les jours) ===");
    lines.push(input.globalConstraints.trim());
    lines.push("");
  }

  if (input.alreadyAssigned && input.alreadyAssigned.length > 0) {
    lines.push("=== REPAS DÉJÀ ASSIGNÉS (éviter les répétitions) ===");
    for (const a of input.alreadyAssigned) {
      const recipe = input.recipes.find((r) => r.id === a.recipeId);
      if (recipe) lines.push(`- Slot ${a.slot} : ${recipe.titre}`);
    }
    lines.push("");
  }

  lines.push("=== JOURS À PLANIFIER ===");
  for (let i = 0; i < input.slotDates.length; i++) {
    const dateStr = input.slotDates[i];
    const date = new Date(dateStr);
    const weekday = ((date.getUTCDay() + 6) % 7) + 1; // 1=lundi
    const constraint = input.dailyConstraints[weekday];
    let line = `Slot ${i} — ${dateStr}`;
    if (constraint) {
      const parts: string[] = [];
      if (constraint.maxPrepMinutes && constraint.maxPrepMinutes > 0) {
        parts.push(`max ${constraint.maxPrepMinutes}min de préparation`);
      }
      if (constraint.isBatchCooking) parts.push("réchauffage uniquement (préparé à l'avance)");
      if (constraint.notes?.trim()) parts.push(constraint.notes.trim());
      if (parts.length > 0) line += ` [PRÉFÉRENCES DU JOUR : ${parts.join(" | ")}]`;
    }
    lines.push(line);
  }
  lines.push("");
  lines.push("=== INSTRUCTIONS ===");
  lines.push(`Réponds UNIQUEMENT avec un tableau JSON valide. Pour chaque slot, indique :
- "slot" : numéro du slot
- "recipe_id" : l'ID exact de la recette choisie
- "justification" : en 1-2 phrases, explique pourquoi cette recette est adaptée (critères respectés) ou note les éventuelles contraintes enfreintes

Format attendu :
[{"slot": 0, "recipe_id": "abc123", "justification": "Respecte la limite de 20min de préparation. Bonne variété avec les autres repas."}, ...]

Règles : respecte toutes les contraintes globales ET quotidiennes ; varie les recettes sur le cycle ; omets les slots pour lesquels aucune recette n'est adaptée ; n'invente jamais d'id.`);

  const result = await callGemini(apiKey, [textPart(lines.join("\n"))], {
    ...ctx,
    feature: "planning",
    timeoutMs: 2 * 60 * 1000,
  });
  await recordTokenUsage(result, "planning", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  if (!text) return [];

  try {
    const arr = JSON.parse(extractJsonArray(text)) as Array<{ slot?: number; recipe_id?: string; justification?: string }>;
    return arr
      .filter((e) => typeof e.slot === "number" && typeof e.recipe_id === "string")
      .map((e) => {
        const slot = e.slot as number;
        const recipeId = e.recipe_id as string;
        const justification = typeof e.justification === "string" ? e.justification : undefined;

        // Calcul du jour de préparation pour les slots "réchauffage"
        let prepDate: string | undefined;
        const dateStr = input.slotDates[slot];
        if (dateStr && input.batchCookingDay != null) {
          const weekday = ((new Date(dateStr).getUTCDay() + 6) % 7) + 1;
          const constraint = input.dailyConstraints[weekday];
          if (constraint?.isBatchCooking) {
            prepDate = computePrepDate(dateStr, input.batchCookingDay);
          }
        }

        return { slot, recipeId, justification, prepDate };
      });
  } catch {
    return [];
  }
}

/**
 * Génère une recette de toutes pièces (conception IA) qui respecte les contraintes
 * d'un slot spécifique. Utilisé en fallback quand aucune recette existante ne convient.
 */
export async function generateRecipeConcept(
  apiKey: string,
  input: RecipeConceptInput,
  ctx: GeminiCallContext,
): Promise<RecipeConceptResult> {
  const lines: string[] = [];
  lines.push("Tu es un chef cuisinier expert. Crée une recette originale et réaliste qui respecte exactement les contraintes suivantes.");
  lines.push("La recette doit être faisable à la maison, délicieuse et adaptée à un repas familial.");
  lines.push("");

  if (input.globalConstraints.trim()) {
    lines.push("=== PRÉFÉRENCES GÉNÉRALES ===");
    lines.push(input.globalConstraints.trim());
    lines.push("");
  }

  if (input.dayConstraint) {
    const c = input.dayConstraint;
    const parts: string[] = [];
    if (c.maxPrepMinutes && c.maxPrepMinutes > 0) parts.push(`préparation max ${c.maxPrepMinutes}min`);
    if (c.isBatchCooking) parts.push("réchauffage uniquement (plat préparé à l'avance)");
    if (c.notes?.trim()) parts.push(c.notes.trim());
    if (parts.length > 0) {
      lines.push("=== CONTRAINTES DU JOUR ===");
      lines.push(parts.join(", "));
      lines.push("");
    }
  }

  lines.push("=== FORMAT DE RÉPONSE ===");
  lines.push("Réponds UNIQUEMENT avec un objet JSON valide (sans balises markdown) :");
  lines.push('{"titre": "Nom de la recette", "cooklang": "Contenu Cooklang complet", "justification": "Pourquoi cette recette est adaptée."}');
  lines.push("");
  lines.push("Règles Cooklang :");
  lines.push("- Métadonnées en début (une par ligne) : >> prepTime: XX  >> cookTime: XX  (en minutes)");
  lines.push("- Ingrédients : @nom{quantité%unité}  ex: @farine{200%g}  @oignon{1%}");
  lines.push("- Durées : ~{durée%unité}  ex: ~{15%min}");
  lines.push("- Ustensiles : #nom{}  ex: #casserole{}");

  const result = await callGemini(apiKey, [textPart(lines.join("\n"))], {
    ...ctx,
    feature: "planning_concept",
    timeoutMs: 90 * 1000,
  });
  await recordTokenUsage(result, "planning_concept", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  const cleaned = text.replace(/^```(?:json)?\s*\n?/, "").replace(/\n?```\s*$/, "").trim();
  try {
    const parsed = JSON.parse(cleaned) as { titre?: string; cooklang?: string; justification?: string };
    return {
      titre: parsed.titre ?? "Recette générée par l'IA",
      cooklang: parsed.cooklang ?? "",
      justification: parsed.justification ?? "Recette créée par l'IA selon les contraintes.",
    };
  } catch {
    return {
      titre: "Recette générée par l'IA",
      cooklang: "",
      justification: "Recette créée par l'IA selon les contraintes.",
    };
  }
}
