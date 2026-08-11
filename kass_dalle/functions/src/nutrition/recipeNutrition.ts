/**
 * Calcul et persistance de la nutrition d'une recette.
 *
 * Convertit chaque ingrédient en grammes (référentiel d'unités + densité),
 * agrège les valeurs per100g du référentiel d'ingrédients, calcule la
 * couverture, le score qualité, puis écrit l'instantané sur la recette.
 *
 * Extrait de callable/nutritionCallable.ts.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

import { COLL_RECIPES, COLL_NUTRITION_UNITS } from "../config";
import { getNutritionSourcePolicy } from "./policy";
import { normalizeNutrients } from "./nutrients";
import { buildIngredientLookupIds } from "./ingredientName";
import {
  normalizeObservedUnit,
  resolveUnitFactorToGrams,
  type ReferentialUnitOverride,
} from "./quantityConversion";
import { asPositiveNumber, roundValue } from "./unitDisplay";

interface IngredientInput {
  name?: unknown;
  qty?: unknown;
  unit?: unknown;
}

interface IngredientProfile {
  per100g?: Record<string, unknown>;
  source?: string;
}

interface IngredientResolution {
  name: string;
  weightGrams: number;
  lookupIds: string[];
}

const NUTRIENT_KEYS = [
  "kcal",
  "protein_g",
  "carbs_g",
  "sugar_g",
  "fiber_g",
  "fat_g",
  "saturated_fat_g",
  "sodium_mg",
  "salt_g",
] as const;
export interface ComputedNutritionResult {
  recipeId: string;
  nutrition: Record<string, unknown>;
}


export async function computeAndPersistRecipeNutrition(args: {
  recipeId: string;
  selectedPortions?: number;
}): Promise<ComputedNutritionResult> {
  const db = getFirestore();
  const recipeRef = db.collection(COLL_RECIPES).doc(args.recipeId);
  const recipeSnap = await recipeRef.get();
  if (!recipeSnap.exists) {
    throw new HttpsError("not-found", "Recette introuvable.");
  }

  const recipe = recipeSnap.data() as Record<string, unknown>;
  const rawIngredients = Array.isArray(recipe.ingredients) ? recipe.ingredients : [];
  const ingredients: IngredientInput[] = rawIngredients
    .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    .map((item) => ({ name: item.name, qty: item.qty, unit: item.unit }));

  if (ingredients.length === 0) {
    const emptySnapshot = {
      selected_portions: asPositiveNumber(args.selectedPortions) ?? asPositiveNumber(recipe.portions) ?? 1,
      total_weight_g: 0,
      coverage: 0,
      coverage_state: "low",
      totals: {},
      per_portion: {},
      per_100g: null,
      quality: {
        score: 0,
        level: "C",
        warnings: ["Aucun ingrédient exploitable pour calculer la nutrition."],
      },
      missing_ingredients: [],
      policy_version: 0,
      computed_at: FieldValue.serverTimestamp(),
      fallback_policy: "none",
    };

    await recipeRef.set({ nutrition: emptySnapshot }, { merge: true });

    return {
      recipeId: args.recipeId,
      nutrition: {
        ...emptySnapshot,
        computed_at: new Date().toISOString(),
      },
    };
  }

  const selectedPortions = asPositiveNumber(args.selectedPortions) ??
    asPositiveNumber(recipe.portions) ??
    1;

  const policy = await getNutritionSourcePolicy();

  const totals: Record<string, number> = {};
  const missingIngredients: string[] = [];
  let totalWeightGrams = 0;
  let convertibleCount = 0;
  let mappedCount = 0;

  // Pré-charge depuis nutrition_units les données de conversion des unités présentes
  // dans la recette. Le référentiel permet de corriger un poids depuis l'écran
  // d'administration sans redéploiement — voir resolveUnitFactorToGrams() pour la
  // règle exacte : sur une unité de volume c'est le volume qui est retenu, jamais un
  // poids figé, car les grammes dépendent de la densité de l'ingrédient.
  const referentialUnits = new Map<string, ReferentialUnitOverride>();
  {
    const unitsToFetch = new Set<string>();
    for (const ingredient of ingredients) {
      const unitStr = typeof ingredient.unit === "string" ? ingredient.unit.trim() : "";
      if (!unitStr) continue;
      const normalized = normalizeObservedUnit(unitStr);
      if (normalized) unitsToFetch.add(normalized);
    }
    if (unitsToFetch.size > 0) {
      const refs = [...unitsToFetch].map((u) => db.collection(COLL_NUTRITION_UNITS).doc(u));
      const unitSnaps = await db.getAll(...refs);
      for (const snap of unitSnaps) {
        if (!snap.exists) continue;
        const data = snap.data() as Record<string, unknown>;
        referentialUnits.set(snap.id, {
          measurementType:
            typeof data.measurement_type === "string" ? data.measurement_type : undefined,
          gramsPerUnit:
            typeof data.grams_per_unit === "number" ? data.grams_per_unit : undefined,
          volumeMlPerUnit:
            typeof data.volume_ml_per_unit === "number" ? data.volume_ml_per_unit : undefined,
        });
      }
    }
  }

  const resolutions: IngredientResolution[] = [];
  const uniqueLookupIds = new Set<string>();

  for (const ingredient of ingredients) {
    const name = typeof ingredient.name === "string" ? ingredient.name.trim() : "";
    if (!name) continue;

    const qty = asPositiveNumber(ingredient.qty);
    const unitStr = typeof ingredient.unit === "string" ? ingredient.unit.trim() : "";
    const normalizedUnit = unitStr ? normalizeObservedUnit(unitStr) : "";
    const factor = resolveUnitFactorToGrams(
      unitStr,
      name,
      normalizedUnit ? (referentialUnits.get(normalizedUnit) ?? null) : null,
    );
    if (qty == null || factor == null) {
      missingIngredients.push(name);
      continue;
    }

    convertibleCount++;
    const weightGrams = qty * factor;
    totalWeightGrams += weightGrams;

    const lookupIds = buildIngredientLookupIds(name);
    if (lookupIds.length === 0) {
      missingIngredients.push(name);
      continue;
    }

    for (const lookupId of lookupIds) {
      uniqueLookupIds.add(lookupId);
    }
    resolutions.push({ name, weightGrams, lookupIds });
  }

  const normalizedProfilesById = new Map<string, Record<string, number>>();
  const docsToFetch = [...uniqueLookupIds].map((id) => db.collection("nutrition_ingredients").doc(id));

  for (let i = 0; i < docsToFetch.length; i += 300) {
    const chunk = docsToFetch.slice(i, i + 300);
    if (chunk.length === 0) continue;
    const snaps = await db.getAll(...chunk);
    for (const snap of snaps) {
      if (!snap.exists) continue;
      const profile = snap.data() as IngredientProfile;
      const normalized = normalizeNutrients(profile.per100g ?? {});
      if (Object.keys(normalized).length === 0) continue;
      normalizedProfilesById.set(snap.id, normalized);
    }
  }

  for (const resolution of resolutions) {
    let normalizedProfile: Record<string, number> | null = null;
    for (const profileId of resolution.lookupIds) {
      const candidate = normalizedProfilesById.get(profileId);
      if (!candidate) continue;
      normalizedProfile = candidate;
      break;
    }

    if (!normalizedProfile) {
      missingIngredients.push(resolution.name);
      continue;
    }

    mappedCount++;
    for (const key of NUTRIENT_KEYS) {
      const per100 = normalizedProfile[key] ?? 0;
      if (!Number.isFinite(per100) || per100 <= 0) continue;
      totals[key] = (totals[key] ?? 0) + (resolution.weightGrams * per100) / 100;
    }
  }

  const coverage = ingredients.length > 0 ? mappedCount / ingredients.length : 0;
  const canShowPer100g = coverage >= policy.quality_policy.minCoverageForPer100g && totalWeightGrams > 0;
  const canShowPartial = coverage >= policy.quality_policy.minCoverageForPartial;

  const perPortion: Record<string, number> = {};
  const per100g: Record<string, number> = {};
  for (const key of NUTRIENT_KEYS) {
    const total = totals[key] ?? 0;
    if (total <= 0) continue;
    perPortion[key] = roundValue(total / selectedPortions, key === "kcal" ? 0 : 2);
    if (canShowPer100g) {
      per100g[key] = roundValue((total / totalWeightGrams) * 100, key === "kcal" ? 0 : 2);
    }
    totals[key] = roundValue(total, key === "kcal" ? 0 : 2);
  }

  const kcal = totals.kcal ?? 0;
  const kcalTheory =
    ((totals.protein_g ?? 0) * 4) +
    ((totals.carbs_g ?? 0) * 4) +
    ((totals.fat_g ?? 0) * 9);
  const kcalDeltaPct = kcal > 0 ? Math.abs(kcal - kcalTheory) / kcal : 0;

  const qualityScore = Math.max(
    0,
    Math.min(
      100,
      Math.round((coverage * 60) + (Math.min(1, convertibleCount / Math.max(1, ingredients.length)) * 25) +
        (Math.max(0, 1 - (kcalDeltaPct / Math.max(0.01, policy.quality_policy.kcalConsistencyWarnDeltaPct))) * 15)),
    ),
  );

  const qualityLevel = qualityScore >= 80 ? "A" : (qualityScore >= 60 ? "B" : "C");
  const warnings: string[] = [];
  if (!canShowPartial) warnings.push("Couverture insuffisante pour une valeur partielle fiable.");
  if (!canShowPer100g) warnings.push("Vue pour 100 g masquée: couverture poids insuffisante.");
  if (kcalDeltaPct > policy.quality_policy.kcalConsistencyWarnDeltaPct) {
    warnings.push("Incohérence énergétique détectée entre kcal et macronutriments.");
  }

  const snapshot = {
    selected_portions: selectedPortions,
    total_weight_g: roundValue(totalWeightGrams, 1),
    coverage,
    coverage_state: canShowPer100g ? "full" : (canShowPartial ? "partial" : "low"),
    totals,
    per_portion: perPortion,
    per_100g: canShowPer100g ? per100g : null,
    quality: {
      score: qualityScore,
      level: qualityLevel,
      warnings,
    },
    missing_ingredients: missingIngredients,
    policy_version: policy.version,
    computed_at: FieldValue.serverTimestamp(),
    fallback_policy: policy.fallback_policy,
  };

  await recipeRef.set(
    {
      nutrition: snapshot,
    },
    { merge: true },
  );

  return {
    recipeId: args.recipeId,
    nutrition: {
      ...snapshot,
      computed_at: new Date().toISOString(),
    },
  };
}
