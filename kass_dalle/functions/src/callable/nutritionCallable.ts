import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { REGION, COLL_APP_CONFIG, COLL_RECIPES } from "../config";
import { requireAdmin, requireAuth } from "./_auth";
import {
  DEFAULT_NUTRITION_POLICY,
  getNutritionSourcePolicy,
  NUTRITION_POLICY_DOC_ID,
  type NutritionSourcePolicy,
} from "../nutrition/policy";
import { normalizeNutrients } from "../nutrition/nutrients";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
};

interface SetNutritionPolicyRequest {
  policy?: Partial<NutritionSourcePolicy>;
}

interface NormalizeNutrientsRequest {
  nutrients?: Record<string, unknown>;
}

interface ComputeRecipeNutritionRequest {
  recipeId?: string;
  selectedPortions?: number;
}

interface IngredientInput {
  name?: unknown;
  qty?: unknown;
  unit?: unknown;
}

interface IngredientProfile {
  per100g?: Record<string, unknown>;
  source?: string;
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

const UNIT_TO_GRAMS: Record<string, number> = {
  g: 1,
  gram: 1,
  grams: 1,
  kg: 1000,
  mg: 0.001,
  ml: 1,
  cl: 10,
  dl: 100,
  l: 1000,
};

function normalizeName(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_|_$/g, "");
}

function asPositiveNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return value;
  if (typeof value === "string") {
    const trimmed = value.trim().replace(",", ".");
    const fraction = trimmed.match(/^(\d+)\s*\/\s*(\d+)$/);
    if (fraction) {
      const num = Number(fraction[1]);
      const den = Number(fraction[2]);
      if (Number.isFinite(num) && Number.isFinite(den) && den > 0) {
        return num / den;
      }
    }
    const parsed = Number(trimmed);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }
  return null;
}

function unitFactor(unit: unknown): number | null {
  if (typeof unit !== "string") return null;
  const key = normalizeName(unit);
  return UNIT_TO_GRAMS[key] ?? null;
}

function roundValue(value: number, digits = 2): number {
  const factor = Math.pow(10, digits);
  return Math.round(value * factor) / factor;
}

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

  const selectedPortions = asPositiveNumber(args.selectedPortions) ??
    asPositiveNumber(recipe.portions) ??
    1;

  const policy = await getNutritionSourcePolicy();

  const totals: Record<string, number> = {};
  const missingIngredients: string[] = [];
  let totalWeightGrams = 0;
  let convertibleCount = 0;
  let mappedCount = 0;

  for (const ingredient of ingredients) {
    const name = typeof ingredient.name === "string" ? ingredient.name.trim() : "";
    if (!name) continue;

    const qty = asPositiveNumber(ingredient.qty);
    const factor = unitFactor(ingredient.unit);
    if (qty == null || factor == null) {
      missingIngredients.push(name);
      continue;
    }

    convertibleCount++;
    const weightGrams = qty * factor;
    totalWeightGrams += weightGrams;

    const profileId = normalizeName(name);
    const profileSnap = await db.collection("nutrition_ingredients").doc(profileId).get();
    if (!profileSnap.exists) {
      missingIngredients.push(name);
      continue;
    }

    const profile = profileSnap.data() as IngredientProfile;
    const normalized = normalizeNutrients(profile.per100g ?? {});
    if (Object.keys(normalized).length === 0) {
      missingIngredients.push(name);
      continue;
    }

    mappedCount++;
    for (const key of NUTRIENT_KEYS) {
      const per100 = normalized[key] ?? 0;
      if (!Number.isFinite(per100) || per100 <= 0) continue;
      totals[key] = (totals[key] ?? 0) + (weightGrams * per100) / 100;
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

export const getNutritionSourcePolicyFn = onCall(callableOpts, async (req) => {
  requireAuth(req);
  const policy = await getNutritionSourcePolicy();
  return { policy };
});

export const setNutritionSourcePolicyFn = onCall<SetNutritionPolicyRequest>(
  callableOpts,
  async (req) => {
    await requireAdmin(req);

    const next = req.data?.policy;
    if (!next) {
      throw new HttpsError("invalid-argument", "policy est requis.");
    }

    const merged: NutritionSourcePolicy = {
      ...DEFAULT_NUTRITION_POLICY,
      ...next,
      source_priority: next.source_priority ?? DEFAULT_NUTRITION_POLICY.source_priority,
      nutrient_aliases: next.nutrient_aliases ?? DEFAULT_NUTRITION_POLICY.nutrient_aliases,
      quality_policy: {
        ...DEFAULT_NUTRITION_POLICY.quality_policy,
        ...(next.quality_policy ?? {}),
      },
      version: typeof next.version === "number" ? next.version : Date.now(),
    };

    await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(NUTRITION_POLICY_DOC_ID)
      .set({
        ...merged,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });

    return { policy: merged };
  },
);

export const normalizeNutrientsFn = onCall<NormalizeNutrientsRequest>(
  callableOpts,
  async (req) => {
    requireAuth(req);
    const nutrients = req.data?.nutrients;
    if (!nutrients || typeof nutrients !== "object") {
      throw new HttpsError("invalid-argument", "nutrients est requis.");
    }

    const normalized = normalizeNutrients(nutrients);
    return { normalized };
  },
);

export const computeRecipeNutritionFn = onCall<ComputeRecipeNutritionRequest>(
  { ...callableOpts, timeoutSeconds: 90 },
  async (req) => {
    requireAuth(req);
    const recipeId = req.data?.recipeId;
    if (!recipeId || typeof recipeId !== "string") {
      throw new HttpsError("invalid-argument", "recipeId est requis.");
    }
    return computeAndPersistRecipeNutrition({
      recipeId,
      selectedPortions: req.data?.selectedPortions,
    });
  },
);
