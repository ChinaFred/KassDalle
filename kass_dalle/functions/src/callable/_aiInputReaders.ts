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
import type {
  DayConstraint,
  PlanningInput,
  PlanningRecipeSummary,
  RecentlyServedMeal,
  RecipeConceptInput,
} from "../gemini/planning";
import {
  type AiInputSizes,
  CORPUS_MAX_ITEMS,
  LIST_MAX_ITEMS,
  RECIPE_TEXT_MAX_CHARS,
  SHORT_TEXT_MAX_CHARS,
  STRUCTURED_ITEM_MAX_CHARS,
  STRUCTURED_OBJECT_MAX_CHARS,
} from "./_inputBounds";

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
  return {
    slotDates: inputs.list<string>(data.slotDates, {
      field: "slotDates",
      maxItems: LIST_MAX_ITEMS,
      maxItemChars: SHORT_TEXT_MAX_CHARS,
      required: true,
    }),
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
  };
}
