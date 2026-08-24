/**
 * Rattrapage planifié de la nutrition.
 *
 * `onRecipeWritten` calcule une fois par changement d'entrée, et c'est tout ce
 * qu'il doit faire : sa garde porte sur ses entrées, précisément pour qu'il
 * cesse de se réveiller lui-même. Un calcul qui échoue n'est donc plus repris
 * par l'écriture suivante — et c'est tant mieux, c'était le mécanisme qui
 * produisait 499 réveils pour 68 recettes en août.
 *
 * Reste qu'un échec doit être repris. Ce balayage est cette reprise-là, et sa
 * forme dit tout : un rattrapage est une décision, pas l'effet de bord d'une
 * écriture sans rapport. Il tourne une fois par jour, à un rythme choisi, sur
 * un nombre de recettes borné, et il s'arrête quand il ne progresse plus.
 *
 * Il écrit sur les recettes qu'il reprend, donc il réveille `onRecipeWritten` —
 * qui rend la main aussitôt, puisque aucune entrée n'a bougé. C'est la garde
 * qui rend ce balayage possible : sans elle, il aurait relancé la salve.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore } from "firebase-admin/firestore";

import { ANTHROPIC_API_KEY, COLL_RECIPES, GEMINI_API_KEY, REGION } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { readTimestampMillis } from "../nutrition/aiEnrichment";
import { resolvePageType } from "../triggers/recipeWritten";
import { syncRecipeNutrition } from "../triggers/recipeNutritionAutoSync";

/**
 * Recettes reprises au plus par passage.
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
 */
export function needsNutritionCatchUp(candidate: CatchUpCandidate, nowMs: number): boolean {
  if (candidate.pageType !== "recipe") return false;
  if (candidate.catchUpAttempts >= MAX_CATCH_UP_ATTEMPTS) return false;

  // Écrite à l'instant : le déclencheur travaille peut-être encore.
  if (candidate.updatedAtMs != null && nowMs - candidate.updatedAtMs < RECENT_WRITE_GRACE_MS) {
    return false;
  }

  const nutrition = candidate.nutrition;
  // Jamais calculée. Pas d'instantané, donc pas d'âge à comparer : on reprend.
  if (!nutrition || typeof nutrition !== "object") return true;

  // Calculée il y a moins de vingt heures : le passage d'hier, ou le
  // déclencheur. Rien de neuf ne peut être arrivé au référentiel entre-temps.
  const computedAtMs = readTimestampMillis(nutrition.computed_at);
  if (computedAtMs != null && nowMs - computedAtMs < MIN_SNAPSHOT_AGE_MS) return false;

  if (nutrition.coverage_state === "failed") return true;

  const missing = nutrition.missing_ingredients;
  return Array.isArray(missing) && missing.length > 0;
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
    const db = getFirestore();
    const nowMs = Date.now();
    // Un seul fil pour tout le passage : l'écran de journaux montre alors le
    // rattrapage comme un traitement, et non comme vingt traitements anonymes.
    const correlationId = newCorrelationId("rattrapage_nutrition");
    // On s'arrête avant le délai de la fonction : une reprise coupée en plein
    // milieu laisse une recette dans un état qu'il faudra reprendre demain.
    const deadlineMs = nowMs + 8 * 60 * 1000;

    let examinees = 0;
    let reprises = 0;
    let completees = 0;
    let echouees = 0;
    let reportees = 0;

    try {
      const snapshot = await db.collection(COLL_RECIPES).get();
      examinees = snapshot.size;

      const candidates = snapshot.docs.filter((doc) => {
        const data = doc.data() as Record<string, unknown>;
        return needsNutritionCatchUp(
          {
            pageType: resolvePageType(data),
            nutrition: data.nutrition as Record<string, unknown> | undefined,
            catchUpAttempts: Number(data.nutrition_catch_up_attempts ?? 0) || 0,
            updatedAtMs: readTimestampMillis(data.updated_at),
          },
          nowMs,
        );
      });

      reportees = Math.max(0, candidates.length - MAX_RECIPES_PER_RUN);

      for (const doc of candidates.slice(0, MAX_RECIPES_PER_RUN)) {
        if (Date.now() >= deadlineMs) {
          // Le reste attend demain, et on le DIT : un plafond silencieux se lit
          // comme « tout a été repris ».
          reportees += 1;
          continue;
        }

        const data = doc.data() as Record<string, unknown>;
        const attempts = Number(data.nutrition_catch_up_attempts ?? 0) || 0;
        reprises += 1;

        try {
          await syncRecipeNutrition({
            after: doc,
            data,
            cause: "rattrapage-planifie",
            correlationId,
          });
        } catch (err) {
          await logError({
            message: "rattrapageNutrition: reprise en échec",
            errorDescription: err instanceof Error ? err.message : String(err),
            moduleType: "DESIGN",
            correlationId,
            extra: { recipeId: doc.id },
          });
        }

        // Relecture : la reprise a-t-elle abouti ? C'est elle qui décide si le
        // compteur repart de zéro ou monte d'un cran. L'instant passé est
        // volontairement lointain — on juge la complétude, pas la fraîcheur,
        // et l'instantané vient d'être réécrit.
        const apres = await doc.ref.get();
        const nutrition = (apres.data()?.nutrition ?? null) as Record<string, unknown> | null;
        const encoreIncomplete = needsNutritionCatchUp(
          { pageType: "recipe", nutrition, catchUpAttempts: 0, updatedAtMs: null },
          Number.MAX_SAFE_INTEGER,
        );

        if (encoreIncomplete) echouees += 1;
        else completees += 1;

        await doc.ref.set(
          { nutrition_catch_up_attempts: encoreIncomplete ? attempts + 1 : 0 },
          { merge: true },
        );
      }

      await logInfo({
        message:
          "rattrapageNutrition: " +
          completees +
          " recette(s) complétée(s), " +
          echouees +
          " encore incomplète(s), " +
          reportees +
          " reportée(s)",
        moduleType: "DESIGN",
        correlationId,
        extra: { examinees, reprises, completees, echouees, reportees },
      });
    } catch (err) {
      await logError({
        message: "rattrapageNutrition: passage interrompu",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        correlationId,
        extra: { examinees, reprises, completees, echouees, reportees },
      });
    }
  },
);
