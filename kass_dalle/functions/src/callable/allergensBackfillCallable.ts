/**
 * Allergènes — rattrapage du référentiel, puis recalcul des recettes.
 *
 * Deux phases, dans cet ordre, à chaque appel :
 *
 * 1. **Ingrédients.** Le référentiel est parcouru ; chaque ingrédient sans
 *    `allergens` est soumis au modèle, par lots de quarante (poste
 *    `backfill_allergens`). Un ingrédient déjà examiné — par le modèle ou par
 *    l'admin — n'est ni redemandé ni refacturé.
 * 2. **Recettes.** Seulement quand la phase 1 a parcouru tout le référentiel :
 *    `allergens` est recalculé sur chaque recette, sans appel de modèle. Une
 *    recette dont le résultat ne change pas n'est pas réécrite. C'est aussi ce
 *    que l'admin relance après avoir corrigé un ingrédient.
 *
 * Réentrante : deux points de reprise, un par phase. Bornée par le délai, par
 * un nombre d'ingrédients examinés et de recettes par appel, et par trois
 * lots en échec de suite, qui signalent une panne plutôt qu'un lot difficile.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import {
  ANTHROPIC_API_KEY,
  COLL_NUTRITION_INGREDIENTS,
  COLL_RECIPES,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import { recipeAllergensSignature } from "../nutrition/allergens";
import {
  ALLERGEN_BATCH_SIZE,
  allergenCandidateName,
  examineAllergenCandidates,
  recipeAllergensFromDocs,
  recipeIngredientNames,
  referentialIdsFor,
  unexaminedIngredientNames,
  type AllergenCandidate,
  type AllergenIssue,
} from "../nutrition/allergenExamination";
import { readDocsByIds } from "../nutrition/firestoreBatch";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  namesList,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewItem,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Point de reprise du parcours du référentiel. */
export const ALLERGENS_INGREDIENTS_CHECKPOINT_DOC_ID = "allergens_ingredients_backfill_checkpoint";
/** Point de reprise du recalcul des recettes. */
export const ALLERGENS_RECIPES_CHECKPOINT_DOC_ID = "allergens_recipes_backfill_checkpoint";

const FEATURE = "backfill_allergens";
const INGREDIENT_PAGE_SIZE = 300;
const RECIPE_PAGE_SIZE = 200;
/** Ingrédients soumis au modèle par appel, par défaut : dix lots. */
const DEFAULT_MAX_INGREDIENTS = 400;
/** Recettes recalculées par appel, par défaut. */
const DEFAULT_MAX_RECIPES = 500;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Un lot du modèle dure jusqu'à une minute : ne pas en lancer un sans cette marge. */
const BATCH_MARGIN_MS = 70_000;
/** Trois lots en échec de suite : une panne, pas trois lots difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillAllergensRequest {
  maxMinutes?: number;
  maxIngredients?: number;
  maxRecipes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillAllergensResponse {
  /** Ingrédients du référentiel lus pendant ce passage. */
  ingredientsLus: number;
  /** `allergens` posé par le modèle pendant ce passage. */
  ingredientsExamines: number;
  /** Déjà examinés (modèle ou admin) : ni appel, ni écriture. */
  ingredientsIgnores: number;
  /** Lot en échec ou ingrédient sans réponse : reste à examiner. */
  ingredientsEnErreur: number;
  /** Vrai quand la phase 1 a parcouru tout le référentiel. */
  referentielParcouru: boolean;
  recettesExaminees: number;
  /** `allergens` réécrit. */
  recettesCalculees: number;
  /** Résultat identique, rien d'écrit. */
  recettesIdentiques: number;
  /** Parmi les recettes de ce passage, celles dont le résultat reste incomplet. */
  recettesIncompletes: number;
  recettesHorsRecette: number;
  recettesEchouees: number;
  /** Vrai quand la phase 2 a parcouru toutes les recettes. */
  recettesParcourues: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Les deux phases ont parcouru leur collection : les curseurs sont remis au début. */
  completed: boolean;
  /**
   * Ingrédients en erreur ou sans réponse, recettes incomplètes ou en échec,
   * nommés : la liste « à revoir » (`_backfillReview.ts`).
   */
  aRevoir: BackfillReviewList;
}

/** Ligne « à revoir » d'un ingrédient resté sans allergènes. */
export function allergenIssueReviewItem(issue: AllergenIssue): BackfillReviewItem {
  return {
    kind: "ingredient",
    id: issue.id,
    label: issue.name,
    reason:
      issue.problem === "unanswered"
        ? "Pas de réponse de l'IA"
        : `Lot en échec : ${shortErrorMessage(issue.error ?? "")}`,
  };
}

/**
 * Raison « à revoir » d'une recette au résultat incomplet : les ingrédients
 * jamais examinés, ou l'absence d'ingrédient nommé.
 */
export function incompleteRecipeReason(unexamined: readonly string[]): string {
  if (unexamined.length === 0) return "Recette incomplète : aucun ingrédient nommé";
  const verb = unexamined.length > 1 ? "non examinés" : "non examiné";
  return `Recette incomplète : ${namesList(unexamined)} ${verb}`;
}

function emptyResponse(): BackfillAllergensResponse {
  return {
    ingredientsLus: 0,
    ingredientsExamines: 0,
    ingredientsIgnores: 0,
    ingredientsEnErreur: 0,
    referentielParcouru: false,
    recettesExaminees: 0,
    recettesCalculees: 0,
    recettesIdentiques: 0,
    recettesIncompletes: 0,
    recettesHorsRecette: 0,
    recettesEchouees: 0,
    recettesParcourues: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
}

interface Bounds {
  deadline: number;
  maxIngredients: number;
  maxRecipes: number;
}

// ── Phase 1 : le référentiel ────────────────────────────────────────────────

async function runIngredientsPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  response: BackfillAllergensResponse,
  review: BackfillReview,
  startAfter: string | null,
): Promise<string | null> {
  let cursor = startAfter;
  let consecutiveFailures = 0;
  let submitted = 0;

  pages: for (;;) {
    let query = db
      .collection(COLL_NUTRITION_INGREDIENTS)
      .orderBy("__name__")
      .limit(INGREDIENT_PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.referentielParcouru = true;
      break;
    }

    // La page est traitée lot par lot ; le curseur n'avance qu'après un lot
    // entier, pour qu'un arrêt ne saute aucun ingrédient.
    let pending: { candidate: AllergenCandidate; docId: string }[] = [];
    const flush = async (): Promise<boolean> => {
      if (pending.length === 0) return true;
      if (Date.now() + BATCH_MARGIN_MS > bounds.deadline) {
        response.stoppedByDeadline = true;
        return false;
      }
      if (submitted >= bounds.maxIngredients) {
        response.stoppedByBudget = true;
        return false;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        return false;
      }
      const batch = pending.map((p) => p.candidate);
      const report = await examineAllergenCandidates({
        candidates: batch,
        ctx: { correlationId: ctx.correlationId, userId: ctx.userId, feature: FEATURE },
        extra: { phase: "ingredients" },
      });
      submitted += batch.length;
      response.ingredientsExamines += report.examined;
      response.ingredientsIgnores += report.alreadyExamined;
      response.ingredientsEnErreur += report.failed + report.unanswered;
      for (const issue of report.issues) review.add(allergenIssueReviewItem(issue));
      consecutiveFailures = report.failed > 0 ? consecutiveFailures + 1 : 0;
      cursor = pending[pending.length - 1].docId;
      pending = [];
      return true;
    };

    for (const doc of page.docs) {
      response.ingredientsLus += 1;
      const data = doc.data() as Record<string, unknown>;
      if (Array.isArray(data.allergens)) {
        response.ingredientsIgnores += 1;
        if (pending.length === 0) cursor = doc.id;
        continue;
      }
      pending.push({
        candidate: { id: doc.id, name: allergenCandidateName(doc.id, data) },
        docId: doc.id,
      });
      if (pending.length >= ALLERGEN_BATCH_SIZE && !(await flush())) break pages;
    }
    if (!(await flush())) break;
    cursor = page.docs[page.docs.length - 1].id;

    await setBackfillCursor({
      db,
      docId: ALLERGENS_INGREDIENTS_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < INGREDIENT_PAGE_SIZE) {
      response.referentielParcouru = true;
      break;
    }
  }
  return cursor;
}

// ── Phase 2 : les recettes ──────────────────────────────────────────────────

async function runRecipesPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  response: BackfillAllergensResponse,
  review: BackfillReview,
  startAfter: string | null,
): Promise<string | null> {
  let cursor = startAfter;
  let consecutiveFailures = 0;
  let treated = 0;

  pages: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(RECIPE_PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      response.recettesParcourues = true;
      break;
    }

    // Une lecture du référentiel pour la page entière, pas une par recette.
    const names = new Set<string>();
    for (const doc of page.docs) {
      for (const name of recipeIngredientNames(doc.data() as Record<string, unknown>)) {
        names.add(name);
      }
    }
    const docs = await readDocsByIds(COLL_NUTRITION_INGREDIENTS, referentialIdsFor(names));

    for (const doc of page.docs) {
      if (Date.now() > bounds.deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (treated >= bounds.maxRecipes) {
        response.stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break pages;
      }

      response.recettesExaminees += 1;
      const data = doc.data() as Record<string, unknown>;
      // Une page sans `page_type` est une recette : le client n'écrit le
      // champ que pour les autres types.
      const pageType = typeof data.page_type === "string" ? data.page_type : "recipe";
      if (pageType !== "recipe") {
        response.recettesHorsRecette += 1;
        cursor = doc.id;
        continue;
      }

      try {
        const computed = recipeAllergensFromDocs(data, docs);
        if (!computed.complete) {
          response.recettesIncompletes += 1;
          review.add({
            kind: "recipe",
            id: doc.id,
            label: recipeReviewLabel(doc.id, data),
            reason: incompleteRecipeReason(unexaminedIngredientNames(data, docs)),
          });
        }
        if (
          data.allergens !== undefined &&
          recipeAllergensSignature(computed) === recipeAllergensSignature(data.allergens)
        ) {
          response.recettesIdentiques += 1;
        } else {
          await doc.ref.update({
            allergens: { ...computed, computed_at: FieldValue.serverTimestamp() },
          });
          response.recettesCalculees += 1;
        }
        treated += 1;
        consecutiveFailures = 0;
      } catch (e) {
        response.recettesEchouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Échec du recalcul : ${shortErrorMessage(e)}`,
        });
        await logError("Allergènes — échec sur une recette", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { recipeId: doc.id, consecutiveFailures },
        });
      }
      cursor = doc.id;
    }

    await setBackfillCursor({
      db,
      docId: ALLERGENS_RECIPES_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < RECIPE_PAGE_SIZE) {
      response.recettesParcourues = true;
      break;
    }
  }
  return cursor;
}

// ── Point d'entrée ──────────────────────────────────────────────────────────

export const backfillAllergensFn = onCall<BackfillAllergensRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxIngredientsRaw = Number(req.data?.maxIngredients ?? DEFAULT_MAX_INGREDIENTS);
    const maxIngredients = Number.isFinite(maxIngredientsRaw)
      ? Math.max(1, Math.min(2000, Math.trunc(maxIngredientsRaw)))
      : DEFAULT_MAX_INGREDIENTS;
    const maxRecipesRaw = Number(req.data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
    const maxRecipes = Number.isFinite(maxRecipesRaw)
      ? Math.max(1, Math.min(5000, Math.trunc(maxRecipesRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: AllergensPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxIngredients,
      maxRecipes,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "allergens",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runAllergensPass(ctx, options),
      summarize: summarizeAllergens,
    });
  },
);

/** Ce qu'un passage a le droit de faire. */
export interface AllergensPassOptions {
  /** Instant de fin du passage ; la marge d'écriture des curseurs est déduite ici. */
  deadlineMs: number;
  maxIngredients: number;
  maxRecipes: number;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeAllergens(r: BackfillAllergensResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
  };
}

/**
 * Un passage, quelle que soit son entrée : le callable (un administrateur) ou
 * `scheduledBackfills` (la programmation, imputée à l'administrateur qui l'a
 * enregistrée — `ctx.userId`).
 */
export async function runAllergensPass(
  ctx: AuthContext,
  options: AllergensPassOptions,
): Promise<BackfillAllergensResponse> {
  const db = getFirestore();
  const bounds: Bounds = {
    deadline: options.deadlineMs - DEADLINE_MARGIN_MS,
    maxIngredients: options.maxIngredients,
    maxRecipes: options.maxRecipes,
  };
  const { resumeFromCheckpoint, resetCheckpoint } = options;

  const response = emptyResponse();
  const review = new BackfillReview();

  const ingredientsStart = await getBackfillCursor({
    db,
    docId: ALLERGENS_INGREDIENTS_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint,
    resetCheckpoint,
  });
  const ingredientsCursor = await runIngredientsPhase(
    db,
    ctx,
    bounds,
    response,
    review,
    ingredientsStart,
  );
  await setBackfillCursor({
    db,
    docId: ALLERGENS_INGREDIENTS_CHECKPOINT_DOC_ID,
    lastDocId: response.referentielParcouru ? null : ingredientsCursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  // Les recettes ne se recalculent que contre un référentiel parcouru en
  // entier : sinon une partie des recettes serait recalculée avec des
  // ingrédients encore à examiner, et le serait à nouveau au passage suivant.
  if (response.referentielParcouru) {
    const recipesStart = await getBackfillCursor({
      db,
      docId: ALLERGENS_RECIPES_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint,
      resetCheckpoint,
    });
    const recipesCursor = await runRecipesPhase(db, ctx, bounds, response, review, recipesStart);
    await setBackfillCursor({
      db,
      docId: ALLERGENS_RECIPES_CHECKPOINT_DOC_ID,
      lastDocId: response.recettesParcourues ? null : recipesCursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });
  }

  response.completed = response.referentielParcouru && response.recettesParcourues;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "Allergènes — rattrapage des ingrédients et des recettes",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: {
      ...withoutReviewList(response),
      maxIngredients: options.maxIngredients,
      maxRecipes: options.maxRecipes,
    },
  });

  return response;
}
