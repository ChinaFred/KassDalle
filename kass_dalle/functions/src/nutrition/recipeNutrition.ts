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
import { detectDuplicateIngredientsWithAI } from "./aiEnrichment";
import {
  normalizeObservedUnit,
  resolveUnitFactorToGrams,
  type IngredientWeightOverride,
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
  /**
   * Autorise la passe IA qui repère les lignes reprenant un ingrédient déjà
   * listé. Sans elle, le calcul se fait sans cette détection plutôt que
   * d'échouer : c'est un raffinement, pas une condition.
   *
   * Ce drapeau s'appelait `geminiApiKey` et se testait par sa seule présence.
   * Une clé d'API qui sert d'interrupteur, c'est un interrupteur qu'on ne
   * trouve pas — et un nom qui ment depuis que le poste peut être servi par
   * Claude.
   */
  aiEnabled?: boolean;
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
      selected_portions:
        asPositiveNumber(args.selectedPortions) ?? asPositiveNumber(recipe.portions) ?? 1,
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
      not_consumed_ingredients: [],
      duplicate_ingredients: [],
      duplicate_indices: [],
      duplicate_signature: "",
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

  const selectedPortions =
    asPositiveNumber(args.selectedPortions) ?? asPositiveNumber(recipe.portions) ?? 1;

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
          gramsPerUnit: typeof data.grams_per_unit === "number" ? data.grams_per_unit : undefined,
          volumeMlPerUnit:
            typeof data.volume_ml_per_unit === "number" ? data.volume_ml_per_unit : undefined,
        });
      }
    }
  }

  // Pré-charge les poids enregistrés sur les ingrédients eux-mêmes.
  //
  // Un œuf, un jaune, une gousse de vanille SONT des unités en eux-mêmes : leur
  // poids appartient à l'ingrédient, pas à l'unité. Il en va de même d'une
  // branche de thym face à une branche de céleri — d'où `grams_per_unit`,
  // indexé par unité. Le référentiel prime sur la table intégrée : corriger un
  // poids ne demande donc pas de redéploiement.
  const weightPerIngredient = new Map<string, IngredientWeightOverride>();
  /** Ingrédients présents dans la recette mais absents du repas. */
  const notConsumedIds = new Set<string>();
  {
    const lookupIds = new Set<string>();
    for (const ingredient of ingredients) {
      const name = typeof ingredient.name === "string" ? ingredient.name.trim() : "";
      if (!name) continue;
      for (const id of buildIngredientLookupIds(name)) lookupIds.add(id);
    }
    if (lookupIds.size > 0) {
      const refs = [...lookupIds].map((id) => db.collection("nutrition_ingredients").doc(id));
      for (let i = 0; i < refs.length; i += 300) {
        const snaps = await db.getAll(...refs.slice(i, i + 300));
        for (const snap of snaps) {
          if (!snap.exists) continue;
          const data = snap.data() as Record<string, unknown>;
          if (data.not_consumed === true) notConsumedIds.add(snap.id);
          const grams = data.grams_per_piece;
          const perUnitRaw = data.grams_per_unit;
          const perUnit: Record<string, number> = {};
          if (perUnitRaw && typeof perUnitRaw === "object") {
            for (const [unit, value] of Object.entries(perUnitRaw as Record<string, unknown>)) {
              if (typeof value === "number" && Number.isFinite(value) && value > 0) {
                perUnit[unit] = value;
              }
            }
          }
          const hasPiece = typeof grams === "number" && grams > 0;
          if (!hasPiece && Object.keys(perUnit).length === 0) continue;
          weightPerIngredient.set(snap.id, {
            ...(hasPiece ? { gramsPerPiece: grams as number } : {}),
            ...(Object.keys(perUnit).length > 0 ? { gramsPerUnit: perUnit } : {}),
          });
        }
      }
    }
  }

  /** Poids connus du référentiel pour cet ingrédient, s'il en porte. */
  function referentialWeights(name: string): IngredientWeightOverride | null {
    for (const id of buildIngredientLookupIds(name)) {
      const weights = weightPerIngredient.get(id);
      if (weights) return weights;
    }
    return null;
  }

  /** L'ingrédient finit-il dans l'assiette ? */
  function isNotConsumed(name: string): boolean {
    return buildIngredientLookupIds(name).some((id) => notConsumedIds.has(id));
  }

  // ── Lignes qui reprennent un ingrédient déjà listé ─────────────────────────
  //
  // Une recette qui achète 1,5 kg de côte et en dresse « 4 tranches de viande »
  // décrit le même aliment deux fois ; additionner double les apports du plat.
  //
  // La détection coûte un appel d'IA, mais la liste d'ingrédients ne change pas
  // à chaque recalcul : le verdict est conservé dans le snapshot avec la
  // signature de la liste qui l'a produit, et n'est redemandé que si cette
  // liste change réellement.
  const duplicateSignature = ingredients
    .map((i) => {
      const name = typeof i.name === "string" ? i.name.trim().toLowerCase() : "";
      const qty = typeof i.qty === "string" ? i.qty.trim() : String(i.qty ?? "");
      const unit = typeof i.unit === "string" ? i.unit.trim().toLowerCase() : "";
      return `${name}|${qty}|${unit}`;
    })
    .join("~");

  const previousNutrition = (recipe.nutrition ?? {}) as Record<string, unknown>;
  let duplicateIndices: number[] = [];

  if (previousNutrition.duplicate_signature === duplicateSignature) {
    const stored = previousNutrition.duplicate_indices;
    if (Array.isArray(stored)) {
      duplicateIndices = stored.filter(
        (value): value is number =>
          typeof value === "number" &&
          Number.isInteger(value) &&
          value >= 0 &&
          value < ingredients.length,
      );
    }
  } else if (args.aiEnabled) {
    duplicateIndices = await detectDuplicateIngredientsWithAI({
      ingredients: ingredients.map((i) => ({
        name: typeof i.name === "string" ? i.name.trim() : "",
        qty: typeof i.qty === "string" ? i.qty.trim() : String(i.qty ?? ""),
        unit: typeof i.unit === "string" ? i.unit.trim() : "",
      })),
      recipeId: args.recipeId,
    });
  }

  const duplicateIndexSet = new Set(duplicateIndices);

  const resolutions: IngredientResolution[] = [];
  const uniqueLookupIds = new Set<string>();
  const notConsumedIngredients: string[] = [];
  const duplicateIngredients: string[] = [];

  for (const [index, ingredient] of ingredients.entries()) {
    const name = typeof ingredient.name === "string" ? ingredient.name.trim() : "";
    if (!name) continue;

    // Une reprise sort du calcul et de son dénominateur, comme un ingrédient
    // non consommé : ce n'est pas une donnée manquante, c'est la même donnée
    // déjà comptée une ligne plus haut.
    if (duplicateIndexSet.has(index)) {
      duplicateIngredients.push(name);
      continue;
    }

    // Un bain de friture, un foin de fumage ou une marinade jetée appartiennent
    // à la recette, pas au repas. Ils sortent du calcul ET de son dénominateur :
    // les compter comme manquants ferait chuter une couverture qui, elle, est
    // complète — la recette n'a rien à apprendre de plus sur eux.
    if (isNotConsumed(name)) {
      notConsumedIngredients.push(name);
      continue;
    }

    const qty = asPositiveNumber(ingredient.qty);
    const unitStr = typeof ingredient.unit === "string" ? ingredient.unit.trim() : "";
    const normalizedUnit = unitStr ? normalizeObservedUnit(unitStr) : "";

    // L'arbitrage complet — poids du couple, puis poids à la pièce, puis
    // référentiel d'unités, puis table intégrée — vit dans une seule fonction,
    // partagée avec le client et asservie par `unit_to_grams.json`.
    const factor = resolveUnitFactorToGrams(
      unitStr,
      name,
      normalizedUnit ? (referentialUnits.get(normalizedUnit) ?? null) : null,
      referentialWeights(name),
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
  const docsToFetch = [...uniqueLookupIds].map((id) =>
    db.collection("nutrition_ingredients").doc(id),
  );

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

  // Le dénominateur ne compte que ce qui est mangé : sinon un bain de friture,
  // volontairement exclu, ferait passer une recette complète pour incomplète.
  const countedIngredients = Math.max(
    0,
    ingredients.length - notConsumedIngredients.length - duplicateIngredients.length,
  );
  const coverage = countedIngredients > 0 ? mappedCount / countedIngredients : 0;
  const canShowPer100g =
    coverage >= policy.quality_policy.minCoverageForPer100g && totalWeightGrams > 0;
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
    (totals.protein_g ?? 0) * 4 + (totals.carbs_g ?? 0) * 4 + (totals.fat_g ?? 0) * 9;
  const kcalDeltaPct = kcal > 0 ? Math.abs(kcal - kcalTheory) / kcal : 0;

  const qualityScore = Math.max(
    0,
    Math.min(
      100,
      Math.round(
        coverage * 60 +
          Math.min(1, convertibleCount / Math.max(1, countedIngredients)) * 25 +
          Math.max(
            0,
            1 - kcalDeltaPct / Math.max(0.01, policy.quality_policy.kcalConsistencyWarnDeltaPct),
          ) *
            15,
      ),
    ),
  );

  const qualityLevel = qualityScore >= 80 ? "A" : qualityScore >= 60 ? "B" : "C";
  const warnings: string[] = [];
  // Messages destinés à l'utilisateur : ils doivent dire ce qui manque et
  // pourquoi, pas seulement constater un seuil.
  if (!canShowPartial) {
    warnings.push(
      "Trop peu d'ingrédients ont un poids connu pour que le calcul soit représentatif.",
    );
  }
  if (!canShowPer100g) {
    warnings.push(
      "Valeurs pour 100 g masquées : le poids total de la recette n'est pas assez " +
        "complet pour les ramener à 100 g sans fausser le résultat. " +
        "Renseignez les ingrédients sans poids pour les afficher.",
    );
  }
  if (kcalDeltaPct > policy.quality_policy.kcalConsistencyWarnDeltaPct) {
    warnings.push(
      "Les calories annoncées et celles recalculées depuis les macronutriments " +
        "diffèrent sensiblement : une valeur du référentiel est probablement inexacte.",
    );
  }

  const snapshot = {
    selected_portions: selectedPortions,
    total_weight_g: roundValue(totalWeightGrams, 1),
    coverage,
    coverage_state: canShowPer100g ? "full" : canShowPartial ? "partial" : "low",
    totals,
    per_portion: perPortion,
    per_100g: canShowPer100g ? per100g : null,
    quality: {
      score: qualityScore,
      level: qualityLevel,
      warnings,
    },
    missing_ingredients: missingIngredients,
    not_consumed_ingredients: notConsumedIngredients,
    duplicate_ingredients: duplicateIngredients,
    // Indices et signature : le verdict se réutilise tant que la liste
    // d'ingrédients n'a pas bougé, et se redemande dès qu'elle change.
    duplicate_indices: duplicateIndices,
    duplicate_signature: duplicateSignature,
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
