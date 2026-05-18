/**
 * Suggestion de planning de repas via Gemini.
 * Porté depuis PlanningAiService.suggestMealPlan().
 */

import { callGemini, textPart, extractJsonArray, GeminiCallContext } from "./client";
import { recordTokenUsage } from "./tokenUsage";

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
}

export interface PlanningSlotResult {
  slot: number;
  recipeId: string;
}

/**
 * Retourne les suggestions sous forme de paires {slot, recipeId}.
 * Le client est responsable de la résolution recipeId → Recipe pleine.
 */
export async function suggestMealPlan(
  apiKey: string,
  input: PlanningInput,
  ctx: GeminiCallContext,
): Promise<PlanningSlotResult[]> {
  if (input.recipes.length === 0) return [];

  const lines: string[] = [];
  lines.push("Tu es un assistant culinaire. Tu dois proposer un planning de repas en choisissant parmi les recettes disponibles.");
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
    lines.push("=== CONTRAINTES GLOBALES ===");
    lines.push(input.globalConstraints.trim());
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
      if (constraint.isBatchCooking) parts.push("batch cooking");
      if (constraint.notes?.trim()) parts.push(constraint.notes.trim());
      if (parts.length > 0) line += ` [${parts.join(" | ")}]`;
    }
    lines.push(line);
  }
  lines.push("");
  lines.push("=== INSTRUCTIONS ===");
  lines.push(`Réponds UNIQUEMENT avec un tableau JSON valide :
[{"slot": 0, "recipe_id": "abc123"}, ...]
Règles : respecte les contraintes ; varie les recettes ; omets les slots sans recette adaptée ; n'invente jamais d'id.`);

  const result = await callGemini(apiKey, [textPart(lines.join("\n"))], {
    ...ctx,
    feature: "planning",
    timeoutMs: 2 * 60 * 1000,
  });
  await recordTokenUsage(result, "planning", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  if (!text) return [];

  try {
    const arr = JSON.parse(extractJsonArray(text)) as Array<{ slot?: number; recipe_id?: string }>;
    return arr
      .filter((e) => typeof e.slot === "number" && typeof e.recipe_id === "string")
      .map((e) => ({ slot: e.slot as number, recipeId: e.recipe_id as string }));
  } catch {
    return [];
  }
}
