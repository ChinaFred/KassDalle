/**
 * Rattrapage de la nutrition : la passe, et ses deux entrées.
 *
 * `onRecipeWritten` calcule une fois par changement d'entrée, et c'est tout ce
 * qu'il doit faire : sa garde porte sur ses entrées, précisément pour qu'il
 * cesse de se réveiller lui-même. Un calcul qui échoue n'est donc plus repris
 * par l'écriture suivante — et c'est tant mieux, c'était le mécanisme qui
 * produisait 499 réveils pour 68 recettes en août.
 *
 * Reste qu'un échec doit être repris. C'est ce que fait cette passe, et sa
 * forme dit tout : un rattrapage est une décision, pas l'effet de bord d'une
 * écriture sans rapport.
 *
 * Deux entrées, une seule mécanique :
 *
 *  - `scheduledNutritionCatchUp` — tous les jours à 5 h, vingt recettes au
 *    plus, bornes de prudence actives. Personne ne l'a demandé, il ne doit donc
 *    surprendre personne.
 *  - `backfillNutritionFn` (voir `callable/nutritionBackfillCallable.ts`) — un
 *    administrateur qui vient de corriger un référentiel veut le résultat
 *    maintenant : les bornes de patience sautent, celle de prudence reste.
 *
 * La passe écrit sur les recettes qu'elle reprend, donc elle réveille
 * `onRecipeWritten` — qui rend la main aussitôt, aucune entrée n'ayant bougé.
 * C'est la garde sur les entrées qui rend ce rattrapage possible : sans elle,
 * il aurait relancé la salve à lui seul.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore } from "firebase-admin/firestore";

import { ANTHROPIC_API_KEY, COLL_RECIPES, GEMINI_API_KEY, REGION } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { BudgetExceededError, assertWithinDailyBudget, recipeBudgetUserId } from "../ai/budget";
import { readTimestampMillis } from "../nutrition/aiEnrichment";
import { resolvePageType } from "../triggers/recipeWritten";
import { syncRecipeNutrition } from "../triggers/recipeNutritionAutoSync";

/** Poste sous lequel le plafond de dépense est consulté. */
const BUDGET_FEATURE = "rattrapage_nutrition";

/**
 * Recettes reprises au plus par passage planifié.
 *
 * La collection en compte quelques centaines : les parcourir toutes coûte des
 * lectures négligeables. Ce qui coûte, ce sont les appels de modèle des
 * recettes REPRISES — d'où un plafond sur celles-là, et sur elles seules.
 */
export const MAX_RECIPES_PER_RUN = 20;

/**
 * Tentatives de rattrapage accordées à une même liste d'ingrédients.
 *
 * Sans ce plafond, une recette qu'aucun rattrapage ne peut compléter — un
 * ingrédient que le modèle ne sait pas estimer, une unité qu'il ne sait pas
 * peser — coûterait quelques appels chaque jour, indéfiniment. Le compteur
 * repart de zéro dans `syncRecipeNutrition` dès qu'un vrai changement d'entrée
 * relance le calcul : une liste modifiée mérite ses propres tentatives.
 */
export const MAX_CATCH_UP_ATTEMPTS = 5;

/**
 * Âge minimal d'un instantané avant de le reprendre.
 *
 * Vingt heures, pour un balayage quotidien : une recette calculée par le
 * passage d'hier est reprise par celui de demain, jamais deux fois le même
 * jour.
 */
export const MIN_SNAPSHOT_AGE_MS = 20 * 60 * 60 * 1000;

/**
 * Délai de grâce après une écriture de recette.
 *
 * Une recette écrite il y a trente secondes est peut-être en cours de calcul :
 * son instantané n'existe pas encore, et la reprendre lancerait une seconde
 * chaîne en parallèle de la première — exactement ce que la garde du
 * déclencheur a supprimé. Le déclencheur a 300 s pour finir ; on lui en laisse
 * six fois plus.
 *
 * Cette borne-là ne saute JAMAIS, backfill compris : elle ne protège pas d'une
 * impatience, elle protège de la salve.
 */
export const RECENT_WRITE_GRACE_MS = 30 * 60 * 1000;

/** Ce qu'on sait d'une recette au moment de décider de la reprendre. */
export interface CatchUpCandidate {
  pageType: string;
  /** Instantané nutritionnel, absent quand aucun calcul n'a jamais abouti. */
  nutrition: Record<string, unknown> | null | undefined;
  catchUpAttempts: number;
  /** Dernière écriture de la recette, en millisecondes. */
  updatedAtMs: number | null;
}

/**
 * Cette recette doit-elle être reprise ? Fonction pure, testée seule.
 *
 * Trois raisons de reprendre : aucun instantané, un instantané d'échec, une
 * couverture incomplète. Trois raisons de s'abstenir : ce n'est pas une
 * recette, elle vient d'être écrite, ou elle a déjà consommé ses tentatives.
 *
 * `forced` lève les deux bornes de PATIENCE — l'âge de l'instantané et le
 * nombre de tentatives. Elles n'ont de sens que pour un passage automatique
 * que personne n'a demandé. Un administrateur qui vient de corriger un
 * référentiel sait, lui, pourquoi il redemande. La borne de PRUDENCE, elle,
 * reste : on ne double jamais une chaîne en cours.
 */
export function needsNutritionCatchUp(
  candidate: CatchUpCandidate,
  nowMs: number,
  forced = false,
): boolean {
  if (candidate.pageType !== "recipe") return false;
  if (!forced && candidate.catchUpAttempts >= MAX_CATCH_UP_ATTEMPTS) return false;

  // Écrite à l'instant : le déclencheur travaille peut-être encore.
  if (candidate.updatedAtMs != null && nowMs - candidate.updatedAtMs < RECENT_WRITE_GRACE_MS) {
    return false;
  }

  const nutrition = candidate.nutrition;
  // Jamais calculée. Pas d'instantané, donc pas d'âge à comparer : on reprend.
  if (!nutrition || typeof nutrition !== "object") return true;

  // Calculée il y a moins de vingt heures : le passage d'hier, ou le
  // déclencheur. Rien de neuf ne peut être arrivé au référentiel entre-temps.
  if (!forced) {
    const computedAtMs = readTimestampMillis(nutrition.computed_at);
    if (computedAtMs != null && nowMs - computedAtMs < MIN_SNAPSHOT_AGE_MS) return false;
  }

  if (nutrition.coverage_state === "failed") return true;

  const missing = nutrition.missing_ingredients;
  return Array.isArray(missing) && missing.length > 0;
}

/** Ce qu'un passage de rattrapage a le droit de faire. */
export interface NutritionCatchUpOptions {
  correlationId: string;
  /** Recettes REPRISES au plus. Les lectures, elles, ne sont pas bornées. */
  maxRecipes: number;
  /** Instant au-delà duquel on s'arrête proprement. */
  deadlineMs: number;
  /** Lève les bornes de patience — réservé à une demande explicite. */
  forced?: boolean;
  /** Reprendre le parcours après cette recette. */
  startAfterId?: string | null;
}

/** Ce qu'un passage a fait, et pourquoi il s'est arrêté. */
export interface NutritionCatchUpReport {
  examinees: number;
  reprises: number;
  completees: number;
  echouees: number;
  /** Candidates vues mais non reprises : plafond, échéance ou budget. */
  laissees: number;
  /** Dernière recette REPRISE — le curseur du prochain passage. */
  lastProcessedId: string | null;
  /** Vrai quand le parcours a atteint la fin de la collection. */
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
}

/** Taille d'une page de lecture. La collection tient en une ou deux. */
const PAGE = 200;

/**
 * Un passage de rattrapage, quelle que soit son entrée.
 *
 * Le parcours continue même après le plafond atteint : c'est ce qui permet de
 * dire combien de recettes restent à reprendre. Un plafond silencieux se lit
 * comme « tout a été repris ».
 */
export async function runNutritionCatchUp(
  options: NutritionCatchUpOptions,
): Promise<NutritionCatchUpReport> {
  const db = getFirestore();
  const nowMs = Date.now();
  const forced = options.forced === true;

  const report: NutritionCatchUpReport = {
    examinees: 0,
    reprises: 0,
    completees: 0,
    echouees: 0,
    laissees: 0,
    lastProcessedId: null,
    collectionParcourue: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
  };

  let cursor = options.startAfterId ?? null;

  parcours: for (;;) {
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      report.collectionParcourue = true;
      break;
    }

    for (const doc of page.docs) {
      cursor = doc.id;
      report.examinees += 1;

      const data = doc.data() as Record<string, unknown>;
      const candidate: CatchUpCandidate = {
        pageType: resolvePageType(data),
        nutrition: data.nutrition as Record<string, unknown> | undefined,
        catchUpAttempts: Number(data.nutrition_catch_up_attempts ?? 0) || 0,
        updatedAtMs: readTimestampMillis(data.updated_at),
      };
      if (!needsNutritionCatchUp(candidate, nowMs, forced)) continue;

      if (report.reprises >= options.maxRecipes) {
        report.laissees += 1;
        continue;
      }
      if (Date.now() >= options.deadlineMs) {
        report.stoppedByDeadline = true;
        report.laissees += 1;
        break parcours;
      }

      // Le plafond de dépense se consulte AVANT l'appel, pas après : passé le
      // plafond, la chaîne échouerait recette après recette et chacune
      // repartirait marquée « encore incomplète », ce qui est faux — elle n'a
      // pas été tentée, elle a été refusée.
      // Même compte que celui que `syncRecipeNutrition` imputera.
      const userId = recipeBudgetUserId(data.created_by);
      try {
        await assertWithinDailyBudget(userId, BUDGET_FEATURE);
      } catch (err) {
        if (err instanceof BudgetExceededError) {
          report.stoppedByBudget = true;
          report.laissees += 1;
          break parcours;
        }
        throw err;
      }

      const attempts = candidate.catchUpAttempts;
      report.reprises += 1;
      report.lastProcessedId = doc.id;

      try {
        await syncRecipeNutrition({
          after: doc,
          data,
          cause: forced ? "backfill-demande" : "rattrapage-planifie",
          correlationId: options.correlationId,
        });
      } catch (err) {
        await logError({
          message: "rattrapageNutrition: reprise en échec",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "DESIGN",
          correlationId: options.correlationId,
          extra: { recipeId: doc.id },
        });
      }

      // Relecture : la reprise a-t-elle abouti ? C'est elle qui décide si le
      // compteur repart de zéro ou monte d'un cran. L'instant passé est
      // volontairement lointain, et `forced` faux — on juge la complétude, pas
      // la fraîcheur ni la patience.
      const apres = await doc.ref.get();
      const nutrition = (apres.data()?.nutrition ?? null) as Record<string, unknown> | null;
      const encoreIncomplete = needsNutritionCatchUp(
        { pageType: "recipe", nutrition, catchUpAttempts: 0, updatedAtMs: null },
        Number.MAX_SAFE_INTEGER,
      );

      if (encoreIncomplete) report.echouees += 1;
      else report.completees += 1;

      await doc.ref.set(
        { nutrition_catch_up_attempts: encoreIncomplete ? attempts + 1 : 0 },
        { merge: true },
      );
    }

    if (page.size < PAGE) {
      report.collectionParcourue = true;
      break;
    }
  }

  return report;
}

export const scheduledNutritionCatchUp = onSchedule(
  {
    // Tous les jours à 5 h, heure de Paris : avant l'alerte de dépense de 7 h,
    // pour que ce qu'il consomme soit déjà compté quand elle regarde.
    schedule: "0 5 * * *",
    timeZone: "Europe/Paris",
    region: REGION,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    memory: "512MiB",
    timeoutSeconds: 540,
    retryCount: 0,
  },
  async () => {
    // Un seul fil pour tout le passage : l'écran de journaux montre alors le
    // rattrapage comme un traitement, et non comme vingt traitements anonymes.
    const correlationId = newCorrelationId("rattrapage_nutrition");

    try {
      const report = await runNutritionCatchUp({
        correlationId,
        maxRecipes: MAX_RECIPES_PER_RUN,
        // On s'arrête avant le délai de la fonction : une reprise coupée en
        // plein milieu laisse une recette dans un état qu'il faudra reprendre.
        deadlineMs: Date.now() + 8 * 60 * 1000,
      });

      await logInfo({
        message:
          "rattrapageNutrition: " +
          report.completees +
          " complétée(s), " +
          report.echouees +
          " encore incomplète(s), " +
          report.laissees +
          " laissée(s) pour demain",
        moduleType: "DESIGN",
        correlationId,
        extra: { ...report },
      });
    } catch (err) {
      await logError({
        message: "rattrapageNutrition: passage interrompu",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        correlationId,
      });
    }
  },
);
