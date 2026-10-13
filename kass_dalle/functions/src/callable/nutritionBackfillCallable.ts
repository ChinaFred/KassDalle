/**
 * Rattrapage de nutrition : le passage manuel, et le passage programmé.
 *
 * Le passage programmé (`scheduledBackfills`, tous les jours à 5 h par défaut)
 * suffit au quotidien. Il ne suffit pas quand un administrateur vient de
 * corriger un référentiel : il veut voir l'effet, pas l'attendre jusqu'au
 * lendemain. Cette callable est cette porte-là.
 *
 * Les deux appellent la même passe (`runNutritionBackfillPass`, puis
 * `runNutritionCatchUp`) ; le passage manuel a deux différences assumées :
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
import { logError, logInfo } from "../logging";
import {
  MAX_CATCH_UP_ATTEMPTS,
  readMissingProfile,
  readMissingWeight,
  runNutritionCatchUp,
  type StillIncompleteRecipe,
} from "../scheduled/nutritionCatchUpSchedule";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  namesList,
  recipeReviewLabel,
  shortErrorMessage,
  type BackfillReviewItem,
  type BackfillReviewList,
} from "./_backfillReview";

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
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillNutritionResponse {
  examinees: number;
  reprises: number;
  completees: number;
  /** Reprises et toujours incomplètes : le passage est « incomplet ». */
  echouees: number;
  /** Candidates laissées faute de temps, de nombre ou de plafond : reprise due. */
  laissees: number;
  /** Non reprises : leurs cinq tentatives sont consommées. */
  abandonnees: number;
  /** Non reprises : seules des lignes impossibles à peser manquent. */
  impesables: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  /**
   * Vrai quand le parcours est fini : collection entière, aucune candidate
   * laissée. Le curseur est remis au début. Ne dit pas que tout est complet :
   * `echouees` le dit.
   */
  completed: boolean;
  /**
   * Recettes incomplètes, nommées, avec la cause : reprises sans succès,
   * abandonnées, impossibles à peser.
   */
  aRevoir: BackfillReviewList;
}

/** Libellé d'une cause de ligne sans poids (`MissingWeightCause`). */
const MISSING_WEIGHT_LABELS: Record<string, string> = {
  quantite_illisible: "quantité illisible",
  quantite_absente: "quantité absente",
  comptage_sans_poids: "pas de poids à la pièce",
  unite_sans_poids: "unité sans poids",
};

/** Début des avertissements écrits par `persistFailedNutritionSnapshot`. */
const FAILED_SNAPSHOT_PREFIX = "Le calcul nutritionnel n'a pas abouti : ";

/**
 * Raison écrite dans un instantané d'échec (`quality.warnings`), sans le
 * début commun à tous ; `null` quand il n'en porte pas.
 */
export function failedSnapshotReason(nutrition: Record<string, unknown>): string | null {
  const quality = nutrition.quality;
  if (!quality || typeof quality !== "object") return null;
  const warnings = (quality as Record<string, unknown>).warnings;
  if (!Array.isArray(warnings)) return null;
  const first = warnings.find((w): w is string => typeof w === "string" && w.trim().length > 0);
  if (!first) return null;
  const text = first.startsWith(FAILED_SNAPSHOT_PREFIX)
    ? first.slice(FAILED_SNAPSHOT_PREFIX.length)
    : first;
  return text.trim().length > 0 ? shortErrorMessage(text) : null;
}

/**
 * Ce qui manque à un instantané, cause par cause : les lignes impossibles à
 * peser, avec la leur, puis les ingrédients sans valeurs pour 100 g. Un
 * instantané antérieur à ces deux champs ne sépare pas les causes : il cite
 * `missing_ingredients` tel quel.
 */
export function missingCausesText(nutrition: Record<string, unknown>): string {
  const weight = readMissingWeight(nutrition);
  const profile = readMissingProfile(nutrition);
  if (profile == null && weight.length === 0) {
    const missing = Array.isArray(nutrition.missing_ingredients)
      ? nutrition.missing_ingredients.filter((n): n is string => typeof n === "string")
      : [];
    return missing.length > 0
      ? `Ingrédients non comptés : ${namesList(missing)}`
      : "Ingrédients non comptés";
  }
  const parts: string[] = [];
  if (weight.length > 0) {
    const lines = weight.map((w) => `${w.name} (${MISSING_WEIGHT_LABELS[w.cause] ?? w.cause})`);
    parts.push(`Impossible à peser : ${namesList(lines)}`);
  }
  if (profile != null && profile.length > 0) {
    parts.push(`Sans valeurs pour 100 g : ${namesList(profile)}`);
  }
  return parts.length > 0 ? parts.join(" · ") : "Ingrédients non comptés";
}

/**
 * Ligne « à revoir » d'une recette dont la nutrition reste incomplète : après
 * une reprise (l'erreur levée, un calcul en échec et sa raison, ou ce qui
 * manque, cause par cause), abandonnée après ses tentatives, ou impossible à
 * peser.
 */
export function nutritionReviewItem(recipe: StillIncompleteRecipe): BackfillReviewItem {
  const label = recipeReviewLabel(recipe.id, recipe.data);
  const item = (reason: string): BackfillReviewItem => ({
    kind: "recipe",
    id: recipe.id,
    label,
    reason:
      recipe.status === "abandonnee"
        ? `Abandonnée après ${MAX_CATCH_UP_ATTEMPTS} reprises — ${reason}`
        : reason,
  });
  if (recipe.error != null) {
    return item(`Reprise en échec : ${shortErrorMessage(recipe.error)}`);
  }
  const nutrition = recipe.nutrition;
  if (!nutrition) return item("Nutrition non calculée");
  if (nutrition.coverage_state === "failed") {
    const why = failedSnapshotReason(nutrition);
    return item(why ? `Calcul de nutrition en échec : ${why}` : "Calcul de nutrition en échec");
  }
  return item(missingCausesText(nutrition));
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
  async (req) => {
    const ctx = await requireAdmin(req, "backfill_nutrition");

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8.5);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(2, Math.min(8.8, maxMinutesRaw))
      : 8.5;
    const maxRecipesRaw = Number(req.data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
    const maxRecipes = Number.isFinite(maxRecipesRaw)
      ? Math.max(1, Math.min(200, Math.trunc(maxRecipesRaw)))
      : DEFAULT_MAX_RECIPES;
    const options: NutritionPassOptions = {
      origin: "manuel",
      maxRecipes,
      deadlineMs: Date.now() + Math.floor(maxMinutes * 60_000),
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    };

    return runBackfillFromCallable({
      key: "nutrition",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runNutritionBackfillPass(ctx, options),
      summarize: summarizeNutrition,
    });
  },
);

/**
 * Ce qu'un passage a le droit de faire. L'origine décide des bornes :
 *
 *  - `manuel` : `forced` — les bornes de PATIENCE sautent — et point de reprise
 *    (`nutrition_catch_up_checkpoint`), quarante recettes par défaut ;
 *  - `programme` : bornes de patience actives, sans point de reprise, vingt
 *    recettes (`MAX_RECIPES_PER_RUN`) — le comportement de l'ancien passage
 *    de 5 h. Les recettes reprises sortent des candidates pour vingt heures :
 *    repartir du début à chaque passage avance quand même.
 *
 * Dans les deux cas le plafond de dépense est consulté recette par recette,
 * imputé à son propriétaire (`recipeBudgetUserId`) — la seule imputation
 * juste pour un calcul qui sert la recette de quelqu'un.
 */
export interface NutritionPassOptions {
  origin: "manuel" | "programme";
  maxRecipes: number;
  deadlineMs: number;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeNutrition(r: BackfillNutritionResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : r.collectionParcourue ? r.laissees : null,
    toReview: r.aRevoir.total,
    // Le plafond de dépense de la passe nutrition est celui du propriétaire de
    // chaque recette : `stoppedByBudget` dit qu'il a fermé la porte.
    spendCapHit: r.stoppedByBudget,
    // Reprises sans succès : le passage est « incomplet », sans reprise à
    // l'heure suivante. Elles reviennent au passage du lendemain, dans la
    // limite de leurs cinq tentatives. Abandonnées et impesables ne comptent
    // pas : aucun passage automatique ne les reprendra.
    unresolved: r.echouees,
  };
}

/** Un passage, manuel ou programmé. */
export async function runNutritionBackfillPass(
  ctx: { userId: string | null; correlationId: string },
  options: NutritionPassOptions,
): Promise<BackfillNutritionResponse> {
  const db = getFirestore();
  const { correlationId } = ctx;
  const adminUid = ctx.userId ?? undefined;
  const manual = options.origin === "manuel";

  const startAfterId = manual
    ? await getBackfillCursor({
        db,
        docId: NUTRITION_CATCH_UP_CHECKPOINT_DOC_ID,
        resumeFromCheckpoint: options.resumeFromCheckpoint,
        resetCheckpoint: options.resetCheckpoint,
      })
    : null;

  await logInfo({
    message: "backfillNutrition: démarrage",
    moduleType: "DESIGN",
    correlationId,
    extra: {
      adminUid,
      origin: options.origin,
      maxRecipes: options.maxRecipes,
      startAfterId,
      resetCheckpoint: options.resetCheckpoint,
    },
  });

  const review = new BackfillReview();
  try {
    const report = await runNutritionCatchUp({
      correlationId,
      maxRecipes: options.maxRecipes,
      deadlineMs: options.deadlineMs,
      forced: manual,
      startAfterId,
      onStillIncomplete: (recipe) => review.add(nutritionReviewItem(recipe)),
    });

    // Le curseur ne se remet au début que lorsqu'il ne reste RIEN : la
    // collection entière parcourue, et aucune candidate laissée en route.
    // Le remettre dès la fin du parcours ferait boucler un backfill qui a
    // encore du travail, sans que rien ne le dise.
    const completed = report.collectionParcourue && report.laissees === 0;
    if (manual) {
      await setBackfillCursor({
        db,
        docId: NUTRITION_CATCH_UP_CHECKPOINT_DOC_ID,
        lastDocId: completed ? null : report.lastProcessedId,
        operation: "backfill_nutrition",
        adminUid,
      });
    }

    await logInfo({
      message:
        "backfillNutrition: " +
        report.completees +
        " complétée(s), " +
        report.echouees +
        " encore incomplète(s), " +
        report.laissees +
        " laissée(s), " +
        report.abandonnees +
        " abandonnée(s), " +
        report.impesables +
        " impossible(s) à peser",
      moduleType: "DESIGN",
      correlationId,
      extra: {
        ...report,
        origin: options.origin,
        completed,
        adminUid,
        aRevoirTotal: review.toJSON().total,
      },
    });

    return {
      examinees: report.examinees,
      reprises: report.reprises,
      completees: report.completees,
      echouees: report.echouees,
      laissees: report.laissees,
      abandonnees: report.abandonnees,
      impesables: report.impesables,
      collectionParcourue: report.collectionParcourue,
      stoppedByDeadline: report.stoppedByDeadline,
      stoppedByBudget: report.stoppedByBudget,
      completed,
      aRevoir: review.toJSON(),
    };
  } catch (err) {
    await logError({
      message: "backfillNutrition: passage interrompu",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId,
      extra: { adminUid, origin: options.origin, startAfterId },
    });
    throw err;
  }
}
