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
import { suggestMealRole } from "../gemini/tagger";
import { logError, logInfo } from "../logging";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";

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
}

interface BackfillRolesResponse {
  examinees: number;
  classees: number;
  dejaClassees: number;
  horsRecette: number;
  /** Le modèle n'a pas su : la recette reste sans rôle, reprise au prochain appel. */
  sansRole: number;
  echouees: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
  completed: boolean;
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
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
  async (req): Promise<BackfillRolesResponse> => {
    const ctx = await requireAdmin(req, FEATURE);
    const db = getFirestore();

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const deadline = Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS;
    const maxRecipesRaw = Number(req.data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
    const maxRecipes = Number.isFinite(maxRecipesRaw)
      ? Math.max(1, Math.min(200, Math.trunc(maxRecipesRaw)))
      : DEFAULT_MAX_RECIPES;
    const force = parseBoolean(req.data?.force, false);
    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);

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
            await logInfo({
              message: "Rôle des recettes — le modèle n'a pas su classer une recette",
              correlationId: ctx.correlationId,
              userId: ctx.userId,
              moduleType: "DESIGN",
              feature: FEATURE,
              extra: { recipeId: doc.id, titre },
            });
          } else {
            await doc.ref.update({
              "tags.meal_role": fields.mealRole,
              "tags.contains": fields.contains,
              "tags.suggested_sides": fields.suggestedSides,
              "tags.roles_tagged_at": FieldValue.serverTimestamp(),
            });
            counters.classees += 1;
          }
          consecutiveFailures = 0;
        } catch (e) {
          counters.echouees += 1;
          consecutiveFailures += 1;
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

    // Le curseur revient au début quand tout est passé : un rappel de la
    // fonction reprendrait sinon une collection déjà traitée en entier. Sinon
    // il retient la dernière recette examinée, arrêt en cours de page compris.
    await setBackfillCursor({
      db,
      docId: RECIPE_ROLES_CHECKPOINT_DOC_ID,
      lastDocId: collectionParcourue ? null : cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });

    const response: BackfillRolesResponse = {
      ...counters,
      collectionParcourue,
      stoppedByDeadline,
      stoppedByBudget,
      stoppedByErrors,
      completed: collectionParcourue,
    };

    await logInfo({
      message: "Rôle des recettes — rattrapage",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      extra: { ...response, maxMinutes, maxRecipes, force },
    });

    return response;
  },
);
