/**
 * Style des recettes — rattrapage de l'existant (ponctuel).
 *
 * `tags.styles` est apparu en v0.24.54 : la passe du rôle (import, suggestion
 * de tags, déclencheur, backfill « Rôle des recettes ») le pose sur ce qui
 * arrive ou change. Les recettes déjà classées ne l'ont pas, et une consigne
 * de planning « street food le vendredi » ne peut se vérifier que sur une
 * recette examinée.
 *
 * Un appel de modèle par recette, sur le style seul (`suggestRecipeStyles`) :
 * le rôle, la protéine et ce que la recette apporte, déjà posés et parfois
 * corrigés à la main, ne sont pas redemandés. Poste de coût
 * `backfill_recipe_styles`.
 *
 * Une recette examinée porte `tags.styles_checked_at`, même sans style
 * retenu : elle n'est plus reprise, et le passage finit « sans reste ». Un
 * style corrigé à la main (`tags.styles_manual`) n'est jamais réécrit, même
 * en reprise forcée ; la recette reçoit seulement le marqueur, sans appel.
 *
 * Réentrante : curseur dans `app_config/recipe_styles_backfill_checkpoint`.
 * Bornée trois fois — par le délai, par quarante recettes par appel, et par
 * trois échecs de suite, qui signalent une panne plutôt qu'une recette
 * difficile. Une recette en échec n'est pas marquée : elle est redemandée au
 * passage suivant, et nommée dans la liste « à revoir ».
 */

import { onCall } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import {
  ANTHROPIC_API_KEY,
  COLL_RECIPES,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { isStylesManual } from "../gemini/mealRole";
import { suggestRecipeStyles } from "../gemini/tagger";
import { logError, logInfo } from "../logging";
import { resolvePageType } from "../triggers/recipeWritten";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient la dernière recette examinée. */
export const RECIPE_STYLES_CHECKPOINT_DOC_ID = "recipe_styles_backfill_checkpoint";

const FEATURE = "backfill_recipe_styles";
const PAGE_SIZE = 100;
/** Recettes examinées par appel, par défaut : comme « Rôle des recettes ». */
const DEFAULT_MAX_RECIPES = 40;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillStylesRequest {
  maxMinutes?: number;
  maxRecipes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Réexaminer aussi les recettes déjà marquées ; un style corrigé à la main reste. */
  force?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillStylesResponse {
  examinees: number;
  /** Recettes dont le modèle a rendu le style (zéro à trois). */
  stylees: number;
  /** Parmi elles, celles sans aucun style retenu. */
  sansStyle: number;
  /** Déjà examinées (`styles_checked_at`), sautées. */
  dejaExaminees: number;
  /** Style corrigé à la main : marquées examinées sans appel. */
  manuelles: number;
  horsRecette: number;
  /** Le modèle n'a pas répondu sur le style, ou l'appel a échoué. */
  echouees: number;
  /**
   * Recettes encore sans `styles_checked_at`, sur toute la collection. `null`
   * quand le décompte a échoué : un `0` à sa place dirait que tout est fait.
   */
  restantes: number | null;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
  /** Recettes en échec dans ce passage, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/**
 * Recettes encore sans `tags.styles_checked_at`, comptées sur toute la
 * collection par trois agrégats, aucun document lu. `null` quand le décompte
 * échoue : l'erreur est journalisée, l'écran affiche « décompte impossible ».
 */
async function countRecipesWithoutStyle(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
): Promise<number | null> {
  try {
    const recipes = db.collection(COLL_RECIPES);
    const [total, examinees, horsRecette] = await Promise.all([
      recipes.count().get(),
      recipes.where("tags.styles_checked_at", "!=", null).count().get(),
      recipes.where("page_type", "!=", "recipe").count().get(),
    ]);
    return Math.max(0, total.data().count - examinees.data().count - horsRecette.data().count);
  } catch (e) {
    await logError("Style des recettes — décompte des recettes restantes impossible", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      geminiStatus: "ERROR",
      feature: FEATURE,
      errorDescription: e instanceof Error ? e.message : String(e),
    });
    return null;
  }
}

export const backfillRecipeStylesFn = onCall<BackfillStylesRequest>(
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
    const maxRecipesRaw = Number(req.data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
    const maxRecipes = Number.isFinite(maxRecipesRaw)
      ? Math.max(1, Math.min(200, Math.trunc(maxRecipesRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: RecipeStylesPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxRecipes,
      force: parseBoolean(req.data?.force, false),
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "recipe_styles",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runRecipeStylesPass(ctx, options),
      summarize: summarizeRecipeStyles,
    });
  },
);

/** Ce qu'un passage a le droit de faire. */
export interface RecipeStylesPassOptions {
  /** Instant de fin du passage ; la marge d'écriture du curseur est déduite ici. */
  deadlineMs: number;
  maxRecipes: number;
  force: boolean;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeRecipeStyles(r: BackfillStylesResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restantes,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    unresolved: r.echouees,
  };
}

/**
 * Ce que le passage fait d'une recette, sans appel : `null` quand elle est à
 * soumettre au modèle. Pure, testée par `recipeStylesBackfill.test.ts`.
 */
export function styleBackfillSkip(
  data: Record<string, unknown>,
  force: boolean,
): "hors_recette" | "manuelle" | "deja_examinee" | null {
  if (resolvePageType(data) !== "recipe") return "hors_recette";
  const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
    string,
    unknown
  >;
  if (isStylesManual(tags)) return "manuelle";
  if (!force && tags.styles_checked_at != null) return "deja_examinee";
  return null;
}

/** Un passage : le callable seul l'appelle, un ponctuel ne se programme pas. */
export async function runRecipeStylesPass(
  ctx: AuthContext,
  options: RecipeStylesPassOptions,
): Promise<BackfillStylesResponse> {
  const db = getFirestore();
  const { maxRecipes, force, resumeFromCheckpoint, resetCheckpoint } = options;
  const deadline = options.deadlineMs - DEADLINE_MARGIN_MS;

  let cursor = await getBackfillCursor({
    db,
    docId: RECIPE_STYLES_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint,
    resetCheckpoint,
  });

  const counters = {
    examinees: 0,
    stylees: 0,
    sansStyle: 0,
    dejaExaminees: 0,
    manuelles: 0,
    horsRecette: 0,
    echouees: 0,
  };
  let collectionParcourue = false;
  let stoppedByDeadline = false;
  let stoppedByBudget = false;
  let stoppedByErrors = false;
  let consecutiveFailures = 0;
  const review = new BackfillReview();

  pages: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      collectionParcourue = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > deadline) {
        stoppedByDeadline = true;
        break pages;
      }
      if (counters.stylees + counters.echouees >= maxRecipes) {
        stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        stoppedByErrors = true;
        break pages;
      }

      counters.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
        string,
        unknown
      >;
      const skip = styleBackfillSkip(data, force);
      if (skip === "hors_recette") {
        counters.horsRecette += 1;
        cursor = doc.id;
        continue;
      }
      if (skip === "deja_examinee") {
        counters.dejaExaminees += 1;
        cursor = doc.id;
        continue;
      }
      if (skip === "manuelle") {
        counters.manuelles += 1;
        // Le style choisi à la main reste ; seul le marqueur manquant est posé,
        // pour que la recette ne compte plus parmi les restantes.
        if (tags.styles_checked_at == null) {
          try {
            await doc.ref.update({ "tags.styles_checked_at": FieldValue.serverTimestamp() });
          } catch (e) {
            await logError("Style des recettes — marqueur d'une recette corrigée non écrit", {
              correlationId: ctx.correlationId,
              userId: ctx.userId,
              moduleType: "DESIGN",
              feature: FEATURE,
              errorDescription: e instanceof Error ? e.message : String(e),
              extra: { recipeId: doc.id },
            });
          }
        }
        cursor = doc.id;
        continue;
      }

      const titre = asString(data.titre);
      const cooklang = asString(data.draft_cooklang) || asString(data.raw_cooklang);
      try {
        const answer = await suggestRecipeStyles(
          { titre, cooklang, dishTypes: asStrings(tags.dish_types) },
          { ...ctx, feature: FEATURE, moduleType: "DESIGN" },
        );
        if (!answer.stylesChecked) {
          // Pas une erreur de code : le modèle n'a pas rendu de liste. La
          // recette reste sans marqueur, redemandée au passage suivant.
          counters.echouees += 1;
          consecutiveFailures += 1;
          review.add({
            kind: "recipe",
            id: doc.id,
            label: recipeReviewLabel(doc.id, data),
            reason: "L'IA n'a pas répondu sur le style",
          });
          await logInfo({
            message: "Style des recettes — le modèle n'a pas répondu sur le style",
            correlationId: ctx.correlationId,
            userId: ctx.userId,
            moduleType: "DESIGN",
            feature: FEATURE,
            extra: { recipeId: doc.id, titre },
          });
        } else {
          await doc.ref.update({
            "tags.styles": answer.styles,
            "tags.styles_checked_at": FieldValue.serverTimestamp(),
          });
          counters.stylees += 1;
          if (answer.styles.length === 0) counters.sansStyle += 1;
          consecutiveFailures = 0;
        }
      } catch (e) {
        counters.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Échec : ${shortErrorMessage(e)}`,
        });
        await logError("Style des recettes — échec sur une recette", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          geminiStatus: "ERROR",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { recipeId: doc.id, titre, consecutiveFailures },
        });
      }
      cursor = doc.id;
    }

    await setBackfillCursor({
      db,
      docId: RECIPE_STYLES_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < PAGE_SIZE) {
      collectionParcourue = true;
      break;
    }
  }

  const response: BackfillStylesResponse = {
    ...counters,
    restantes: await countRecipesWithoutStyle(db, ctx),
    collectionParcourue,
    stoppedByDeadline,
    stoppedByBudget,
    stoppedByErrors,
    completed: collectionParcourue,
    aRevoir: review.toJSON(),
  };

  // Le curseur revient au début quand tout est passé ; sinon il retient la
  // dernière recette examinée. Le compte rendu part dans l'état du backfill
  // (`backfills/runner.ts`), que l'écran lit en continu.
  await setBackfillCursor({
    db,
    docId: RECIPE_STYLES_CHECKPOINT_DOC_ID,
    lastDocId: collectionParcourue ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  await logInfo({
    message: "Style des recettes — rattrapage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxRecipes, force },
  });

  return response;
}
