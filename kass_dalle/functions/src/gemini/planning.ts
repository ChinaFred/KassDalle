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
  dishTypes?: string[];
  themes?: string[];
  cuisines?: string[];
  occasions?: string[];
  mainIngredients?: string[];
}

function asksForDessert(globalConstraints: string, dailyNotes: string): boolean {
  const text = `${globalConstraints} ${dailyNotes}`.toLowerCase();
  return [
    "dessert",
    "sucre",
    "sucré",
    "gouter",
    "goûter",
    "petit dej",
    "petit-déj",
    "petit dejeuner",
    "petit-déjeuner",
    "brunch",
  ].some((k) => text.includes(k));
}

function isDessertRecipe(recipe: PlanningRecipeSummary): boolean {
  const bag = [
    recipe.titre,
    ...(recipe.dishTypes ?? []),
    ...(recipe.themes ?? []),
    ...(recipe.occasions ?? []),
  ]
    .join(" ")
    .toLowerCase();

  return [
    "dessert",
    "sucre",
    "sucré",
    "gateau",
    "gâteau",
    "tarte",
    "beignet",
    "crepe",
    "crêpe",
    "brownie",
    "cookie",
    "mousse",
    "patis",
    "pâtis",
    "glace",
    "sorbet",
    "banane split",
  ].some((k) => bag.includes(k));
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
  /** True si la suggestion implique un redimensionnement/ajustement. */
  resized?: boolean;
  /** Détail du redimensionnement, si applicable. */
  resizeReason?: string;
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
  lines.push("Tu dois IMPÉRATIVEMENT respecter toutes les contraintes (globales et quotidiennes), maximiser la variété, et justifier chaque suggestion.");
  lines.push("Tu dois rigoureusement distinguer trois types de slots : (a) repas frais cuisiné le jour même, (b) repas servi un jour de batch cooking, qui reste un vrai repas de ce jour, (c) slot de réchauffage qui consomme un plat préparé un autre jour.");
  lines.push("");
  lines.push("=== RECETTES DISPONIBLES ===");
  for (const r of input.recipes) {
    const attrs: string[] = [];
    if (r.prepTime) attrs.push(`${r.prepTime}min prép`);
    if (r.cookTime) attrs.push(`${r.cookTime}min cuisson`);
    if (r.dishTypes && r.dishTypes.length > 0) attrs.push(`type: ${r.dishTypes.join(", ")}`);
    if (r.themes && r.themes.length > 0) attrs.push(`thèmes: ${r.themes.join(", ")}`);
    if (r.occasions && r.occasions.length > 0) attrs.push(`occasions: ${r.occasions.join(", ")}`);
    if (r.cuisines && r.cuisines.length > 0) attrs.push(`cuisine: ${r.cuisines.join(", ")}`);
    if (r.mainIngredients && r.mainIngredients.length > 0) attrs.push(`ingrédients: ${r.mainIngredients.join(", ")}`);
    lines.push(`- ID: ${r.id} | Titre: ${r.titre}${attrs.length ? " | " + attrs.join(" | ") : ""}`);
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

  if (input.batchCookingDay != null) {
    lines.push("=== RÔLE DU JOUR DE BATCH COOKING ===");
    lines.push(`Le jour de batch cooking est le jour de semaine n°${input.batchCookingDay} (1=lundi … 7=dimanche).`);
    lines.push("Ce jour-là, l'utilisateur a plus de temps pour cuisiner ou préparer à l'avance. Mais le repas SERVI ce jour-là reste un repas normal du cycle.");
    lines.push("Le plat préparé à l'avance pour plus tard n'est PAS obligatoirement le plat servi ce jour-là.");
    lines.push("Les slots taggés \"SLOT DE RÉCHAUFFAGE\" sont les seuls slots où l'on sert un plat préparé un autre jour.");
    lines.push("");
  }

  lines.push("=== JOURS À PLANIFIER ===");
  for (let i = 0; i < input.slotDates.length; i++) {
    const dateStr = input.slotDates[i];
    const date = new Date(dateStr);
    const weekday = ((date.getUTCDay() + 6) % 7) + 1; // 1=lundi
    const constraint = input.dailyConstraints[weekday];
    const isBatchCookingDay = input.batchCookingDay != null && weekday === input.batchCookingDay;
    const isReheatDay = !!constraint?.isBatchCooking && !isBatchCookingDay;
    let line = `Slot ${i} — ${dateStr}`;
    const tags: string[] = [];
    if (isBatchCookingDay) tags.push("JOUR DE BATCH COOKING (jour avec plus de temps; repas servi ce jour = repas normal)");
    if (isReheatDay) tags.push("SLOT DE RÉCHAUFFAGE (repas préparé un autre jour)");
    if (tags.length > 0) line += ` [TYPE : ${tags.join(" + ")}]`;
    if (constraint) {
      const parts: string[] = [];
      if (constraint.maxPrepMinutes && constraint.maxPrepMinutes > 0) {
        parts.push(`max ${constraint.maxPrepMinutes}min de préparation`);
      }
      if (isReheatDay) parts.push("réchauffage uniquement (préparé à l'avance)");
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
- "why" : en 1-2 phrases, explique pourquoi cette recette est adaptée (critères respectés) ou note les éventuelles contraintes enfreintes
- "resized" : true si tu as dû redimensionner/adapter la proposition, sinon false
- "resize_reason" : texte court décrivant ce qui a été redimensionné, chaîne vide si resized=false

Format attendu :
[{"slot": 0, "recipe_id": "abc123", "why": "Respecte la limite de 20min de préparation. Bonne variété avec les autres repas.", "resized": false, "resize_reason": ""}, ...]

Règles :
- respecte toutes les contraintes globales ET quotidiennes
- TU DOIS proposer une recette pour CHAQUE slot listé ci-dessus, y compris le jour de batch cooking. Ne saute un slot QUE si aucune recette n'est compatible avec ses contraintes ; dans ce cas explique-le dans le "why" d'un autre slot, mais c'est l'exception.
- VARIÉTÉ STRICTE DES RECETTES : chaque recette ne peut apparaître qu'une seule fois sur l'ensemble du cycle (les slots déjà assignés comptent), TANT QU'il reste au moins une recette compatible non utilisée
- VARIÉTÉ STRICTE DES INGRÉDIENTS / PROTÉINES : ne planifie pas plusieurs fois d'affilée la même protéine principale (porc, bœuf, poulet, poisson…) ni le même féculent dominant (pâtes, riz, pommes de terre…). Avant de proposer un plat, vérifie ses "type", "thèmes" et "ingrédients" dans la liste des recettes : si une protéine ou un féculent apparaît déjà 1 fois dans le cycle, ne le ressers que si AUCUNE autre recette compatible ne propose une alternative. Idéalement, alterne protéines et féculents pour couvrir le maximum de variété.
- Par défaut, ne propose PAS de recette de type dessert/sucré pour un repas principal. N'autorise un dessert comme plat que si les contraintes globales ou du jour le demandent explicitement.
- ne suggère JAMAIS le même plat sur deux slots consécutifs
- si une répétition (recette OU protéine/féculent) est vraiment inévitable, explique-le explicitement dans "why" en nommant les contraintes qui bloquent les alternatives
- n'invente jamais d'id

Règles spécifiques au batch cooking :
- Le slot "JOUR DE BATCH COOKING" est OBLIGATOIREMENT rempli : c'est le repas SERVI ce jour-là. Ne le laisse JAMAIS vide.
- Ce repas doit être traité comme un repas normal du cycle. Le fait que l'utilisateur fasse du batch cooking ce jour-là ne signifie PAS qu'il souhaite manger ce même plat le jour batch ET un jour de réchauffage.
- N'écris JAMAIS "réchauffage" pour ce slot.
- Les slots "SLOT DE RÉCHAUFFAGE" sont les seuls slots correspondant à un plat préparé un autre jour.
- N'utilise PAS automatiquement le même plat sur le jour batch et sur un slot de réchauffage. Une telle répétition n'est autorisée que si elle est explicitement inévitable faute d'alternative compatible, et doit alors être expliquée dans "why".`);

  const result = await callGemini(apiKey, [textPart(lines.join("\n"))], {
    ...ctx,
    feature: "planning",
    timeoutMs: 2 * 60 * 1000,
  });
  await recordTokenUsage(result, "planning", ctx.userId);

  const text = (result.response.text() ?? "").trim();
  if (!text) return [];

  try {
    const arr = JSON.parse(extractJsonArray(text)) as Array<{
      slot?: number;
      recipe_id?: string;
      justification?: string;
      why?: string;
      resized?: boolean;
      resize_reason?: string;
      resizeReason?: string;
    }>;
    const base = arr
      .filter((e) => typeof e.slot === "number" && typeof e.recipe_id === "string")
      .map((e) => {
        const slot = e.slot as number;
        const recipeId = e.recipe_id as string;
        const why = typeof e.why === "string"
          ? e.why
          : (typeof e.justification === "string" ? e.justification : undefined);
        const resized = typeof e.resized === "boolean" ? e.resized : false;
        const resizeReasonRaw = typeof e.resize_reason === "string"
          ? e.resize_reason
          : (typeof e.resizeReason === "string" ? e.resizeReason : "");
        const resizeReason = resizeReasonRaw.trim();

        // Calcul du jour de préparation pour les slots "réchauffage"
        let prepDate: string | undefined;
        const dateStr = input.slotDates[slot];
        if (dateStr && input.batchCookingDay != null) {
          const weekday = ((new Date(dateStr).getUTCDay() + 6) % 7) + 1;
          const constraint = input.dailyConstraints[weekday];
          const isBatchCookingDay = weekday === input.batchCookingDay;
          if (constraint?.isBatchCooking && !isBatchCookingDay) {
            prepDate = computePrepDate(dateStr, input.batchCookingDay);
          }
        }

        return {
          slot,
          recipeId,
          justification: why,
          resized,
          resizeReason: resizeReason.length > 0 ? resizeReason : undefined,
          prepDate,
        };
      });

    // Garde-fou variété : pas de doublon de recette sur le cycle tant qu'une
    // alternative existe. Le jour batch n'autorise pas automatiquement une
    // répétition avec un slot de réchauffage.
    const validRecipeIds = new Set(input.recipes.map((r) => r.id));
    const bySlot = [...base].sort((a, b) => a.slot - b.slot);
    const deduped: PlanningSlotResult[] = [];
    const usedRecipeIds = new Set<string>();

    for (const s of bySlot) {
      if (!validRecipeIds.has(s.recipeId)) continue;
      const dateStr = input.slotDates[s.slot];
      const weekday = dateStr ? ((new Date(dateStr).getUTCDay() + 6) % 7) + 1 : undefined;
      const constraint = weekday != null ? input.dailyConstraints[weekday] : undefined;
      const dailyNotes = constraint?.notes ?? "";
      const allowsDessert = asksForDessert(input.globalConstraints, dailyNotes);
      const recipe = input.recipes.find((r) => r.id === s.recipeId);
      if (recipe && isDessertRecipe(recipe) && !allowsDessert) continue;
      if (usedRecipeIds.has(s.recipeId)) continue;
      usedRecipeIds.add(s.recipeId);
      deduped.push(s);
    }

    return deduped;
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
