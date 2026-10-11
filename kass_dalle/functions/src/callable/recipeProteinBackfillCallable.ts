/**
 * Protéine et féculent des plats — rattrapage de l'existant.
 *
 * Deux champs sont apparus sur `tags` en v0.23.24 : `main_protein` et
 * `main_starch`. Le prompt du rôle (`MEAL_ROLE_PROMPT`) les pose sur ce qui
 * arrive — import, « Suggérer les tags », classement à l'écriture. Les plats
 * et accompagnements déjà classés ne les ont pas, et la présélection du
 * planning retombe alors sur l'indice de `dish_types` pour varier la protéine,
 * et n'alterne pas les féculents.
 *
 * Un appel de modèle par recette, sur ces deux champs seuls : le rôle est
 * donné au modèle, pas demandé. Rien d'autre n'est réécrit — ni `meal_role`,
 * ni `contains`, ni `dish_types`, qui ont pu être corrigés à la main. Le poste
 * de coût est `backfill_recipe_protein`.
 *
 * Réentrante : une recette examinée porte `tags.main_ingredients_checked_at`
 * et n'est plus questionnée. Le marqueur est posé dès que le modèle a répondu,
 * même par une valeur hors liste (« veau ») : sans lui, la recette serait
 * requestionnée et refacturée à chaque tour. Une recette sans réponse (deux
 * chaînes vides, réponse illisible, échec) reste à refaire. Seuls les champs
 * absents sont écrits : une protéine ou un féculent déjà posés, à la main ou
 * par un autre chemin, ne sont jamais remplacés. Le curseur reprend où
 * l'appel précédent s'est arrêté. Bornée
 * trois fois — par le délai, par quarante recettes par appel, et par trois
 * échecs de suite.
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
import {
  MAIN_INGREDIENTS_CHECKED_FIELD,
  hasBothMainIngredients,
  mainIngredientsPatch,
  parseMealRole,
  ROLES_WITH_MAIN_INGREDIENTS,
} from "../gemini/mealRole";
import { suggestMainProteinStarch } from "../gemini/tagger";
import { logError, logInfo } from "../logging";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
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
export const RECIPE_PROTEIN_CHECKPOINT_DOC_ID = "recipe_protein_backfill_checkpoint";

const FEATURE = "backfill_recipe_protein";
const PAGE_SIZE = 100;
/** Recettes questionnées par appel, par défaut : comme « Rôle des recettes ». */
const DEFAULT_MAX_RECIPES = 40;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois recettes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillProteinRequest {
  maxMinutes?: number;
  maxRecipes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

interface BackfillProteinResponse {
  examinees: number;
  /** Plats et accompagnements examinés par le modèle dans ce passage, et marqués. */
  traitees: number;
  /**
   * Déjà marqués, ou portant `main_protein` et `main_starch` sans marqueur
   * (marqueur posé, sans appel).
   */
  dejaTraitees: number;
  /** Pages non-recettes, recettes sans rôle, entrées, desserts, snacks. */
  ignorees: number;
  /** Le modèle n'a pas répondu (deux chaînes vides) : la recette sera réexaminée. */
  sansReponse: number;
  echouees: number;
  /**
   * Plats et accompagnements encore sans marqueur d'examen, sur toute la
   * collection. `null` quand le décompte a échoué.
   */
  restantes: number | null;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  /** Recettes sans réponse ou en échec dans ce passage, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/**
 * Plats et accompagnements pas encore examinés, par deux agrégats sans index
 * composite : ceux qui portent l'un des deux rôles, moins toutes les recettes
 * qui portent le marqueur d'examen. Une recette dont le rôle a été changé à la
 * main après coup (plat devenu dessert) garde son marqueur et fait baisser le
 * reste d'une unité : le compte est un ordre de grandeur, le passage
 * « terminé » fait foi. Il tombe à zéro après un tour complet sans « sans
 * réponse » ni échec.
 */
async function countRemaining(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
): Promise<number | null> {
  try {
    const recipes = db.collection(COLL_RECIPES);
    const [concernees, examinees] = await Promise.all([
      recipes
        .where("tags.meal_role", "in", [...ROLES_WITH_MAIN_INGREDIENTS])
        .count()
        .get(),
      recipes.where(`tags.${MAIN_INGREDIENTS_CHECKED_FIELD}`, "!=", null).count().get(),
    ]);
    return Math.max(0, concernees.data().count - examinees.data().count);
  } catch (e) {
    await logError("Protéine et féculent des plats — décompte des recettes restantes impossible", {
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

export const backfillRecipeProteinFn = onCall<BackfillProteinRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillProteinResponse> => {
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
    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);

    let cursor = await getBackfillCursor({
      db,
      docId: RECIPE_PROTEIN_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint,
      resetCheckpoint,
    });

    const counters = {
      examinees: 0,
      traitees: 0,
      dejaTraitees: 0,
      ignorees: 0,
      sansReponse: 0,
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
        if (counters.traitees + counters.sansReponse + counters.echouees >= maxRecipes) {
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
        const mealRole = parseMealRole(tags.meal_role);

        if (
          pageType !== "recipe" ||
          mealRole == null ||
          !ROLES_WITH_MAIN_INGREDIENTS.includes(mealRole)
        ) {
          counters.ignorees += 1;
          cursor = doc.id;
          continue;
        }
        if (tags[MAIN_INGREDIENTS_CHECKED_FIELD] != null) {
          counters.dejaTraitees += 1;
          cursor = doc.id;
          continue;
        }
        if (hasBothMainIngredients(tags)) {
          // Protéine et féculent posés sans marqueur (« Suggérer les tags »
          // d'un ancien client, ou valeurs saisies) : rien à demander au
          // modèle. Le marqueur seul, pour que le reste à traiter tombe à
          // zéro. Un seul des deux posé : le modèle propose l'autre.
          try {
            await doc.ref.update({
              [`tags.${MAIN_INGREDIENTS_CHECKED_FIELD}`]: FieldValue.serverTimestamp(),
            });
            counters.dejaTraitees += 1;
          } catch (e) {
            counters.echouees += 1;
            review.add({
              kind: "recipe",
              id: doc.id,
              label: recipeReviewLabel(doc.id, data),
              reason: `Marqueur d'examen non écrit : ${shortErrorMessage(e)}`,
            });
            await logError("Protéine et féculent des plats — marqueur non écrit", {
              correlationId: ctx.correlationId,
              userId: ctx.userId,
              moduleType: "DESIGN",
              feature: FEATURE,
              errorDescription: e instanceof Error ? e.message : String(e),
              extra: { recipeId: doc.id },
            });
          }
          cursor = doc.id;
          continue;
        }

        const titre = asString(data.titre);
        const cooklang = asString(data.draft_cooklang) || asString(data.raw_cooklang);
        try {
          const fields = await suggestMainProteinStarch(
            { titre, cooklang, mealRole, dishTypes: asStrings(tags.dish_types) },
            { ...ctx, feature: FEATURE, moduleType: "DESIGN" },
          );
          if (!fields.mainIngredientsChecked) {
            // Pas une erreur : le modèle n'a pas répondu. Rien n'est écrit, la
            // recette sera réexaminée au prochain tour complet.
            counters.sansReponse += 1;
            review.add({
              kind: "recipe",
              id: doc.id,
              label: recipeReviewLabel(doc.id, data),
              reason: "Pas de réponse de l'IA",
            });
            await logInfo({
              message: "Protéine et féculent des plats — pas de réponse du modèle",
              correlationId: ctx.correlationId,
              userId: ctx.userId,
              moduleType: "DESIGN",
              feature: FEATURE,
              extra: { recipeId: doc.id, titre },
            });
          } else {
            // Les champs absents seulement, et le marqueur : le rôle, ce que
            // la recette apporte, ses types de plat et une valeur déjà posée
            // ont pu être corrigés à la main. Une réponse hors liste
            // (« veau ») n'écrit que le marqueur.
            const patch = mainIngredientsPatch(tags, fields);
            await doc.ref.update({
              ...Object.fromEntries(Object.entries(patch).map(([k, v]) => [`tags.${k}`, v])),
              [`tags.${MAIN_INGREDIENTS_CHECKED_FIELD}`]: FieldValue.serverTimestamp(),
            });
            counters.traitees += 1;
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
          await logError("Protéine et féculent des plats — échec sur une recette", {
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
        docId: RECIPE_PROTEIN_CHECKPOINT_DOC_ID,
        lastDocId: cursor,
        operation: FEATURE,
        adminUid: ctx.userId,
      });

      if (page.size < PAGE_SIZE) {
        collectionParcourue = true;
        break;
      }
    }

    const response: BackfillProteinResponse = {
      ...counters,
      restantes: await countRemaining(db, ctx),
      collectionParcourue,
      stoppedByDeadline,
      stoppedByBudget,
      stoppedByErrors,
      completed: collectionParcourue,
      aRevoir: review.toJSON(),
    };

    // Curseur remis au début quand tout est passé ; compte rendu posé à côté,
    // relu par l'écran à l'ouverture.
    await setBackfillCursor({
      db,
      docId: RECIPE_PROTEIN_CHECKPOINT_DOC_ID,
      lastDocId: collectionParcourue ? null : cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
      lastReport: { ...response },
    });

    await logInfo({
      message: "Protéine et féculent des plats — rattrapage",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      extra: { ...withoutReviewList(response), maxMinutes, maxRecipes },
    });

    return response;
  },
);
