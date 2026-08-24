/**
 * Rattrapage de nutrition à la demande.
 *
 * Le passage planifié de 5 h suffit au quotidien. Il ne suffit pas quand un
 * administrateur vient de corriger un référentiel : il veut voir l'effet, pas
 * l'attendre jusqu'au lendemain. Cette callable est cette porte-là.
 *
 * Elle appelle exactement la même passe (`runNutritionCatchUp`), avec deux
 * différences assumées :
 *
 *  - `forced` lève les bornes de PATIENCE — l'âge de l'instantané et le plafond
 *    de tentatives. Elles protègent d'une insistance automatique que personne
 *    n'a demandée ; ici, quelqu'un l'a demandée.
 *  - le curseur permet de reprendre là où l'appel précédent s'est arrêté. Un
 *    backfill ne tient pas dans le délai d'une fonction, et un backfill qui
 *    recommence du début à chaque appel ne finit jamais.
 *
 * La borne de PRUDENCE, elle, ne saute pas : on ne reprend jamais une recette
 * dont le déclencheur calcule peut-être encore. C'est ce qui a coûté 499
 * réveils en août.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { ANTHROPIC_API_KEY, GEMINI_API_KEY, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { runNutritionCatchUp } from "../scheduled/nutritionCatchUpSchedule";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient la dernière recette reprise. */
export const NUTRITION_CATCH_UP_CHECKPOINT_DOC_ID = "nutrition_catch_up_checkpoint";

/**
 * Reprises accordées par appel, par défaut.
 *
 * Quarante recettes tiennent largement dans les huit minutes utiles, et un
 * administrateur qui veut tout reprendre rappelle la fonction — c'est à cela
 * que sert le curseur.
 */
const DEFAULT_MAX_RECIPES = 40;

interface BackfillNutritionRequest {
  maxMinutes?: number;
  maxRecipes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

interface BackfillNutritionResponse {
  examinees: number;
  reprises: number;
  completees: number;
  echouees: number;
  laissees: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  /** Vrai quand plus rien n'attend : le curseur a été remis au début. */
  completed: boolean;
}

export const backfillNutritionFn = onCall<BackfillNutritionRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillNutritionResponse> => {
    await requireAdmin(req, "backfill_nutrition");

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8.5);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(2, Math.min(8.8, maxMinutesRaw))
      : 8.5;
    const maxRecipesRaw = Number(req.data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
    const maxRecipes = Number.isFinite(maxRecipesRaw)
      ? Math.max(1, Math.min(200, Math.trunc(maxRecipesRaw)))
      : DEFAULT_MAX_RECIPES;

    const resumeFromCheckpoint = parseBoolean(req.data?.resumeFromCheckpoint, true);
    const resetCheckpoint = parseBoolean(req.data?.resetCheckpoint, false);

    const db = getFirestore();
    const correlationId = newCorrelationId("backfill_nutrition");
    const adminUid = req.auth?.uid;

    const startAfterId = await getBackfillCursor({
      db,
      docId: NUTRITION_CATCH_UP_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint,
      resetCheckpoint,
    });

    await logInfo({
      message: "backfillNutrition: démarrage",
      moduleType: "DESIGN",
      correlationId,
      extra: { adminUid, maxMinutes, maxRecipes, startAfterId, resetCheckpoint },
    });

    try {
      const report = await runNutritionCatchUp({
        correlationId,
        maxRecipes,
        deadlineMs: Date.now() + Math.floor(maxMinutes * 60_000),
        forced: true,
        startAfterId,
      });

      // Le curseur ne se remet au début que lorsqu'il ne reste RIEN : la
      // collection entière parcourue, et aucune candidate laissée en route.
      // Le remettre dès la fin du parcours ferait boucler un backfill qui a
      // encore du travail, sans que rien ne le dise.
      const completed = report.collectionParcourue && report.laissees === 0;
      await setBackfillCursor({
        db,
        docId: NUTRITION_CATCH_UP_CHECKPOINT_DOC_ID,
        lastDocId: completed ? null : report.lastProcessedId,
        operation: "backfill_nutrition",
        adminUid,
      });

      await logInfo({
        message:
          "backfillNutrition: " +
          report.completees +
          " complétée(s), " +
          report.echouees +
          " encore incomplète(s), " +
          report.laissees +
          " laissée(s)",
        moduleType: "DESIGN",
        correlationId,
        extra: { ...report, completed, adminUid },
      });

      return {
        examinees: report.examinees,
        reprises: report.reprises,
        completees: report.completees,
        echouees: report.echouees,
        laissees: report.laissees,
        collectionParcourue: report.collectionParcourue,
        stoppedByDeadline: report.stoppedByDeadline,
        stoppedByBudget: report.stoppedByBudget,
        completed,
      };
    } catch (err) {
      await logError({
        message: "backfillNutrition: passage interrompu",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        correlationId,
        extra: { adminUid, startAfterId },
      });
      throw err;
    }
  },
);
