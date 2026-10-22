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

import {
  REGION,
  COLL_APP_CONFIG,
  COLL_RECIPES,
  GEMINI_API_KEY,
  ANTHROPIC_API_KEY,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { requireAdmin, requireAuth, requireEditor } from "./_auth";
import { assertCanModifyRecipe, assertCanNormalizeReferentials } from "./_recipeAccess";
import {
  LIST_MAX_ITEMS,
  RECIPE_TEXT_MAX_CHARS,
  STRUCTURED_ITEM_MAX_CHARS,
  readAiInputs,
} from "./_inputBounds";
import {
  DEFAULT_NUTRITION_POLICY,
  getNutritionSourcePolicy,
  NUTRITION_POLICY_DOC_ID,
  type NutritionSourcePolicy,
} from "../nutrition/policy";
import { normalizeNutrients } from "../nutrition/nutrients";
import { computeAndPersistRecipeNutrition } from "../nutrition/recipeNutrition";
import { normalizeRecipeReferentialsCore } from "../nutrition/referentialNormalization";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { logError } from "../logging";
import { toHttpsError } from "./_callableErrors";
const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
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
  await requireAuth(req, "politique_nutrition_lecture");
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
    await requireAdmin(req, "politique_nutrition_ecriture");

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
  await requireAuth(req, "normalisation_nutriments");
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
    // L'IA qui modifie une recette est réservée aux éditeurs (v0.24.66,
    // tickets #162 et #163) ;
    // la propriété de la recette se vérifie ensuite. `onRecipeWritten`
    // calcule pour toutes les recettes, hors de cette garde.
    const ctx = await requireEditor(req, "calcul_nutrition");
    const recipeId = req.data?.recipeId;
    if (!recipeId || typeof recipeId !== "string") {
      throw new HttpsError("invalid-argument", "recipeId est requis.");
    }
    // Le calcul s'écrit sur la recette et peut appeler un modèle sur ses
    // ingrédients : créateur ou administrateur, comme `allow update` dans les
    // règles. Les autres lisent la nutrition stockée. Les déclencheurs
    // (`onRecipeWritten`, rattrapage) ne passent pas par ici et continuent de
    // calculer pour toutes les recettes.
    const recipeSnap = await getFirestore().collection(COLL_RECIPES).doc(recipeId).get();
    if (!recipeSnap.exists) {
      throw new HttpsError("not-found", "Recette introuvable.");
    }
    await assertCanModifyRecipe(recipeSnap.data(), ctx.userId);
    try {
      // `selectedPortions` n'est plus transmis : le calcul se fait aux
      // portions de la recette. Un lecteur ne dicte pas ce qui est écrit sur
      // un document que toute la famille lit.
      return await computeAndPersistRecipeNutrition({
        aiEnabled: true,
        recipeId,
        correlationId: ctx.correlationId,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await logError({
        message: "computeRecipeNutritionFn: ERREUR",
        errorDescription: message,
        correlationId: ctx.correlationId,
        extra: {
          recipeId,
          uid: req.auth?.uid ?? null,
          selectedPortions: req.data?.selectedPortions ?? null,
        },
      });
      // Le texte brut ne part pas au client : `toHttpsError` garde les
      // `HttpsError` volontaires (recette introuvable), rend le plafond d'IA
      // du compte avec son message et ses `details`, et remplace le reste par
      // un texte fixe. L'erreur vient d'être journalisée avec son contexte.
      throw await toHttpsError(err, { alreadyLogged: true });
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
    const ctx = await requireAuth(req, "normalisation_referentiels");
    const data = (req.data ?? {}) as Record<string, unknown>;
    // Écrit dans le référentiel partagé : éditeur ou administrateur
    // seulement (`assertCanNormalizeReferentials`).
    await assertCanNormalizeReferentials({
      recipeId: data.recipeId,
      callerUid: ctx.userId,
      correlationId: ctx.correlationId,
    });
    // Plusieurs postes d'IA partent de cette normalisation (unités, poids,
    // per100g…) : le relevé porte le nom de l'entrée, pas celui d'un poste.
    const { cooklang, ingredients } = await readAiInputs(
      { ...ctx, feature: "normalisation_referentiels" },
      (inputs) => ({
        cooklang:
          typeof data.cooklang === "string"
            ? (inputs.text(data.cooklang, { field: "cooklang", max: RECIPE_TEXT_MAX_CHARS }) ?? "")
            : "",
        ingredients: Array.isArray(data.ingredients)
          ? inputs.list<Record<string, unknown>>(data.ingredients, {
              field: "ingredients",
              maxItems: LIST_MAX_ITEMS,
              maxItemChars: STRUCTURED_ITEM_MAX_CHARS,
            })
          : undefined,
      }),
    );

    const recipeId = typeof data.recipeId === "string" ? data.recipeId : undefined;
    try {
      return await normalizeRecipeReferentialsCore({
        aiEnabled: true,
        recipeId,
        cooklang,
        ingredients,
        userId: req.auth?.uid ?? undefined,
        // Sans ce fil, les enrichissements déclenchés par une SAUVEGARDE
        // fabriquaient chacun le leur : une même normalisation se lisait en
        // quatre groupes de journaux sans rapport apparent.
        correlationId: ctx.correlationId,
      });
    } catch (err) {
      await logError({
        message: "normalizeRecipeReferentialsFn: ERREUR",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: ctx.correlationId,
        extra: { recipeId: recipeId ?? null, uid: req.auth?.uid ?? null },
      });
      // Même traduction que les autres callables d'IA : plafond du compte
      // avec son message, texte fixe pour le reste.
      throw await toHttpsError(err, { alreadyLogged: true });
    }
  },
);
