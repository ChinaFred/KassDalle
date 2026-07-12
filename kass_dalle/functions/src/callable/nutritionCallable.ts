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
import { buildIngredientLookupIds, normalizeIngredientStrictId } from "../nutrition/ingredientName";
import { canonicalizeNormalizedUnit, unitFactorToGrams } from "../nutrition/quantityConversion";
import { normalizeIngredientCanonicalId } from "../nutrition/ingredientName";
import { resolveIngredientUnitFields } from "../nutrition/ingredientUnitResolution";
import { upsertNutritionUnitReference } from "../nutrition/unitReference";
import { extractIngredientsStructured } from "../cooklang/parser";
import { logError } from "../logging";

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

interface NormalizeRecipeReferentialsRequest {
  recipeId?: string;
  cooklang?: string;
  ingredients?: Array<Record<string, unknown>>;
}

export interface NormalizeRecipeReferentialsResult {
  rewrittenCooklang: string;
  resolvedIngredients: Array<Record<string, unknown>>;
  stats: {
    totalIngredients: number;
    unitsResolved: number;
    ingredientsKnown: number;
    ingredientsProposed: number;
    renamedUnits: number;
    renamedIngredients: number;
  };
}

interface NormalizedRecipeIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string;
  unit_raw: string;
  unit_canonical: string;
  unit_resolution_source: string;
  unit_resolution_confidence: number;
  ingredient_ref_id: string;
  ingredient_ref_status: "known" | "proposed";
  ingredient_canonical_name: string;
  ingredient_resolution_source: "referential" | "fallback";
  ingredient_resolution_confidence: number;
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
  const key = normalizeIngredientStrictId(unit);
  return key ? unitFactorToGrams(canonicalizeNormalizedUnit(key)) : null;
}

function roundValue(value: number, digits = 2): number {
  const factor = Math.pow(10, digits);
  return Math.round(value * factor) / factor;
}

const UNIT_LABEL_BY_CANONICAL: Record<string, string> = {
  c_a_c: "c.à.c.",
  c_a_s: "c.à.s.",
  c_a_d: "c.à.d.",
  piece: "pièce",
  pincee: "pincée",
  l: "L",
};

function fallbackUnitLabel(normalizedUnit: string): string {
  if (!normalizedUnit) return "";
  return UNIT_LABEL_BY_CANONICAL[normalizedUnit] ?? normalizedUnit.replace(/_/g, " ");
}

function parseQtyAndUnit(raw: string): { qty: string; unit: string } {
  const parts = raw.split("%");
  const qty = parts.length > 0 ? parts[0].trim() : "";
  const unit = parts.length > 1 ? parts.slice(1).join("%").trim() : "";
  return { qty, unit };
}

function formatQtyAndUnit(qty: string, unit: string): string {
  if (!qty && !unit) return "";
  if (!unit) return qty;
  return `${qty}%${unit}`;
}

async function ensureIngredientReference(args: {
  ingredientRawName: string;
  recipeId?: string;
}): Promise<{ ingredientRefId: string; canonicalName: string; status: "known" | "proposed" }> {
  const db = getFirestore();
  const ingredientRefId = normalizeIngredientCanonicalId(args.ingredientRawName);
  if (!ingredientRefId) {
    return {
      ingredientRefId: "",
      canonicalName: args.ingredientRawName.trim(),
      status: "proposed",
    };
  }

  const docRef = db.collection("nutrition_ingredients").doc(ingredientRefId);
  const snap = await docRef.get();
  if (snap.exists) {
    const data = snap.data() as Record<string, unknown>;
    const canonicalName = typeof data.canonical_name === "string" && data.canonical_name.trim().length > 0
      ? data.canonical_name.trim()
      : ingredientRefId.replace(/_/g, " ");
    return {
      ingredientRefId,
      canonicalName,
      status: "known",
    };
  }

  await docRef.set({
    canonical_name: ingredientRefId.replace(/_/g, " "),
    aliases: FieldValue.arrayUnion(args.ingredientRawName.trim()),
    per100g: {},
    source: "recipe_referential_resolution",
    quality_status: "pending",
    status: "proposed",
    seen_count: 1,
    first_seen_at: FieldValue.serverTimestamp(),
    last_seen_at: FieldValue.serverTimestamp(),
    ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  }, { merge: true });

  return {
    ingredientRefId,
    canonicalName: ingredientRefId.replace(/_/g, " "),
    status: "proposed",
  };
}

async function resolveUnitDisplay(args: {
  ingredientName: string;
  unitRaw: string;
  recipeId?: string;
}): Promise<{
  displayUnit: string;
  unitCanonical: string;
  unitRaw: string;
  unitResolutionSource: string;
  unitResolutionConfidence: number;
}> {
  const db = getFirestore();
  const resolved = resolveIngredientUnitFields({
    name: args.ingredientName,
    qty: "",
    unit: args.unitRaw,
  });

  let canonical = resolved.unit_canonical;
  if (!canonical && args.unitRaw.trim().length > 0) {
    const upserted = await upsertNutritionUnitReference({
      db,
      unitRaw: args.unitRaw,
      ingredientName: args.ingredientName,
      recipeId: args.recipeId,
    });
    canonical = upserted.normalizedUnit ?? "";
  }

  if (!canonical) {
    return {
      displayUnit: args.unitRaw.trim(),
      unitCanonical: "",
      unitRaw: args.unitRaw.trim(),
      unitResolutionSource: resolved.unit_resolution_source,
      unitResolutionConfidence: resolved.unit_resolution_confidence,
    };
  }

  const unitRef = await db.collection("nutrition_units").doc(canonical).get();
  if (!unitRef.exists) {
    await upsertNutritionUnitReference({
      db,
      unitRaw: args.unitRaw || canonical,
      ingredientName: args.ingredientName,
      recipeId: args.recipeId,
    });
  }

  const unitData = unitRef.data() as Record<string, unknown> | undefined;
  const fromDisplayLabel = typeof unitData?.display_label === "string"
    ? unitData.display_label.trim()
    : "";
  const fromLabel = typeof unitData?.label === "string"
    ? unitData.label.trim()
    : "";
  const aliases = Array.isArray(unitData?.aliases)
    ? unitData?.aliases.filter((v): v is string => typeof v === "string" && v.trim().length > 0)
    : [];

  const displayUnit =
    fromDisplayLabel ||
    fromLabel ||
    (aliases.length > 0 ? aliases[0].trim() : "") ||
    fallbackUnitLabel(canonical);

  return {
    displayUnit,
    unitCanonical: canonical,
    unitRaw: resolved.unit_raw,
    unitResolutionSource: resolved.unit_resolution_source,
    unitResolutionConfidence: resolved.unit_resolution_confidence,
  };
}

async function resolveOneIngredient(args: {
  item: Record<string, unknown>;
  recipeId?: string;
}): Promise<NormalizedRecipeIngredient | null> {
  const rawName = typeof args.item.name === "string" ? args.item.name.trim() : "";
  if (!rawName) return null;
  const qty = typeof args.item.qty === "string" ? args.item.qty.trim() : "";
  const rawUnit = typeof args.item.unit === "string" ? args.item.unit.trim() : "";
  const category = typeof args.item.category === "string" ? args.item.category.trim() : "";

  const ingredientRef = await ensureIngredientReference({
    ingredientRawName: rawName,
    recipeId: args.recipeId,
  });
  const unit = await resolveUnitDisplay({
    ingredientName: ingredientRef.canonicalName,
    unitRaw: rawUnit,
    recipeId: args.recipeId,
  });

  return {
    name: ingredientRef.canonicalName,
    qty,
    unit: unit.displayUnit,
    ...(category ? { category } : {}),
    unit_raw: unit.unitRaw,
    unit_canonical: unit.unitCanonical,
    unit_resolution_source: unit.unitResolutionSource,
    unit_resolution_confidence: unit.unitResolutionConfidence,
    ingredient_ref_id: ingredientRef.ingredientRefId,
    ingredient_ref_status: ingredientRef.status,
    ingredient_canonical_name: ingredientRef.canonicalName,
    ingredient_resolution_source: ingredientRef.status === "known" ? "referential" : "fallback",
    ingredient_resolution_confidence: ingredientRef.status === "known" ? 1 : 0.6,
  };
}

async function rewriteCooklangWithReferentials(args: {
  cooklang: string;
  recipeId?: string;
}): Promise<string> {
  const re = /@([^{@#~\n]+)\{([^}]*)\}/g;
  const matches = [...args.cooklang.matchAll(re)];
  if (matches.length === 0) return args.cooklang;

  let out = "";
  let cursor = 0;
  for (const m of matches) {
    const tokenStart = m.index ?? 0;
    const tokenEnd = tokenStart + m[0].length;
    out += args.cooklang.slice(cursor, tokenStart);

    const rawName = m[1].trim();
    const parsed = parseQtyAndUnit(m[2] ?? "");
    const resolved = await resolveOneIngredient({
      item: {
        name: rawName,
        qty: parsed.qty,
        unit: parsed.unit,
      },
      recipeId: args.recipeId,
    });

    if (resolved == null) {
      out += m[0];
    } else {
      out += `@${resolved.name}{${formatQtyAndUnit(resolved.qty, resolved.unit)}}`;
    }
    cursor = tokenEnd;
  }
  out += args.cooklang.slice(cursor);
  return out;
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

  const resolutions: IngredientResolution[] = [];
  const uniqueLookupIds = new Set<string>();

  for (const ingredient of ingredients) {
    const name = typeof ingredient.name === "string" ? ingredient.name.trim() : "";
    if (!name) continue;

    const qty = asPositiveNumber(ingredient.qty);
    const factor = unitFactorToGrams(
      typeof ingredient.unit === "string" ? ingredient.unit : "",
      name,
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
    try {
      return await computeAndPersistRecipeNutrition({
        recipeId,
        selectedPortions: req.data?.selectedPortions,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await logError({
        message: "computeRecipeNutritionFn: ERREUR",
        errorDescription: message,
        correlationId: `compute-nutrition-${Date.now()}`,
        extra: {
          recipeId,
          uid: req.auth?.uid ?? null,
          selectedPortions: req.data?.selectedPortions ?? null,
        },
      });
      throw err;
    }
  },
);

export const normalizeRecipeReferentialsFn = onCall<NormalizeRecipeReferentialsRequest>(
  { ...callableOpts, timeoutSeconds: 90 },
  async (req) => {
    requireAuth(req);

    return normalizeRecipeReferentialsCore({
      recipeId: typeof req.data?.recipeId === "string" ? req.data.recipeId : undefined,
      cooklang: typeof req.data?.cooklang === "string" ? req.data.cooklang : "",
      ingredients: Array.isArray(req.data?.ingredients)
        ? req.data?.ingredients
        : undefined,
    });
  },
);

export async function normalizeRecipeReferentialsCore(args: {
  recipeId?: string;
  cooklang: string;
  ingredients?: Array<Record<string, unknown>>;
}): Promise<NormalizeRecipeReferentialsResult> {
  const cooklang = args.cooklang;
  const recipeId = args.recipeId;
  const ingredientsInput = Array.isArray(args.ingredients)
    ? args.ingredients
    : extractIngredientsStructured(cooklang).map((i) => ({
      name: i.name,
      qty: i.qty,
      unit: i.unit,
      ...(i.category ? { category: i.category } : {}),
    }));

  const resolvedIngredients: NormalizedRecipeIngredient[] = [];
  for (const item of ingredientsInput) {
    if (!item || typeof item !== "object") continue;
    const resolved = await resolveOneIngredient({
      item: item as Record<string, unknown>,
      recipeId,
    });
    if (resolved != null) resolvedIngredients.push(resolved);
  }

  const rewrittenCooklang = cooklang
    ? await rewriteCooklangWithReferentials({ cooklang, recipeId })
    : "";

  const originalItems = ingredientsInput
    .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    .map((item) => ({
      name: typeof item.name === "string" ? item.name.trim() : "",
      unit: typeof item.unit === "string" ? item.unit.trim() : "",
    }));

  const comparedCount = Math.min(originalItems.length, resolvedIngredients.length);
  let renamedUnits = 0;
  let renamedIngredients = 0;
  for (let i = 0; i < comparedCount; i++) {
    if (
      originalItems[i].unit.length > 0 &&
      resolvedIngredients[i].unit.length > 0 &&
      originalItems[i].unit.toLowerCase() !== resolvedIngredients[i].unit.toLowerCase()
    ) {
      renamedUnits++;
    }
    if (
      originalItems[i].name.length > 0 &&
      resolvedIngredients[i].name.length > 0 &&
      originalItems[i].name.toLowerCase() !== resolvedIngredients[i].name.toLowerCase()
    ) {
      renamedIngredients++;
    }
  }

  return {
    rewrittenCooklang,
    resolvedIngredients: resolvedIngredients.map((i) => ({ ...i })),
    stats: {
      totalIngredients: resolvedIngredients.length,
      unitsResolved: resolvedIngredients.filter((i) => i.unit_canonical.length > 0).length,
      ingredientsKnown: resolvedIngredients.filter((i) => i.ingredient_ref_status === "known").length,
      ingredientsProposed: resolvedIngredients.filter((i) => i.ingredient_ref_status === "proposed").length,
      renamedUnits,
      renamedIngredients,
    },
  };
}
