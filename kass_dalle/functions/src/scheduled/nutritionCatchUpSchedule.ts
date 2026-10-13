/**
 * Rattrapage de la nutrition : la passe et ses règles de décision.
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
 * Deux entrées, une seule mécanique (`runNutritionBackfillPass`,
 * `callable/nutritionBackfillCallable.ts`) :
 *
 *  - le passage programmé — `scheduledBackfills`, tous les jours à 5 h par
 *    défaut, réglable dans Admin › Backfills — vingt recettes au plus, bornes
 *    de patience actives. Personne ne l'a demandé à cet instant, il ne doit
 *    donc surprendre personne. Il remplace `scheduledNutritionCatchUp`,
 *    retirée en v0.23.45 ;
 *  - `backfillNutritionFn` — un administrateur qui vient de corriger un
 *    référentiel veut le résultat maintenant : les bornes de patience sautent,
 *    celle de prudence reste.
 *
 * La passe écrit sur les recettes qu'elle reprend, donc elle réveille
 * `onRecipeWritten` — qui rend la main aussitôt, aucune entrée n'ayant bougé.
 * C'est la garde sur les entrées qui rend ce rattrapage possible : sans elle,
 * il aurait relancé la salve à lui seul.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_RECIPES } from "../config";
import { logError } from "../logging";
import { BudgetExceededError, assertWithinDailyBudget, recipeBudgetUserId } from "../ai/budget";
import { ENRICHMENT_RETRY_AFTER_MS, readTimestampMillis } from "../nutrition/aiEnrichment";
import type { MissingWeightCause } from "../nutrition/recipeNutrition";
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
 *
 * Égal au délai de relance de l'enrichissement (`ENRICHMENT_RETRY_AFTER_MS`) :
 * les marques d'essai des ingrédients et des unités sont écrites pendant le
 * calcul, donc juste avant l'instantané. Un instantané assez vieux pour être
 * repris garantit des marques assez vieilles pour que la reprise puisse
 * redemander au modèle. Avec vingt-quatre heures d'un côté et vingt de
 * l'autre, une reprise sur deux ne posait aucune question et consommait quand
 * même une tentative.
 */
export const MIN_SNAPSHOT_AGE_MS = ENRICHMENT_RETRY_AFTER_MS;

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
 * Causes d'une ligne sans poids qu'une reprise ne peut pas combler. La
 * reprise ne demande ni une quantité que la recette n'écrit pas lisiblement,
 * ni le poids d'une pièce. Le poids d'une unité, elle le demanderait, mais
 * sous la garde de vingt heures d'`enrichUnknownUnitsWithAI`, et c'est le
 * backfill « Enrichir unités et ingrédients » qui en porte la charge — avec sa
 * mémoire des échecs. Une ligne sans quantité ni unité (`quantite_absente`)
 * reste reprenable : la reprise demande sa portion usuelle au modèle.
 */
const UNFIXABLE_BY_CATCH_UP: ReadonlySet<string> = new Set<MissingWeightCause>([
  "quantite_illisible",
  "comptage_sans_poids",
  "unite_sans_poids",
]);

/** Vrai quand l'instantané laisse quelque chose à calculer. */
export function nutritionIsIncomplete(nutrition: unknown): boolean {
  if (!nutrition || typeof nutrition !== "object") return true;
  const n = nutrition as Record<string, unknown>;
  if (n.coverage_state === "failed") return true;
  return Array.isArray(n.missing_ingredients) && n.missing_ingredients.length > 0;
}

/** Les lignes sans poids d'un instantané (`missing_weight`), lues prudemment. */
export function readMissingWeight(nutrition: unknown): { name: string; cause: string }[] {
  if (!nutrition || typeof nutrition !== "object") return [];
  const raw = (nutrition as Record<string, unknown>).missing_weight;
  if (!Array.isArray(raw)) return [];
  const out: { name: string; cause: string }[] = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") continue;
    const r = item as Record<string, unknown>;
    if (typeof r.name !== "string" || typeof r.cause !== "string") continue;
    out.push({ name: r.name, cause: r.cause });
  }
  return out;
}

/**
 * Les ingrédients pesés sans valeurs pour 100 g (`missing_profile`), ou
 * `null` sur un instantané antérieur au champ.
 */
export function readMissingProfile(nutrition: unknown): string[] | null {
  if (!nutrition || typeof nutrition !== "object") return null;
  const raw = (nutrition as Record<string, unknown>).missing_profile;
  if (!Array.isArray(raw)) return null;
  return raw.filter((n): n is string => typeof n === "string");
}

/**
 * Parmi les ingrédients sans valeurs, ceux que plus rien ne redemande au
 * modèle (`missing_profile_excluded` : trois échecs au backfill « Enrichir
 * unités et ingrédients »). Vide sur un instantané antérieur au champ.
 */
export function readMissingProfileExcluded(nutrition: unknown): string[] {
  if (!nutrition || typeof nutrition !== "object") return [];
  const raw = (nutrition as Record<string, unknown>).missing_profile_excluded;
  if (!Array.isArray(raw)) return [];
  return raw.filter((n): n is string => typeof n === "string");
}

/**
 * Vrai quand aucun manque de l'instantané ne peut être comblé par une
 * reprise : aucun calcul en échec, chaque ligne sans poids d'une cause de
 * `UNFIXABLE_BY_CATCH_UP`, et chaque ingrédient sans valeurs exclu après
 * trois échecs (`missing_profile_excluded`) — l'enrichissement de la reprise
 * ne le redemande plus.
 *
 * Un instantané antérieur à `missing_weight` / `missing_profile` ne permet
 * pas de le dire : il reste reprenable, et la reprise l'écrit au format
 * actuel.
 */
export function nothingLeftToAsk(nutrition: unknown): boolean {
  if (!nutrition || typeof nutrition !== "object") return false;
  if ((nutrition as Record<string, unknown>).coverage_state === "failed") return false;
  const profile = readMissingProfile(nutrition);
  if (profile == null) return false;
  const excluded = new Set(readMissingProfileExcluded(nutrition));
  if (!profile.every((name) => excluded.has(name))) return false;
  const weight = readMissingWeight(nutrition);
  if (weight.length === 0 && profile.length === 0) return false;
  return weight.every((w) => UNFIXABLE_BY_CATCH_UP.has(w.cause));
}

/**
 * Ce que le rattrapage fait d'une recette :
 *
 *  - `reprendre` : elle repart dans la chaîne nutrition ;
 *  - `ignorer` : rien à faire — ce n'est pas une recette, elle est complète,
 *    elle vient d'être écrite, ou elle a été calculée il y a moins de vingt
 *    heures ;
 *  - `abandonnee` : incomplète, mais ses `MAX_CATCH_UP_ATTEMPTS` tentatives
 *    sont consommées. Elle n'est plus reprise, et le compte rendu la nomme ;
 *  - `non_reprenable` : incomplète, mais rien de ce qui manque ne peut venir
 *    d'une reprise — lignes impossibles à peser, ingrédients que le modèle a
 *    manqués trois fois (`nothingLeftToAsk`). Un appel n'y changerait rien :
 *    elle n'est pas reprise, et le compte rendu la nomme avec la cause.
 */
export type CatchUpDecision = "reprendre" | "ignorer" | "abandonnee" | "non_reprenable";

/**
 * Décision du rattrapage pour une recette. Fonction pure, testée seule.
 *
 * `forced` lève les bornes de PATIENCE — l'âge de l'instantané, le nombre de
 * tentatives et l'exclusion du non-reprenable. Elles n'ont de sens que pour un
 * passage automatique que personne n'a demandé. Un administrateur qui vient de
 * corriger un référentiel — un poids à la pièce, le poids d'une unité — sait,
 * lui, pourquoi il redemande. La borne de PRUDENCE, elle, reste : on ne double
 * jamais une chaîne en cours.
 */
export function catchUpDecision(
  candidate: CatchUpCandidate,
  nowMs: number,
  forced = false,
): CatchUpDecision {
  if (candidate.pageType !== "recipe") return "ignorer";

  // Écrite à l'instant : le déclencheur travaille peut-être encore.
  if (candidate.updatedAtMs != null && nowMs - candidate.updatedAtMs < RECENT_WRITE_GRACE_MS) {
    return "ignorer";
  }

  const nutrition = candidate.nutrition;
  if (!nutritionIsIncomplete(nutrition)) return "ignorer";
  if (forced) return "reprendre";

  if (candidate.catchUpAttempts >= MAX_CATCH_UP_ATTEMPTS) return "abandonnee";

  // Jamais calculée. Pas d'instantané, donc pas d'âge à comparer : on reprend.
  if (!nutrition || typeof nutrition !== "object") return "reprendre";

  // Calculée il y a moins de vingt heures : le passage d'hier, ou le
  // déclencheur. Les marques d'essai de l'enrichissement sont aussi récentes :
  // une reprise ne pourrait rien redemander.
  const computedAtMs = readTimestampMillis(nutrition.computed_at);
  if (computedAtMs != null && nowMs - computedAtMs < MIN_SNAPSHOT_AGE_MS) return "ignorer";

  if (nothingLeftToAsk(nutrition)) return "non_reprenable";
  return "reprendre";
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
  /**
   * Appelé pour chaque recette reprise qui reste incomplète : le backfill à
   * la demande en fait sa liste « à revoir ».
   */
  onStillIncomplete?: (recipe: StillIncompleteRecipe) => void;
}

/** Recette reprise dont la nutrition reste incomplète. */
export interface StillIncompleteRecipe {
  id: string;
  data: Record<string, unknown>;
  /** Instantané relu après la reprise, `null` s'il n'existe pas. */
  nutrition: Record<string, unknown> | null;
  /** Message de l'erreur levée par la reprise, `null` sans erreur. */
  error: string | null;
  /**
   * Pourquoi elle est listée : `reprise` (reprise, toujours incomplète),
   * `abandonnee` (tentatives consommées, non reprise), `non_reprenable` (non
   * reprise : rien de ce qui manque ne peut venir d'une reprise).
   */
  status: "reprise" | "abandonnee" | "non_reprenable";
}

/** Ce qu'un passage a fait, et pourquoi il s'est arrêté. */
export interface NutritionCatchUpReport {
  examinees: number;
  reprises: number;
  completees: number;
  echouees: number;
  /** Candidates vues mais non reprises : plafond, échéance ou budget. */
  laissees: number;
  /** Incomplètes, non reprises : leurs tentatives sont consommées. */
  abandonnees: number;
  /** Incomplètes, non reprises : seules des lignes impossibles à peser manquent. */
  nonReprenables: number;
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
    abandonnees: 0,
    nonReprenables: 0,
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
      const decision = catchUpDecision(candidate, nowMs, forced);
      if (decision === "abandonnee" || decision === "non_reprenable") {
        // Non reprise, mais nommée : une recette qui disparaît du compte
        // rendu se lit comme une recette complète.
        if (decision === "abandonnee") report.abandonnees += 1;
        else report.nonReprenables += 1;
        options.onStillIncomplete?.({
          id: doc.id,
          data,
          nutrition: candidate.nutrition ?? null,
          error: null,
          status: decision,
        });
        continue;
      }
      if (decision !== "reprendre") continue;

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

      let syncError: string | null = null;
      try {
        await syncRecipeNutrition({
          after: doc,
          data,
          cause: forced ? "backfill-demande" : "rattrapage-planifie",
          correlationId: options.correlationId,
        });
      } catch (err) {
        syncError = err instanceof Error ? err.message : String(err);
        await logError({
          message: "rattrapageNutrition: reprise en échec",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "DESIGN",
          correlationId: options.correlationId,
          extra: { recipeId: doc.id },
        });
      }

      // Relecture : la reprise a-t-elle abouti ? C'est elle qui décide si le
      // compteur repart de zéro ou monte d'un cran. On juge la complétude
      // seule : une recette devenue non reprenable reste incomplète, et son
      // compteur monte.
      const apres = await doc.ref.get();
      const nutrition = (apres.data()?.nutrition ?? null) as Record<string, unknown> | null;
      const encoreIncomplete = nutritionIsIncomplete(nutrition);

      if (encoreIncomplete) {
        report.echouees += 1;
        options.onStillIncomplete?.({
          id: doc.id,
          data,
          nutrition,
          error: syncError,
          status: "reprise",
        });
      } else {
        report.completees += 1;
      }

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
