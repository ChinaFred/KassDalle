/**
 * Lecture en liste blanche des entrées des callables à entrée structurée.
 *
 * `refineRecipeFn`, `searchRecipesFn`, `suggestMealPlanFn` et
 * `generateRecipeConceptFn` reçoivent un objet que leur générateur recopie
 * dans le prompt. Les borner champ par champ puis transmettre l'objet du
 * client entier laissait passer tout champ oublié : `currentPortions` et
 * `batchCookingDay` partaient au modèle sans contrôle, quelle que soit leur
 * taille. Chaque lecteur ci-dessous construit l'objet transmis **à partir des
 * seuls champs validés** ; un champ inconnu n'y entre pas.
 *
 * Les éléments des listes et les objets imbriqués (résumés de recette,
 * contraintes du jour) sont transmis tels quels, bornés par la taille de leur
 * JSON (`STRUCTURED_ITEM_MAX_CHARS`, `STRUCTURED_OBJECT_MAX_CHARS`).
 *
 * Fonctions pures, testées par `tests/aiInputReaders.test.ts`.
 */

import type { RefineInput } from "../gemini/refiner";
import type { SearchRecipesInput } from "../gemini/search";
import { PLANNING_RUN_ID_PATTERN } from "../gemini/planning";
import type {
  DayConstraint,
  PlanningInput,
  PlanningRecipeSummary,
  RecentlyServedMeal,
  RecipeConceptInput,
} from "../gemini/planning";
import { HttpsError } from "firebase-functions/v2/https";
import {
  type AiInputSizes,
  CORPUS_MAX_ITEMS,
  LIST_MAX_ITEMS,
  RECIPE_TEXT_MAX_CHARS,
  SHORT_TEXT_MAX_CHARS,
  STRUCTURED_ITEM_MAX_CHARS,
  STRUCTURED_OBJECT_MAX_CHARS,
} from "./_inputBounds";

/** Créneaux d'une génération : un mois au plus. */
export const PLANNING_SLOTS_MAX = 31;

/** Une date de créneau commence par AAAA-MM-JJ (le client envoie un ISO 8601). */
export const SLOT_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}/;

/** Recettes écartées d'un même créneau. */
export const DISMISSED_PER_SLOT_MAX = 30;

/** Longueur d'un identifiant de recette (Firestore : 20 caractères). */
export const RECIPE_ID_MAX_CHARS = 128;

/** Nombre de portions d'une recette : large, une recette de collectivité compte. */
export const PORTIONS_MAX = 1_000;

/** `refineRecipeFn` — feature `refine`. */
export function readRefineInput(data: Record<string, unknown>, inputs: AiInputSizes): RefineInput {
  return {
    instruction: inputs.text(data.instruction, {
      field: "instruction",
      max: SHORT_TEXT_MAX_CHARS,
      required: true,
    }),
    currentCooklang: inputs.text(data.currentCooklang, {
      field: "currentCooklang",
      max: RECIPE_TEXT_MAX_CHARS,
      required: true,
    }),
    currentTitre:
      inputs.text(data.currentTitre, { field: "currentTitre", max: SHORT_TEXT_MAX_CHARS }) ?? "",
    currentIngredients:
      inputs.list<RefineInput["currentIngredients"][number]>(data.currentIngredients, {
        field: "currentIngredients",
        maxItems: LIST_MAX_ITEMS,
        maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
      }) ?? [],
    currentTags:
      inputs.object(data.currentTags, {
        field: "currentTags",
        maxChars: STRUCTURED_OBJECT_MAX_CHARS,
      }) ?? {},
    // 0 admis : une recette dont les portions n'ont pas été lues en porte 0.
    currentPortions:
      inputs.number(data.currentPortions, {
        field: "currentPortions",
        min: 0,
        max: PORTIONS_MAX,
      }) ?? null,
  };
}

/** `searchRecipesFn` — feature `search`. */
export function readSearchInput(
  data: Record<string, unknown>,
  inputs: AiInputSizes,
): SearchRecipesInput {
  return {
    query: inputs.text(data.query, { field: "query", max: SHORT_TEXT_MAX_CHARS, required: true }),
    recipes:
      inputs.list<Record<string, string>>(data.recipes, {
        field: "recipes",
        maxItems: CORPUS_MAX_ITEMS,
        maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
      }) ?? [],
    ratedRecipes:
      inputs.list<Record<string, string>>(data.ratedRecipes, {
        field: "ratedRecipes",
        maxItems: CORPUS_MAX_ITEMS,
        maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
      }) ?? [],
  };
}

/** Identifiant de groupe familial : un identifiant de document Firestore. */
const GROUP_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * `suggestMealPlanFn` — le planning visé : `null` pour le planning personnel,
 * l'identifiant du groupe pour un planning de groupe. Lu à part : il ne part
 * pas au modèle, il sert au contrôle d'appartenance et à la traçabilité.
 */
export function readPlanningGroupId(data: Record<string, unknown>): string | null {
  const raw = data.groupId;
  if (raw === undefined || raw === null) return null;
  if (typeof raw !== "string" || !GROUP_ID_PATTERN.test(raw)) {
    throw new HttpsError("invalid-argument", "« groupId » n'est pas un identifiant de groupe.");
  }
  return raw;
}

/** `suggestMealPlanFn` — feature `planning`. */
export function readPlanningInput(
  data: Record<string, unknown>,
  inputs: AiInputSizes,
): PlanningInput {
  const slotConstraints = inputs.list<DayConstraint | null>(data.slotConstraints, {
    field: "slotConstraints",
    maxItems: LIST_MAX_ITEMS,
    maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
  });
  const batchCookingDay = inputs.number(data.batchCookingDay, {
    field: "batchCookingDay",
    min: 1,
    max: 7,
    integer: true,
  });
  const alreadyAssigned = inputs.list<{ slot: number; recipeId: string }>(data.alreadyAssigned, {
    field: "alreadyAssigned",
    maxItems: LIST_MAX_ITEMS,
    maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
  });
  const recentlyServed = inputs.list<RecentlyServedMeal>(data.recentlyServed, {
    field: "recentlyServed",
    maxItems: LIST_MAX_ITEMS,
    maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
  });
  // Liste blanche : une autre valeur n'est pas « model » par défaut, elle est
  // refusée — un mode deviné pourrait lancer un appel facturé.
  const modeRaw = inputs.text(data.mode, { field: "mode", max: 10 });
  if (modeRaw !== undefined && modeRaw !== "model" && modeRaw !== "code") {
    throw new HttpsError("invalid-argument", "« mode » doit valoir « model » ou « code ».");
  }
  const mode = modeRaw as "model" | "code" | undefined;
  const dismissedRaw = inputs.list<unknown>(data.slotDismissed, {
    field: "slotDismissed",
    maxItems: LIST_MAX_ITEMS,
    maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
  });
  const slotDates = inputs.list<string>(data.slotDates, {
    field: "slotDates",
    maxItems: PLANNING_SLOTS_MAX,
    maxItemChars: SHORT_TEXT_MAX_CHARS,
    required: true,
  });
  // Une date de créneau commence par AAAA-MM-JJ : elle sert de clé de lecture
  // de l'historique et de jour de semaine, jamais de texte libre.
  for (const d of slotDates) {
    if (typeof d !== "string" || !SLOT_DATE_PATTERN.test(d)) {
      throw new HttpsError("invalid-argument", "« slotDates » attend des dates AAAA-MM-JJ.");
    }
  }
  if (dismissedRaw !== undefined && dismissedRaw.length > slotDates.length) {
    throw new HttpsError(
      "invalid-argument",
      "« slotDismissed » ne peut pas compter plus d'éléments que « slotDates ».",
    );
  }
  // Chaque élément est une liste d'identifiants ; le reste devient `null`.
  const slotDismissed = dismissedRaw?.map((item) => {
    if (!Array.isArray(item)) return null;
    const ids = item.filter((id): id is string => typeof id === "string");
    if (ids.length > DISMISSED_PER_SLOT_MAX || ids.some((id) => id.length > RECIPE_ID_MAX_CHARS)) {
      throw new HttpsError(
        "invalid-argument",
        `« slotDismissed » : ${DISMISSED_PER_SLOT_MAX} identifiants de ${RECIPE_ID_MAX_CHARS} caractères au plus par créneau.`,
      );
    }
    return ids;
  });
  return {
    slotDates,
    recipes:
      inputs.list<PlanningRecipeSummary>(data.recipes, {
        field: "recipes",
        maxItems: CORPUS_MAX_ITEMS,
        maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
      }) ?? [],
    globalConstraints:
      inputs.text(data.globalConstraints, {
        field: "globalConstraints",
        max: SHORT_TEXT_MAX_CHARS,
      }) ?? "",
    dailyConstraints:
      inputs.object<Record<number, DayConstraint>>(data.dailyConstraints, {
        field: "dailyConstraints",
        maxChars: STRUCTURED_OBJECT_MAX_CHARS,
      }) ?? {},
    ...(slotConstraints !== undefined ? { slotConstraints } : {}),
    ...(batchCookingDay !== undefined ? { batchCookingDay } : {}),
    ...(alreadyAssigned !== undefined ? { alreadyAssigned } : {}),
    ...(recentlyServed !== undefined ? { recentlyServed } : {}),
    ...(mode !== undefined ? { mode } : {}),
    ...(slotDismissed !== undefined ? { slotDismissed } : {}),
  };
}

/** `generateRecipeConceptFn` — feature `planning_concept`. */
export function readConceptInput(
  data: Record<string, unknown>,
  inputs: AiInputSizes,
): RecipeConceptInput {
  const dayConstraint = inputs.object<DayConstraint>(data.dayConstraint, {
    field: "dayConstraint",
    maxChars: STRUCTURED_ITEM_MAX_CHARS,
  });
  const alreadyPlanned = inputs.list<string>(data.alreadyPlanned, {
    field: "alreadyPlanned",
    maxItems: LIST_MAX_ITEMS,
    maxItemChars: SHORT_TEXT_MAX_CHARS,
  });
  const requestedDish = inputs.object<{ titre: string; description?: string }>(data.requestedDish, {
    field: "requestedDish",
    maxChars: STRUCTURED_ITEM_MAX_CHARS,
  });
  const runId = inputs.text(data.runId, { field: "runId", max: 64 });
  if (runId !== undefined && !PLANNING_RUN_ID_PATTERN.test(runId)) {
    throw new HttpsError("invalid-argument", "« runId » n'est pas un identifiant de génération.");
  }
  return {
    slotDate: inputs.text(data.slotDate, {
      field: "slotDate",
      max: SHORT_TEXT_MAX_CHARS,
      required: true,
    }),
    globalConstraints:
      inputs.text(data.globalConstraints, {
        field: "globalConstraints",
        max: SHORT_TEXT_MAX_CHARS,
      }) ?? "",
    ...(dayConstraint !== undefined ? { dayConstraint } : {}),
    ...(alreadyPlanned !== undefined ? { alreadyPlanned } : {}),
    ...(requestedDish !== undefined ? { requestedDish } : {}),
    ...(runId !== undefined ? { runId } : {}),
  };
}
