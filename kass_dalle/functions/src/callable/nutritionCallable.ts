/**
 * Points d'entrée HTTPS de la chaîne nutrition.
 *
 * Ce fichier ne contient que des callables : vérification des droits, lecture
 * des arguments, appel d'un service de , mise en forme de la
 * réponse. Toute la logique métier vit dans :
 *   - nutrition/unitDisplay.ts              présentation des quantités et unités
 *   - nutrition/aiEnrichment.ts             appels Gemini et leurs prompts
 *   - nutrition/referentialNormalization.ts résolution contre les référentiels
 *   - nutrition/recipeNutrition.ts          calcul et persistance
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";

import { REGION, COLL_APP_CONFIG, GEMINI_API_KEY, ANTHROPIC_API_KEY } from "../config";
import { requireAdmin, requireAuth } from "./_auth";
import {
  DEFAULT_NUTRITION_POLICY,
  getNutritionSourcePolicy,
  NUTRITION_POLICY_DOC_ID,
  type NutritionSourcePolicy,
} from "../nutrition/policy";
import { normalizeNutrients } from "../nutrition/nutrients";
import { computeAndPersistRecipeNutrition } from "../nutrition/recipeNutrition";
import { normalizeRecipeReferentialsCore } from "../nutrition/referentialNormalization";
import {
  cleanupIngredientReferential,
  seedIngredientPieceWeights,
} from "../nutrition/referentialCleanup";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
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

export const getNutritionSourcePolicyFn = onCall(callableOpts, async (req) => {
  requireAuth(req);
  const policy = await getNutritionSourcePolicy();
  return { policy };
});

/**
 * Vérifie qu'un seuil est un nombre dans ses bornes, et refuse sinon.
 *
 * Ces seuils gouvernent ce que l'utilisateur voit : au-delà de
 * `minCoverageForPer100g`, les valeurs pour 100 g sont masquées, et
 * `kcalConsistencyWarnDeltaPct` entre au dénominateur du score de qualité. Une
 * valeur hors bornes ne provoquerait pas d'erreur — elle masquerait la
 * nutrition de toutes les recettes, ou rendrait le score absurde. C'est ici que
 * ça se garantit, pas dans le formulaire : le formulaire n'est qu'un appelant
 * parmi d'autres possibles.
 */
function requireRatio(value: unknown, field: string, { max = 1 }: { max?: number } = {}): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", `${field} doit être un nombre.`);
  }
  if (value < 0 || value > max) {
    throw new HttpsError("invalid-argument", `${field} doit être compris entre 0 et ${max}.`);
  }
  return value;
}

export const setNutritionSourcePolicyFn = onCall<SetNutritionPolicyRequest>(
  callableOpts,
  async (req) => {
    await requireAdmin(req);

    const next = req.data?.policy;
    if (!next) {
      throw new HttpsError("invalid-argument", "policy est requis.");
    }

    const quality = {
      ...DEFAULT_NUTRITION_POLICY.quality_policy,
      ...(next.quality_policy ?? {}),
    };
    quality.minCoverageForPartial = requireRatio(
      quality.minCoverageForPartial,
      "minCoverageForPartial",
    );
    quality.minCoverageForPer100g = requireRatio(
      quality.minCoverageForPer100g,
      "minCoverageForPer100g",
    );
    // Un écart toléré de plus de 100 % n'aurait aucun sens : l'avertissement
    // ne se déclencherait jamais.
    quality.kcalConsistencyWarnDeltaPct = requireRatio(
      quality.kcalConsistencyWarnDeltaPct,
      "kcalConsistencyWarnDeltaPct",
    );
    if (quality.kcalConsistencyWarnDeltaPct <= 0) {
      throw new HttpsError(
        "invalid-argument",
        "kcalConsistencyWarnDeltaPct doit être strictement positif : il sert de dénominateur au score de qualité.",
      );
    }
    // Le seuil d'affichage du « pour 100 g » est plus exigeant que celui du
    // calcul partiel. L'inverse produirait des valeurs pour 100 g affichées sur
    // une recette que l'app déclare par ailleurs trop incomplète pour être
    // représentative — deux messages qui se contredisent.
    if (quality.minCoverageForPer100g < quality.minCoverageForPartial) {
      throw new HttpsError(
        "invalid-argument",
        "minCoverageForPer100g doit être supérieur ou égal à minCoverageForPartial.",
      );
    }

    const fallback = next.fallback_policy ?? DEFAULT_NUTRITION_POLICY.fallback_policy;
    if (!["off", "strict", "permissive"].includes(fallback)) {
      throw new HttpsError(
        "invalid-argument",
        "fallback_policy doit valoir off, strict ou permissive.",
      );
    }

    const merged: NutritionSourcePolicy = {
      ...DEFAULT_NUTRITION_POLICY,
      ...next,
      fallback_policy: fallback,
      source_priority: next.source_priority ?? DEFAULT_NUTRITION_POLICY.source_priority,
      nutrient_aliases: next.nutrient_aliases ?? DEFAULT_NUTRITION_POLICY.nutrient_aliases,
      quality_policy: quality,
      version: typeof next.version === "number" ? next.version : Date.now(),
    };

    await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(NUTRITION_POLICY_DOC_ID)
      .set(
        {
          ...merged,
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );

    return { policy: merged };
  },
);

export const normalizeNutrientsFn = onCall<NormalizeNutrientsRequest>(callableOpts, async (req) => {
  requireAuth(req);
  const nutrients = req.data?.nutrients;
  if (!nutrients || typeof nutrients !== "object") {
    throw new HttpsError("invalid-argument", "nutrients est requis.");
  }

  const normalized = normalizeNutrients(nutrients);
  return { normalized };
});

export const computeRecipeNutritionFn = onCall<ComputeRecipeNutritionRequest>(
  // Les secrets sont montés parce que le calcul peut demander à l'IA quelles
  // lignes reprennent un ingrédient déjà listé. Sans eux, `.value()` échoue à
  // l'exécution — et un recalcul qui plante vaut moins qu'un doublon.
  {
    ...callableOpts,
    timeoutSeconds: 90,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
  },
  async (req) => {
    requireAuth(req);
    const recipeId = req.data?.recipeId;
    if (!recipeId || typeof recipeId !== "string") {
      throw new HttpsError("invalid-argument", "recipeId est requis.");
    }
    try {
      // `selectedPortions` n'est plus transmis : le calcul se fait aux
      // portions de la recette. Un lecteur ne dicte pas ce qui est écrit sur
      // un document que toute la famille lit.
      return await computeAndPersistRecipeNutrition({ aiEnabled: true, recipeId });
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
  {
    ...callableOpts,
    timeoutSeconds: 120,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    memory: "512MiB" as const,
  },
  async (req) => {
    requireAuth(req);

    return normalizeRecipeReferentialsCore({
      aiEnabled: true,
      recipeId: typeof req.data?.recipeId === "string" ? req.data.recipeId : undefined,
      cooklang: typeof req.data?.cooklang === "string" ? req.data.cooklang : "",
      ingredients: Array.isArray(req.data?.ingredients) ? req.data?.ingredients : undefined,
      userId: req.auth?.uid ?? undefined,
    });
  },
);

/// Audite les identifiants du référentiel d'ingrédients, et les répare si
/// `apply` est vrai. Réservé à l'administration.
export const cleanupIngredientReferentialFn = onCall<{ apply?: boolean }>(
  { ...callableOpts, timeoutSeconds: 540, memory: "512MiB" as const },
  async (req) => {
    await requireAdmin(req);
    return cleanupIngredientReferential({ apply: req.data?.apply === true });
  },
);

/// Verse la table d'amorçage des poids à la pièce dans le référentiel, pour que
/// celui-ci prenne le relais de la table intégrée. Réservé à l'administration.
export const seedIngredientPieceWeightsFn = onCall(
  { ...callableOpts, timeoutSeconds: 300 },
  async (req) => {
    await requireAdmin(req);
    return seedIngredientPieceWeights();
  },
);
