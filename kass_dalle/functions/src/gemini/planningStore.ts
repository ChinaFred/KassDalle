/**
 * Lectures et écritures Firestore du planning.
 *
 * `planning.ts` reste pur hors `callModel` : la présélection, la validation et
 * les décisions de plafond s'y testent sans Firestore. Ce module porte ce qui
 * touche la base — politique, historique des repas, notes personnelles,
 * document de génération, mémoire des refus — et rien d'autre.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` seul, déjà chargé par le reste
 * du bundle.
 */

import { randomUUID } from "node:crypto";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";

import {
  COLL_APP_CONFIG,
  COLL_PLANNED_MEALS,
  COLL_PLANNING_RUNS,
  COLL_RECIPE_RATINGS,
  COLL_USER_PREFERENCES,
  COLL_USERS,
  PLANNING_POLICY_DOC_ID,
  PLANNING_REFUSALS_DOC_ID,
} from "../config";
import { getUsdToEurRate } from "../ai/budget";
import { AiPricingUnavailableError, loadAiPricingTable } from "../ai/pricing";
import { resolveCallTarget } from "../ai/router";
import { logError, logWarn } from "../logging";
import {
  DEFAULT_PLANNING_POLICY,
  HISTORY_DAYS,
  estimateCallCeilingUsd,
  planningConceptDecision,
  readPlanningPolicy,
  readRating,
  readRefusals,
  type ConceptDenialReason,
  type PlanningPolicy,
  type PlanningSlotResult,
  type PlanningSuggestion,
  type RefusalEntry,
} from "./planning";

/** Conservation d'un document de génération, par la politique TTL Firestore. */
export const PLANNING_RUN_RETENTION_DAYS = 180;

/** Plafond de raisonnement supposé quand Gemini n'en a pas : estimation prudente. */
const GEMINI_THINKING_CEILING_TOKENS = 8_192;

/** Identifiant de génération : tiré par le serveur, jamais par le client. */
export function newPlanningRunId(): string {
  return `pr_${randomUUID().replace(/-/g, "")}`;
}

let cachedPolicy: { value: PlanningPolicy; readAt: number } | null = null;
const POLICY_TTL_MS = 60_000;

/** Politique de présélection, cache 60 s ; lecture en échec : défauts et `logError`. */
export async function getPlanningPolicy(): Promise<PlanningPolicy> {
  if (cachedPolicy && Date.now() - cachedPolicy.readAt < POLICY_TTL_MS) {
    return cachedPolicy.value;
  }
  try {
    const snap = await getFirestore().collection(COLL_APP_CONFIG).doc(PLANNING_POLICY_DOC_ID).get();
    const value = readPlanningPolicy(snap.exists ? (snap.data() as Record<string, unknown>) : null);
    cachedPolicy = { value, readAt: Date.now() };
    return value;
  } catch (err) {
    await logError({
      message: "getPlanningPolicy: lecture impossible, réglages par défaut appliqués",
      feature: "planning",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_PLANNING_POLICY;
  }
}

function isoDayMinus(day: string, days: number): string {
  const d = new Date(`${day.slice(0, 10)}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - days);
  return d.toISOString().slice(0, 10);
}

/**
 * Dernière date servie de chaque recette, dans les 90 jours avant le cycle.
 *
 * Lu à la source plutôt qu'envoyé par le client : une donnée qui sert à
 * décider ne vient pas d'une liste qu'un écran a pu tronquer. Une lecture en
 * échec rend une carte vide et `available: false` : la génération continue,
 * et aucune justification n'affirme alors un fait de service.
 */
export async function readServedHistory(args: {
  uid: string;
  cycleStart: string;
  correlationId?: string;
}): Promise<{ lastServed: Map<string, string>; available: boolean }> {
  const lastServed = new Map<string, string>();
  try {
    const from = new Date(`${isoDayMinus(args.cycleStart, HISTORY_DAYS)}T00:00:00Z`);
    const to = new Date(`${args.cycleStart.slice(0, 10)}T00:00:00Z`);
    const snap = await getFirestore()
      .collection(COLL_PLANNED_MEALS)
      .where("uid", "==", args.uid)
      .where("planned_at", ">=", Timestamp.fromDate(from))
      .where("planned_at", "<", Timestamp.fromDate(to))
      .select("recipe_id", "planned_at")
      .limit(1000)
      .get();
    for (const doc of snap.docs) {
      const id = doc.get("recipe_id");
      const at = doc.get("planned_at");
      if (typeof id !== "string" || !id || !(at instanceof Timestamp)) continue;
      const day = at.toDate().toISOString().slice(0, 10);
      const known = lastServed.get(id);
      if (!known || known < day) lastServed.set(id, day);
    }
    return { lastServed, available: true };
  } catch (err) {
    await logError({
      message: "Planning — historique des repas illisible, génération sans note de fraîcheur",
      correlationId: args.correlationId,
      userId: args.uid,
      feature: "planning",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return { lastServed: new Map(), available: false };
  }
}

/**
 * Notes personnelles de l'appelant — les siennes seulement, jamais celles des
 * autres membres. Une lecture en échec rend une carte vide : chaque recette
 * compte alors comme non notée.
 */
export async function readUserRatings(args: {
  uid: string;
  correlationId?: string;
}): Promise<Map<string, number>> {
  const ratings = new Map<string, number>();
  try {
    const snap = await getFirestore()
      .collection(COLL_RECIPE_RATINGS)
      .where("user_id", "==", args.uid)
      .select("recipe_id", "rating")
      .get();
    for (const doc of snap.docs) {
      const id = doc.get("recipe_id");
      const rating = readRating(doc.get("rating"));
      if (typeof id === "string" && id && rating != null) ratings.set(id, rating);
    }
  } catch (err) {
    await logError({
      message: "Planning — notes personnelles illisibles, génération sans note",
      correlationId: args.correlationId,
      userId: args.uid,
      feature: "planning",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
  }
  return ratings;
}

/**
 * Refus actifs de l'appelant — les siens seulement, lus sous son compte.
 *
 * Le document est écrit par le client : `readRefusals` le lit comme une
 * donnée non fiable. Une lecture en échec rend une carte vide : la génération
 * continue sans pénalité de refus, et `logError` le trace.
 */
export async function readUserRefusals(args: {
  uid: string;
  nowMs: number;
  correlationId?: string;
}): Promise<Map<string, RefusalEntry>> {
  try {
    const snap = await getFirestore()
      .collection(COLL_USERS)
      .doc(args.uid)
      .collection(COLL_USER_PREFERENCES)
      .doc(PLANNING_REFUSALS_DOC_ID)
      .get();
    return snap.exists ? readRefusals(snap.data(), args.nowMs) : new Map();
  } catch (err) {
    await logError({
      message: "Planning — mémoire des refus illisible, génération sans pénalité de refus",
      correlationId: args.correlationId,
      userId: args.uid,
      feature: "planning",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return new Map();
  }
}

/**
 * Plafond d'une génération en dollars, au taux relevé sur la facture.
 *
 * Sans taux utilisable : `null`, le plafond en euros ne s'applique pas — un
 * taux figé dans le code serait un chiffre plausible et faux.
 */
export async function generationCapUsd(policy: PlanningPolicy): Promise<number | null> {
  const rate = await getUsdToEurRate();
  if (rate == null || !(rate > 0)) {
    await logWarn({
      message: "Planning — taux dollar/euro inconnu, plafond par génération inapplicable",
      feature: "planning",
    });
    return null;
  }
  return policy.costCapEurPerGeneration / rate;
}

/**
 * Estimateur du coût plafond d'un appel pour un poste, sur la grille en
 * vigueur. Grille illisible : `null` et `logWarn`, jamais un prix du code.
 */
export function ceilingEstimator(
  feature: string,
  maxTokens: number,
): (promptChars: number) => Promise<number | null> {
  return async (promptChars) => {
    try {
      const [target, table] = await Promise.all([resolveCallTarget(feature), loadAiPricingTable()]);
      const output =
        target.provider === "gemini"
          ? maxTokens + (target.thinkingBudget ?? GEMINI_THINKING_CEILING_TOKENS)
          : maxTokens;
      return estimateCallCeilingUsd({
        model: target.model,
        promptChars,
        maxOutputTokens: output,
        table,
        at: new Date(),
      });
    } catch (err) {
      if (!(err instanceof AiPricingUnavailableError)) {
        await logError({
          message: "Planning — estimation du coût plafond impossible",
          feature,
          errorDescription: err instanceof Error ? err.message : String(err),
        });
      } else {
        await logWarn({
          message: "Planning — grille tarifaire illisible, plafond de coût inapplicable",
          feature,
          errorDescription: err.message,
        });
      }
      return null;
    }
  };
}

function runRef(uid: string, runId: string) {
  return getFirestore().collection(COLL_USERS).doc(uid).collection(COLL_PLANNING_RUNS).doc(runId);
}

/**
 * Écrit le document de génération, une fois, après l'appel.
 *
 * Rend `false` en cas d'échec (`logError`) : la réponse part quand même, sans
 * `runId`, et le client ne lance alors aucune conception automatique.
 */
export async function writePlanningRun(args: {
  uid: string;
  runId: string;
  correlationId: string;
  slotDates: string[];
  suggestion: PlanningSuggestion;
  policy: PlanningPolicy;
  costCapUsd: number | null;
}): Promise<boolean> {
  const { suggestion } = args;
  const now = new Date();
  const expires = new Date(now.getTime() + PLANNING_RUN_RETENTION_DAYS * 86_400_000);
  const proposal = (s: PlanningSlotResult) => ({
    slot: s.slot,
    date: (args.slotDates[s.slot] ?? "").slice(0, 10),
    recipe_id: s.recipeId,
    starter_id: s.starterId ?? null,
    dessert_id: s.dessertId ?? null,
    source: s.source,
  });
  const cost = suggestion.modelCall?.costUsd;
  try {
    await runRef(args.uid, args.runId).set({
      created_at: Timestamp.fromDate(now),
      expires_at: Timestamp.fromDate(expires),
      correlation_id: args.correlationId,
      cycle_start: (args.slotDates[0] ?? "").slice(0, 10),
      slots: args.slotDates.length,
      corpus_size: suggestion.stats.corpus,
      candidates_sent: suggestion.stats.candidatesSent,
      duration_ms: suggestion.stats.durationMs,
      rejected_choices: suggestion.stats.rejectedChoices,
      history_available: suggestion.stats.historyAvailable,
      model_status: suggestion.modelStatus,
      provider: suggestion.modelCall?.provider ?? null,
      model: suggestion.modelCall?.model ?? null,
      proposals: suggestion.slots.map(proposal),
      concepts_max: args.policy.conceptsPerGeneration,
      concepts_used: 0,
      cost_cap_usd: args.costCapUsd,
      cost_usd: typeof cost === "number" ? cost : 0,
      unpriced_calls: suggestion.modelCall && cost == null ? 1 : 0,
    });
    return true;
  } catch (err) {
    await logError({
      message: "Planning — document de génération non écrit, conceptions automatiques coupées",
      correlationId: args.correlationId,
      userId: args.uid,
      feature: "planning",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { runId: args.runId },
    });
    return false;
  }
}

/** Refus d'une conception rattachée à une génération. */
export class PlanningRunDenied extends Error {
  constructor(
    readonly reason: ConceptDenialReason,
    message: string,
  ) {
    super(message);
    this.name = "PlanningRunDenied";
  }
}

/**
 * Réserve une conception sur la génération, en transaction, AVANT l'appel :
 * une conception en échec compte, parce qu'elle a pu être facturée.
 *
 * Le chemin `users/{appelant}/…` rend inutilisable le `runId` d'un autre
 * compte : il n'existe pas sous l'appelant. Rend le nombre de conceptions
 * restantes après celle-ci.
 */
export async function reservePlanningConcept(args: {
  uid: string;
  runId: string;
  estimateUsd: number | null;
}): Promise<number> {
  const ref = runRef(args.uid, args.runId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = snap.exists ? (snap.data() as Record<string, unknown>) : null;
    const num = (v: unknown, fallback: number) =>
      typeof v === "number" && Number.isFinite(v) ? v : fallback;
    const created = data?.created_at;
    const run = data
      ? {
          createdAtMs: created instanceof Timestamp ? created.toMillis() : 0,
          conceptsMax: num(data.concepts_max, 0),
          conceptsUsed: num(data.concepts_used, 0),
          costUsd: num(data.cost_usd, 0),
          costCapUsd: typeof data.cost_cap_usd === "number" ? data.cost_cap_usd : null,
        }
      : null;
    const decision = planningConceptDecision({
      run,
      nowMs: Date.now(),
      estimateUsd: args.estimateUsd,
    });
    if (!decision.ok) throw new PlanningRunDenied(decision.reason, decision.message);
    tx.update(ref, { concepts_used: FieldValue.increment(1) });
    return Math.max(0, (run?.conceptsMax ?? 0) - (run?.conceptsUsed ?? 0) - 1);
  });
}

/** Ajoute le coût d'une conception à sa génération. Best-effort, `logError` en échec. */
export async function addPlanningRunCost(args: {
  uid: string;
  runId: string;
  costUsd: number | null | undefined;
  correlationId: string;
}): Promise<void> {
  try {
    await runRef(args.uid, args.runId).update(
      typeof args.costUsd === "number"
        ? { cost_usd: FieldValue.increment(args.costUsd) }
        : { unpriced_calls: FieldValue.increment(1) },
    );
  } catch (err) {
    await logError({
      message: "Planning — coût de la conception non reporté sur la génération",
      correlationId: args.correlationId,
      userId: args.uid,
      feature: "planning_concept",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { runId: args.runId, costUsd: args.costUsd ?? null },
    });
  }
}
