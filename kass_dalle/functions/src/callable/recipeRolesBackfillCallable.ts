/**
 * Rôle des recettes dans un repas — rattrapage de l'existant.
 *
 * Trois champs viennent d'apparaître sur `tags` : `meal_role`, `contains`,
 * `suggested_sides`. La passe 2 de l'import les pose sur ce qui arrive ; les
 * recettes déjà en base ne les ont pas, et le planning ne peut composer un
 * repas — un plat et son accompagnement — que pour une recette classée.
 *
 * Un appel de modèle par recette, sur le rôle seul : les cuisines et types de
 * plat existants ne sont pas redemandés, ils ont pu être corrigés à la main.
 * Le poste de coût est `backfill_recipe_roles`, distinct de la suggestion de
 * tags : une reprise en masse se lit à part dans les comptes.
 *
 * Réentrante : une recette déjà classée n'est pas reprise (sauf `force`), et
 * le curseur permet de continuer où l'appel précédent s'est arrêté. Bornée
 * trois fois — par le délai, par un nombre de recettes par appel, et par
 * trois échecs de suite, qui signalent une panne plutôt qu'une recette
 * difficile.
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
import { mainIngredientsPatch } from "../gemini/mealRole";
import { suggestMealRole } from "../gemini/tagger";
import { logError, logInfo } from "../logging";
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
export const RECIPE_ROLES_CHECKPOINT_DOC_ID = "recipe_roles_backfill_checkpoint";

const FEATURE = "backfill_recipe_roles";
const PAGE_SIZE = 100;
/** Recettes classées par appel, par défaut : tient dans les huit minutes. */
const DEFAULT_MAX_RECIPES = 40;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillRolesRequest {
  maxMinutes?: number;
  maxRecipes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Reclasser aussi les recettes qui portent déjà un rôle. */
  force?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillRolesResponse {
  examinees: number;
  classees: number;
  dejaClassees: number;
  horsRecette: number;
  /** Le modèle n'a pas su : la recette reste sans rôle, reprise au prochain appel. */
  sansRole: number;
  echouees: number;
  /**
   * Recettes encore sans rôle après ce passage, sur toute la collection —
   * le chiffre que l'on cherche quand on relance pour la troisième fois.
   * `null` quand le décompte a échoué : un `0` à sa place dirait que tout est classé.
   */
  restantes: number | null;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
  /** Recettes sans rôle ou en échec dans ce passage, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/**
 * Recettes encore sans rôle, comptées sur toute la collection et non sur ce
 * passage. Trois agrégats, aucun document lu : toutes les pages, celles qui
 * portent un rôle, celles qui ne sont pas des recettes. `!= null` ne retient
 * que le champ présent et renseigné — l'import écrit `null` quand la passe 2
 * n'a pas su, et cette recette-là reste à classer. Une page non-recette qui
 * porterait un rôle serait déduite deux fois ; aucune n'en reçoit.
 *
 * `null` quand le décompte échoue : le passage a eu lieu et ses compteurs
 * valent ; l'erreur est journalisée, et le client affiche « décompte
 * impossible » plutôt qu'un zéro.
 */
async function countRecipesWithoutRole(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
): Promise<number | null> {
  try {
    const recipes = db.collection(COLL_RECIPES);
    const [total, avecRole, horsRecette] = await Promise.all([
      recipes.count().get(),
      recipes.where("tags.meal_role", "!=", null).count().get(),
      recipes.where("page_type", "!=", "recipe").count().get(),
    ]);
    return Math.max(0, total.data().count - avecRole.data().count - horsRecette.data().count);
  } catch (e) {
    await logError("Rôle des recettes — décompte des recettes restantes impossible", {
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

export const backfillRecipeRolesFn = onCall<BackfillRolesRequest>(
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
    const options: RecipeRolesPassOptions = {
      deadlineMs: Date.now() + maxMinutes * 60_000,
      maxRecipes,
      force: parseBoolean(req.data?.force, false),
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "recipe_roles",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runRecipeRolesPass(ctx, options),
      summarize: summarizeRecipeRoles,
    });
  },
);

/** Ce qu'un passage a le droit de faire. */
export interface RecipeRolesPassOptions {
  /** Instant de fin du passage ; la marge d'écriture du curseur est déduite ici. */
  deadlineMs: number;
  maxRecipes: number;
  force: boolean;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeRecipeRoles(r: BackfillRolesResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restantes,
    toReview: r.aRevoir.total,
    spendCapHit: false,
  };
}

/**
 * Un passage, quelle que soit son entrée : le callable (un administrateur) ou
 * `scheduledBackfills` (la programmation, imputée à l'administrateur qui l'a
 * enregistrée — `ctx.userId`).
 */
export async function runRecipeRolesPass(
  ctx: AuthContext,
  options: RecipeRolesPassOptions,
): Promise<BackfillRolesResponse> {
  const db = getFirestore();
  const { maxRecipes, force, resumeFromCheckpoint, resetCheckpoint } = options;
  const deadline = options.deadlineMs - DEADLINE_MARGIN_MS;

  let cursor = await getBackfillCursor({
    db,
    docId: RECIPE_ROLES_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint,
    resetCheckpoint,
  });

  const counters = {
    examinees: 0,
    classees: 0,
    dejaClassees: 0,
    horsRecette: 0,
    sansRole: 0,
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
      if (counters.classees + counters.sansRole + counters.echouees >= maxRecipes) {
        stoppedByBudget = true;
        break pages;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        stoppedByErrors = true;
        break pages;
      }

      counters.examinees += 1;
      const data = doc.data() as Record<string, unknown>;
      // Une page sans `page_type` est une recette : le client n'écrit le
      // champ que pour les autres types.
      const pageType = typeof data.page_type === "string" ? data.page_type : "recipe";
      const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
        string,
        unknown
      >;

      if (pageType !== "recipe") {
        counters.horsRecette += 1;
        cursor = doc.id;
        continue;
      }
      if (!force && asString(tags.meal_role).length > 0) {
        counters.dejaClassees += 1;
        cursor = doc.id;
        continue;
      }

      const titre = asString(data.titre);
      const cooklang = asString(data.draft_cooklang) || asString(data.raw_cooklang);
      try {
        const fields = await suggestMealRole(
          GEMINI_API_KEY.value(),
          { titre, cooklang, dishTypes: asStrings(tags.dish_types) },
          { ...ctx, feature: FEATURE, moduleType: "DESIGN" },
        );
        if (fields.mealRole == null) {
          // Pas une erreur : le modèle n'a pas su. La recette reste sans
          // rôle et sera réexaminée ; le dire, sinon « sansRole » ne se
          // relie à aucune recette.
          counters.sansRole += 1;
          review.add({
            kind: "recipe",
            id: doc.id,
            label: recipeReviewLabel(doc.id, data),
            reason: "L'IA n'a pas su classer la recette",
          });
          await logInfo({
            message: "Rôle des recettes — le modèle n'a pas su classer une recette",
            correlationId: ctx.correlationId,
            userId: ctx.userId,
            moduleType: "DESIGN",
            feature: FEATURE,
            extra: { recipeId: doc.id, titre },
          });
        } else {
          // Une protéine ou un féculent déjà posés ne sont pas remplacés.
          const patch = mainIngredientsPatch(tags, fields);
          await doc.ref.update({
            "tags.meal_role": fields.mealRole,
            "tags.contains": fields.contains,
            "tags.suggested_sides": fields.suggestedSides,
            ...(patch.main_protein ? { "tags.main_protein": patch.main_protein } : {}),
            ...(patch.main_starch ? { "tags.main_starch": patch.main_starch } : {}),
            ...(fields.mainIngredientsChecked
              ? { "tags.main_ingredients_checked_at": FieldValue.serverTimestamp() }
              : {}),
            "tags.roles_tagged_at": FieldValue.serverTimestamp(),
          });
          counters.classees += 1;
        }
        consecutiveFailures = 0;
      } catch (e) {
        counters.echouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "recipe",
          id: doc.id,
          label: recipeReviewLabel(doc.id, data),
          reason: `Échec : ${shortErrorMessage(e)}`,
        });
        await logError("Rôle des recettes — échec sur une recette", {
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
      docId: RECIPE_ROLES_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    if (page.size < PAGE_SIZE) {
      collectionParcourue = true;
      break;
    }
  }

  const response: BackfillRolesResponse = {
    ...counters,
    restantes: await countRecipesWithoutRole(db, ctx),
    collectionParcourue,
    stoppedByDeadline,
    stoppedByBudget,
    stoppedByErrors,
    completed: collectionParcourue,
    aRevoir: review.toJSON(),
  };

  // Le curseur revient au début quand tout est passé : un rappel de la
  // fonction reprendrait sinon une collection déjà traitée en entier. Sinon
  // il retient la dernière recette examinée, arrêt en cours de page compris.
  // Le compte rendu part dans l'état du backfill (`backfills/runner.ts`),
  // que l'écran lit en continu.
  await setBackfillCursor({
    db,
    docId: RECIPE_ROLES_CHECKPOINT_DOC_ID,
    lastDocId: collectionParcourue ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  await logInfo({
    message: "Rôle des recettes — rattrapage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxRecipes, force },
  });

  return response;
}
