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

import { REGION, COLL_APP_CONFIG, GEMINI_API_KEY } from "../config";
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
import { cleanupIngredientReferential } from "../nutrition/referentialCleanup";
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
  { ...callableOpts, timeoutSeconds: 120, secrets: [GEMINI_API_KEY], memory: "512MiB" as const },
  async (req) => {
    requireAuth(req);

    return normalizeRecipeReferentialsCore({
      recipeId: typeof req.data?.recipeId === "string" ? req.data.recipeId : undefined,
      cooklang: typeof req.data?.cooklang === "string" ? req.data.cooklang : "",
      ingredients: Array.isArray(req.data?.ingredients)
        ? req.data?.ingredients
        : undefined,
      geminiApiKey: GEMINI_API_KEY.value(),
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
