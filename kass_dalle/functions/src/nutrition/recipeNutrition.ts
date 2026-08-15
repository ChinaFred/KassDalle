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
  DEFAULT_FRY_OIL_NAME,
  DEFAULT_FRY_OIL_PER100G,
  computeAbsorbedOilGrams,
  estimateFryAbsorptionWithAI,
  fryingSignature,
  looksFried,
  NO_FRY_ABSORPTION,
  type FryAbsorptionVerdict,
} from "./fryAbsorption";
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
  /** Rang dans la liste d'ingrédients de la recette, tel que l'IA le désigne. */
  index: number;
  name: string;
  weightGrams: number;
  lookupIds: string[];
}

/**
 * Un ingrédient écarté du repas, gardé de côté avec son poids.
 *
 * Le bain de friture sort du total, mais il reste la seule source qui dise
 * quelle huile est employée et combien il y en a : son profil sert à valoriser
 * l'huile absorbée, et sa quantité à la plafonner.
 */
interface ExcludedIngredient {
  name: string;
  weightGrams: number | null;
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
  /**
   * Ignoré — conservé pour ne pas casser les appels en vol.
   *
   * Le calcul est désormais fait **aux portions déclarées de la recette**, et
   * jamais à celles qu'un lecteur a choisies : le bloc `nutrition` vit sur un
   * document partagé, et l'y écrire au nombre de parts d'un utilisateur faisait
   * que chaque membre de la famille écrasait l'affichage des autres, sans
   * qu'aucune erreur ne soit levée.
   *
   * Rien n'est perdu : seul `per_portion` dépendait de ce nombre, et il vaut
   * `totals / N` — une division que chaque écran fait pour le N qui le
   * concerne. Voir `RecipeNutritionSnapshot.perPortionFor` côté client.
   */
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
      selected_portions: asPositiveNumber(recipe.portions) ?? 1,
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
      absorbed_oil: null,
      fry_verdict: null,
      fry_signature: "",
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

  // Portions de référence : celles de la recette, jamais celles d'un lecteur.
  // Le bloc écrit ici est partagé par toute la famille.
  const selectedPortions = asPositiveNumber(recipe.portions) ?? 1;

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
  const excludedIngredients: ExcludedIngredient[] = [];
  const duplicateIngredients: string[] = [];

  /**
   * Poids en grammes d'une ligne d'ingrédient, ou `null` si elle ne se convertit
   * pas.
   *
   * L'arbitrage complet — poids du couple, puis poids à la pièce, puis
   * référentiel d'unités, puis table intégrée — vit dans une seule fonction,
   * partagée avec le client et asservie par `unit_to_grams.json`.
   */
  function weightOf(ingredient: IngredientInput, name: string): number | null {
    const qty = asPositiveNumber(ingredient.qty);
    const unitStr = typeof ingredient.unit === "string" ? ingredient.unit.trim() : "";
    const normalizedUnit = unitStr ? normalizeObservedUnit(unitStr) : "";
    const factor = resolveUnitFactorToGrams(
      unitStr,
      name,
      normalizedUnit ? (referentialUnits.get(normalizedUnit) ?? null) : null,
      referentialWeights(name),
    );
    if (qty == null || factor == null) return null;
    return qty * factor;
  }

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
      // Écarté du repas, mais pas oublié : c'est parmi ces lignes que se trouve
      // le bain de friture, dont l'huile absorbée emprunte le profil et la
      // quantité. Charger son profil ne coûte rien — la lecture est groupée —
      // et il ne rejoint jamais `resolutions`, donc jamais le total.
      const excludedLookupIds = buildIngredientLookupIds(name);
      for (const lookupId of excludedLookupIds) {
        uniqueLookupIds.add(lookupId);
      }
      excludedIngredients.push({
        name,
        weightGrams: weightOf(ingredient, name),
        lookupIds: excludedLookupIds,
      });
      continue;
    }

    const weightGrams = weightOf(ingredient, name);
    if (weightGrams == null) {
      missingIngredients.push(name);
      continue;
    }

    convertibleCount++;
    totalWeightGrams += weightGrams;

    const lookupIds = buildIngredientLookupIds(name);
    if (lookupIds.length === 0) {
      missingIngredients.push(name);
      continue;
    }

    for (const lookupId of lookupIds) {
      uniqueLookupIds.add(lookupId);
    }
    resolutions.push({ index, name, weightGrams, lookupIds });
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

  // ── Huile absorbée à la friture ────────────────────────────────────────────
  //
  // Le bain sort du total, et c'est juste : on ne mange pas un litre d'huile.
  // Mais ce qu'on y plonge en ressort plus gras — un poulet pané absorbe le
  // dixième de son poids. Sans cette ligne, la recette affiche « couverture
  // complète » en mentant de 40 % sur ses lipides.
  //
  // Le taux appartient à l'aliment frit, pas au bain : la quantité d'huile
  // écrite dans la recette est arbitraire. Le bain déclaré ne sert que de
  // plafond — on n'absorbe pas plus d'huile qu'il n'y en a — et de source de
  // profil, puisque c'est lui qui dit quelle huile est employée.
  //
  // Le verdict coûte un appel d'IA. Comme celui des doublons, il est conservé
  // avec la signature qui l'a produit, et n'est redemandé que si la liste
  // d'ingrédients ou le texte de la recette changent réellement. Il est stocké
  // séparément de son résultat : un poids d'ingrédient qui devient connu entre
  // deux calculs doit produire de l'huile sans redemander le verdict.
  const rawCooklang = typeof recipe.raw_cooklang === "string" ? recipe.raw_cooklang : "";
  const frySignature = fryingSignature({ ingredientsKey: duplicateSignature, rawCooklang });

  let fryVerdict: FryAbsorptionVerdict = NO_FRY_ABSORPTION;
  if (previousNutrition.fry_signature === frySignature) {
    const stored = previousNutrition.fry_verdict;
    if (stored && typeof stored === "object") {
      const record = stored as Record<string, unknown>;
      const ratio = record.absorption_ratio;
      fryVerdict = {
        friedIndices: (Array.isArray(record.fried_indices) ? record.fried_indices : []).filter(
          (value): value is number =>
            typeof value === "number" &&
            Number.isInteger(value) &&
            value >= 0 &&
            value < ingredients.length,
        ),
        absorptionRatio: typeof ratio === "number" && Number.isFinite(ratio) ? ratio : 0,
      };
    }
  } else if (
    args.aiEnabled &&
    // Portier gratuit : sans un signe de friture dans le texte ou les
    // ingrédients, aucune recette ne paie l'appel.
    looksFried({
      rawCooklang,
      ingredientNames: ingredients.map((i) => (typeof i.name === "string" ? i.name : "")),
    })
  ) {
    fryVerdict = await estimateFryAbsorptionWithAI({
      ingredients: ingredients.map((i) => ({
        name: typeof i.name === "string" ? i.name.trim() : "",
        qty: typeof i.qty === "string" ? i.qty.trim() : String(i.qty ?? ""),
        unit: typeof i.unit === "string" ? i.unit.trim() : "",
      })),
      rawCooklang,
      recipeId: args.recipeId,
    });
  }

  let absorbedOil: Record<string, unknown> | null = null;
  if (fryVerdict.absorptionRatio > 0 && fryVerdict.friedIndices.length > 0) {
    const friedIndexSet = new Set(fryVerdict.friedIndices);
    const friedWeightGrams = resolutions
      .filter((resolution) => friedIndexSet.has(resolution.index))
      .reduce((acc, resolution) => acc + resolution.weightGrams, 0);

    // Quelle huile, et combien y en a-t-il ? La recette le dit dans ses lignes
    // écartées. À défaut, l'huile végétale de repli : approcher vaut mieux que
    // taire, et la ligne s'annonce comme estimée.
    let oilName = DEFAULT_FRY_OIL_NAME;
    let oilProfile = DEFAULT_FRY_OIL_PER100G;
    let declaredOilGrams: number | null = null;
    let bestFat = 0;
    for (const excluded of excludedIngredients) {
      let profile: Record<string, number> | null = null;
      for (const lookupId of excluded.lookupIds) {
        const candidate = normalizedProfilesById.get(lookupId);
        if (!candidate) continue;
        profile = candidate;
        break;
      }
      // Sous la moitié de lipides, ce n'est pas un corps gras : un lit de gros
      // sel ou une marinade jetée n'apprend rien sur l'huile du bain.
      const fat = profile?.fat_g ?? 0;
      if (!profile || fat < 50 || fat <= bestFat) continue;
      bestFat = fat;
      oilProfile = profile;
      oilName = excluded.name;
      declaredOilGrams = excluded.weightGrams;
    }

    const { grams, capped } = computeAbsorbedOilGrams({
      friedWeightGrams,
      absorptionRatio: fryVerdict.absorptionRatio,
      declaredOilGrams,
    });

    if (grams > 0) {
      // L'huile absorbée est mangée : elle pèse dans l'assiette, donc dans le
      // dénominateur des valeurs pour 100 g.
      totalWeightGrams += grams;
      const contribution: Record<string, number> = {};
      for (const key of NUTRIENT_KEYS) {
        const per100 = oilProfile[key] ?? 0;
        if (!Number.isFinite(per100) || per100 <= 0) continue;
        const value = (grams * per100) / 100;
        totals[key] = (totals[key] ?? 0) + value;
        contribution[key] = roundValue(value, key === "kcal" ? 0 : 2);
      }

      absorbedOil = {
        grams,
        absorption_ratio: fryVerdict.absorptionRatio,
        fried_weight_g: roundValue(friedWeightGrams, 1),
        source_name: oilName,
        // Le bain déclaré était plus maigre que l'absorption estimée : on s'en
        // tient à ce que la recette met dans la poêle.
        capped,
        per_ingredient: contribution,
      };
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
    // Ligne dérivée : ni un ingrédient ni une donnée manquante, mais de la
    // matière grasse réellement mangée. Le verdict qui l'a produite est gardé à
    // part, pour survivre à un calcul où aucun ingrédient frit n'avait de poids.
    absorbed_oil: absorbedOil,
    fry_verdict:
      fryVerdict.friedIndices.length > 0
        ? {
            fried_indices: fryVerdict.friedIndices,
            absorption_ratio: fryVerdict.absorptionRatio,
          }
        : null,
    fry_signature: frySignature,
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
