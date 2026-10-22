/**
 * `scheduledBackfills` — les passages programmés des backfills récurrents.
 *
 * Une seule tâche, toutes les heures, heure de Paris. À chaque tick, pour
 * chaque backfill récurrent (`backfills/registry.ts`) :
 *
 *  1. sa programmation est lue dans `app_config/backfill_schedules`. Le
 *     défaut (`DEFAULT_BACKFILL_SCHEDULES` : la nutrition, tous les jours à
 *     5 h — elle remplace `scheduledNutritionCatchUp`, retirée en v0.23.45)
 *     y est écrit au premier tick qui ne le trouve pas, pour que l'écran le
 *     lise au lieu d'en garder une copie ;
 *  2. l'auteur de la programmation doit être encore administrateur
 *     (`programmerBlocker`) : sinon, pas de passage, et l'état le dit ;
 *  3. il est lancé s'il est échu (`dueReason`) : jour et heure programmés, ou
 *     reprise d'un passage programmé resté incomplet ;
 *  4. les passages échus partent en séquence, chacun borné par ce qui reste
 *     du délai de la fonction. Ce qui ne tient pas est marqué à reprendre et
 *     part au tick suivant.
 *
 * Plafond de dépense. Un backfill qui appelle un modèle est imputé à
 * l'administrateur qui a enregistré la programmation (`programme_par_uid`) :
 * ses appels passent par `callModel` sous son uid, et le plafond est consulté
 * avant le passage puis relu s'il s'arrête avant la fin. C'est le plafond de
 * **base**, sans le multiplicateur du compte (fondateur ×100) :
 * `runWithBaseBudgetCap`. Plafond atteint : le
 * passage est « incomplet, arrêt par plafond », et la reprise attend le
 * prochain créneau, pas l'heure suivante. Exception assumée : la nutrition
 * impute chaque recette à son propriétaire (`recipeBudgetUserId`), comme
 * l'ancien passage de 5 h — le calcul sert la recette de quelqu'un.
 *
 * Cloud Tasks n'est pas utilisé : la mécanique du pipeline sert un job par
 * document, avec relances. Un backfill a déjà son point de reprise et son
 * verrou ; une tâche horaire qui reprend où le passage s'est arrêté suffit,
 * sans file à créer ni à surveiller.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { ANTHROPIC_API_KEY, COLL_APP_CONFIG, GEMINI_API_KEY, REGION } from "../config";
import { logError, logInfo, logWarn, newCorrelationId, qualify } from "../logging";
import { BudgetExceededError, assertWithinDailyBudget } from "../ai/budget";
import { runWithBaseBudgetCap } from "../ai/callOrigin";
import { isAdminAccount } from "../callable/_auth";
import { backfillDefinition, recurrentKeys, type BackfillKey } from "../backfills/registry";
import {
  BackfillBusyError,
  backfillRunDocId,
  markBackfillDeferred,
  readMillis,
  recordScheduledRunBlocked,
  recordSpendCapSkip,
  runBackfillPass,
} from "../backfills/runner";
import {
  BACKFILL_SCHEDULES_DOC_ID,
  dueReason,
  missingDefaultSchedules,
  programmerBlocker,
  effectiveSchedule,
  lockHeld,
  parisSlot,
  passStatus,
  slotMatches,
  type BackfillSchedule,
  type DueReason,
  type PassSummary,
  type RunStateForDue,
} from "../backfills/schedule";
import { MAX_RECIPES_PER_RUN } from "./nutritionCatchUpSchedule";
import {
  runNutritionBackfillPass,
  summarizeNutrition,
} from "../callable/nutritionBackfillCallable";
import {
  runEnrichReferentialsPass,
  summarizeEnrichReferentials,
} from "../callable/billingCallable";
import { runAllergensPass, summarizeAllergens } from "../callable/allergensBackfillCallable";
import { runRecipeRolesPass, summarizeRecipeRoles } from "../callable/recipeRolesBackfillCallable";
import { runShoppingPass, summarizeShopping } from "../callable/shoppingBackfillCallable";
import { runRetentionPass, summarizeRetention } from "../callable/retentionBackfillCallable";

const FUNCTION_TIMEOUT_SECONDS = 540;
/** Marge gardée sur le délai de la fonction pour écrire les états. */
const TICK_MARGIN_MS = 30_000;
/** Un passage ne part pas avec moins de trois minutes devant lui. */
const MIN_PASS_MS = 3 * 60_000;
/** Durée maximale d'un passage, comme depuis le callable. */
const MAX_PASS_MS = 8.5 * 60_000;

/**
 * Documents traités par passage programmé — les défauts des callables, sauf
 * la nutrition qui garde les vingt recettes de l'ancien passage de 5 h.
 */
const ROLES_PER_PASS = 40;
const ALLERGEN_INGREDIENTS_PER_PASS = 400;
const ALLERGEN_RECIPES_PER_PASS = 500;
const SHOPPING_RECIPES_PER_PASS = 500;
const RETENTION_REPORTS_PER_PASS = 5000;

/** Poste sous lequel le plafond est consulté avant un passage programmé. */
const BUDGET_FEATURES: Partial<Record<BackfillKey, string>> = {
  enrich_referentials: "backfill_enrich_referentials_per100g",
  allergens: "backfill_allergens",
  recipe_roles: "backfill_recipe_roles",
};

/** L'état d'un backfill, tel que la décision « échu » le lit. */
function runStateOf(data: Record<string, unknown> | undefined): RunStateForDue {
  return {
    enCours: data?.dernier_passage_statut === "en_cours",
    enCoursDepuisMs: readMillis(data?.en_cours_depuis),
    repriseDue: data?.reprise_due === true,
    dernierCreneau: typeof data?.dernier_creneau === "string" ? data.dernier_creneau : null,
  };
}

/** Faux si le plafond de dépense de [uid] est atteint pour [feature]. */
async function budgetOpen(uid: string, feature: string): Promise<boolean> {
  try {
    await assertWithinDailyBudget(uid, feature);
    return true;
  } catch (err) {
    if (err instanceof BudgetExceededError) return false;
    throw err;
  }
}

interface ScheduledPass {
  run: () => Promise<object>;
  summarize: (r: object) => PassSummary;
}

/** La passe d'un récurrent, bornée par [deadlineMs]. */
function scheduledPassFor(
  key: BackfillKey,
  uid: string | null,
  correlationId: string,
  deadlineMs: number,
  reason: DueReason,
): ScheduledPass | null {
  if (key === "nutrition") {
    return {
      run: () =>
        runNutritionBackfillPass(
          { userId: uid, correlationId },
          {
            origin: "programme",
            maxRecipes: MAX_RECIPES_PER_RUN,
            deadlineMs,
            resumeFromCheckpoint: false,
            resetCheckpoint: false,
          },
        ),
      summarize: (r) => summarizeNutrition(r as Parameters<typeof summarizeNutrition>[0]),
    };
  }
  // Les autres récurrents n'ont pas de défaut : leur programmation vient
  // toujours d'un administrateur, qui est le compte imputé.
  if (!uid) return null;
  const ctx = { userId: uid, correlationId };
  switch (key) {
    case "enrich_referentials":
      return {
        run: () =>
          runEnrichReferentialsPass(ctx, {
            deadlineMs,
            resumeFromCheckpoint: true,
            resetCheckpoint: false,
            refreshSodium: false,
            // Un passage programmé ne redemande jamais un élément exclu
            // après trois échecs : seul un administrateur le décide.
            retryExcluded: false,
            // Reprise à l'heure suivante : les unités viennent d'être
            // parcourues, seule la phase des ingrédients a un curseur.
            skipUnits: reason === "reprise",
          }),
        summarize: (r) =>
          summarizeEnrichReferentials(r as Parameters<typeof summarizeEnrichReferentials>[0]),
      };
    case "allergens":
      return {
        run: () =>
          runAllergensPass(ctx, {
            deadlineMs,
            maxIngredients: ALLERGEN_INGREDIENTS_PER_PASS,
            maxRecipes: ALLERGEN_RECIPES_PER_PASS,
            resumeFromCheckpoint: true,
            resetCheckpoint: false,
            retryExcluded: false,
          }),
        summarize: (r) => summarizeAllergens(r as Parameters<typeof summarizeAllergens>[0]),
      };
    case "recipe_roles":
      return {
        run: () =>
          runRecipeRolesPass(ctx, {
            deadlineMs,
            maxRecipes: ROLES_PER_PASS,
            force: false,
            retryExcluded: false,
            resumeFromCheckpoint: true,
            resetCheckpoint: false,
          }),
        summarize: (r) => summarizeRecipeRoles(r as Parameters<typeof summarizeRecipeRoles>[0]),
      };
    case "shopping_products":
      return {
        run: () =>
          runShoppingPass(ctx, {
            deadlineMs,
            maxDocs: SHOPPING_RECIPES_PER_PASS,
            resumeFromCheckpoint: true,
            resetCheckpoint: false,
          }),
        summarize: (r) => summarizeShopping(r as Parameters<typeof summarizeShopping>[0]),
      };
    case "retention":
      return {
        run: () => runRetentionPass(ctx, { deadlineMs, maxDocs: RETENTION_REPORTS_PER_PASS }),
        summarize: (r) => summarizeRetention(r as Parameters<typeof summarizeRetention>[0]),
      };
    default:
      return null;
  }
}

/** Lance un passage programmé ; ne lève pas, chaque issue est enregistrée ou journalisée. */
async function runScheduledBackfill(args: {
  key: BackfillKey;
  schedule: BackfillSchedule;
  creneau: string | null;
  reason: DueReason;
  deadlineMs: number;
}): Promise<void> {
  const { key, schedule, creneau } = args;
  const correlationId =
    key === "nutrition"
      ? newCorrelationId("rattrapage_nutrition")
      : newCorrelationId(qualify("backfill_programme", key));
  const uid = schedule.programmeParUid;

  // L'auteur doit être encore administrateur au moment du passage : un compte
  // rétrogradé ou révoqué ne voit plus de dépense imputée en son nom.
  const blocker = programmerBlocker(uid, uid != null && (await isAdminAccount(uid)));
  if (blocker) {
    await recordScheduledRunBlocked(key, creneau, correlationId, blocker);
    await logWarn({
      message: `Backfill programmé ${key} — passage refusé : ${blocker}`,
      correlationId,
      userId: uid ?? undefined,
      moduleType: "DESIGN",
      extra: { key, creneau },
    });
    return;
  }

  const pass = scheduledPassFor(key, uid, correlationId, args.deadlineMs, args.reason);
  if (!pass) {
    await logError({
      message: `Backfill programmé ${key} — aucun administrateur imputable, passage non lancé`,
      correlationId,
      moduleType: "DESIGN",
      extra: { key, creneau },
    });
    return;
  }

  try {
    const budgetFeature = BUDGET_FEATURES[key];
    let spendCapHit = false;
    if (budgetFeature && uid) {
      if (!(await budgetOpen(uid, budgetFeature))) {
        await recordSpendCapSkip(key, creneau, correlationId);
        await logWarn({
          message: `Backfill programmé ${key} — plafond de dépense atteint, passage reporté au prochain créneau`,
          correlationId,
          userId: uid,
          feature: budgetFeature,
          moduleType: "DESIGN",
          extra: { key, creneau },
        });
        return;
      }
    }

    const result = await runBackfillPass({
      key,
      origin: "programme",
      actorUid: uid,
      appVersion: null,
      correlationId,
      creneau,
      run: async () => {
        const response = await pass.run();
        // Arrêt avant la fin : le plafond s'est-il fermé en route ? Les
        // passes comptent alors des échecs, sans le dire.
        if (budgetFeature && uid && !pass.summarize(response).complete) {
          spendCapHit = !(await budgetOpen(uid, budgetFeature));
          if (spendCapHit) {
            await logWarn({
              message: `Backfill programmé ${key} — plafond de dépense atteint en cours de passage, reprise au prochain créneau`,
              correlationId,
              userId: uid,
              feature: budgetFeature,
              moduleType: "DESIGN",
              extra: { key, creneau },
            });
          }
        }
        return response;
      },
      summarize: (r) => {
        const summary = pass.summarize(r);
        return { ...summary, spendCapHit: summary.spendCapHit || spendCapHit };
      },
    });

    await logInfo({
      message: `Backfill programmé ${key} — ${passStatus(result.summary) === "termine" ? "terminé" : "incomplet"}`,
      correlationId,
      userId: uid ?? undefined,
      moduleType: "DESIGN",
      extra: { key, creneau, ...result.summary },
    });
  } catch (err) {
    if (err instanceof BackfillBusyError) {
      // Un passage manuel a pris le verrou entre la lecture et le départ :
      // celui-ci repart au tick suivant.
      await markBackfillDeferred(key, creneau);
      await logInfo({
        message: `Backfill programmé ${key} — passage en cours, reporté d'une heure`,
        correlationId,
        moduleType: "DESIGN",
        extra: { key, creneau },
      });
      return;
    }
    await logError({
      message: `Backfill programmé ${key} — passage en échec`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
      userId: uid ?? undefined,
      moduleType: "DESIGN",
      extra: { key, creneau },
    });
  }
}

/** Décide et lance, pour un backfill, ce que ce tick lui doit. */
async function tickBackfill(
  key: BackfillKey,
  tick: {
    schedulesDoc: Record<string, unknown> | undefined;
    runData: Record<string, unknown> | undefined;
    now: Date;
    tickDeadlineMs: number;
    correlationId: string;
  },
): Promise<void> {
  const { schedulesDoc, now, tickDeadlineMs, correlationId } = tick;
  const schedule = effectiveSchedule(key, schedulesDoc);
  if (schedule == null && schedulesDoc?.[key] !== undefined) {
    await logWarn({
      message: `Backfills programmés — programmation de ${key} illisible, ignorée`,
      correlationId,
      moduleType: "DESIGN",
      extra: { key },
    });
    return;
  }
  const run = runStateOf(tick.runData);
  const nowMs = Date.now();
  const reason = dueReason(schedule, run, now);
  if (!reason) {
    // Créneau tombé pendant un passage manuel : il repart l'heure suivante.
    if (schedule && lockHeld(run, nowMs) && slotMatches(schedule, run, now)) {
      await markBackfillDeferred(key, parisSlot(now).slot);
    }
    return;
  }
  const creneau = reason === "creneau" ? parisSlot(now).slot : null;
  const remainingMs = tickDeadlineMs - nowMs;
  if (remainingMs < MIN_PASS_MS) {
    await markBackfillDeferred(key, creneau);
    await logInfo({
      message: `Backfills programmés — ${key} ne tient plus dans ce tick, reporté d'une heure`,
      correlationId,
      moduleType: "DESIGN",
      extra: { key, reason },
    });
    return;
  }
  const def = backfillDefinition(key);
  await logInfo({
    message: `Backfills programmés — lancement de « ${def?.title ?? key} » (${reason})`,
    correlationId,
    moduleType: "DESIGN",
    extra: { key, reason, creneau },
  });
  const launch = () =>
    runScheduledBackfill({
      key,
      schedule: schedule as BackfillSchedule,
      creneau,
      reason,
      deadlineMs: Math.min(tickDeadlineMs, nowMs + MAX_PASS_MS),
    });
  // Plafond de base pour tout passage programmé imputé à son auteur. La
  // nutrition garde l'imputation par recette, multiplicateurs compris, comme
  // l'ancienne tâche de 5 h.
  await (key === "nutrition" ? launch() : runWithBaseBudgetCap(launch));
}

export const scheduledBackfills = onSchedule(
  {
    schedule: "0 * * * *",
    timeZone: "Europe/Paris",
    region: REGION,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    memory: "512MiB",
    timeoutSeconds: FUNCTION_TIMEOUT_SECONDS,
    retryCount: 0,
  },
  async () => {
    const startMs = Date.now();
    const tickDeadlineMs = startMs + FUNCTION_TIMEOUT_SECONDS * 1000 - TICK_MARGIN_MS;
    const now = new Date(startMs);
    const db = getFirestore();
    const correlationId = newCorrelationId("backfill_programme");

    let schedulesDoc: Record<string, unknown> | undefined;
    let runDocs: Map<string, Record<string, unknown> | undefined>;
    try {
      const keys = recurrentKeys();
      const [schedulesSnap, ...runSnaps] = await db.getAll(
        db.collection(COLL_APP_CONFIG).doc(BACKFILL_SCHEDULES_DOC_ID),
        ...keys.map((k) => db.collection(COLL_APP_CONFIG).doc(backfillRunDocId(k))),
      );
      schedulesDoc = schedulesSnap.data();
      runDocs = new Map(keys.map((k, i) => [k, runSnaps[i].data()]));
    } catch (err) {
      await logError({
        message: "Backfills programmés — lecture des programmations impossible, tick abandonné",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId,
        moduleType: "DESIGN",
      });
      return;
    }

    // Le défaut s'écrit à part : son échec est journalisé, et le tick continue
    // — `effectiveSchedule` applique de toute façon le défaut du registre.
    try {
      const seed = missingDefaultSchedules(schedulesDoc);
      if (Object.keys(seed).length > 0) {
        await db
          .collection(COLL_APP_CONFIG)
          .doc(BACKFILL_SCHEDULES_DOC_ID)
          .set(
            Object.fromEntries(
              Object.entries(seed).map(([k, sch]) => [
                k,
                {
                  enabled: sch.enabled,
                  days: sch.days,
                  hour: sch.hour,
                  timezone: "Europe/Paris",
                  programme_par_uid: null,
                  updated_at: FieldValue.serverTimestamp(),
                },
              ]),
            ),
            { merge: true },
          );
        await logInfo({
          message: "Backfills programmés — programmation par défaut écrite",
          correlationId,
          moduleType: "DESIGN",
          extra: { keys: Object.keys(seed) },
        });
      }
    } catch (err) {
      await logError({
        message: "Backfills programmés — écriture de la programmation par défaut impossible",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId,
        moduleType: "DESIGN",
      });
    }

    for (const key of recurrentKeys()) {
      try {
        await tickBackfill(key, {
          schedulesDoc,
          runData: runDocs.get(key),
          now,
          tickDeadlineMs,
          correlationId,
        });
      } catch (err) {
        // Un backfill en panne n'empêche pas les suivants de partir.
        await logError({
          message: `Backfills programmés — ${key} non traité à ce tick`,
          errorDescription: err instanceof Error ? err.message : String(err),
          correlationId,
          moduleType: "DESIGN",
          extra: { key },
        });
      }
    }
  },
);
