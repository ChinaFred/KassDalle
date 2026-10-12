/**
 * Durées estimées — rattrapage de l'existant.
 *
 * `onRecipeWritten` estime les durées absentes d'une recette à son écriture
 * (`triggers/recipeEstimatedTimes.ts`). Les recettes déjà en base ne sont pas
 * réécrites d'elles-mêmes : ce backfill les parcourt et estime, par lots de
 * huit recettes par appel de modèle, celles à qui il manque une durée de
 * préparation ou de cuisson. Poste de coût `backfill_time_estimate_batch`,
 * distinct de l'estimation à l'écriture : une reprise en masse se lit à part
 * dans les comptes.
 *
 * Réentrante : une recette dont les deux durées sont lues, ou qui porte déjà
 * une estimation pour son contenu, n'est pas reprise — relancer ne refacture
 * rien. Le curseur permet de continuer où l'appel précédent s'est arrêté.
 * Bornée trois fois : par le délai, par un nombre de recettes estimées par
 * appel, et par trois lots en échec de suite, qui signalent une panne plutôt
 * qu'un lot difficile.
 *
 * Deux protections, relevées en relecture de sécurité :
 *  - **un seul passage à la fois.** Un verrou daté (`running_until`) se pose
 *    en transaction sur le point de reprise au début, et se lève à la fin. Un
 *    second lancement pendant le premier sort tout de suite, sans appel de
 *    modèle, avec un compte rendu « déjà en cours ». Le verrou expire de
 *    lui-même au bout du délai maximal de la fonction : une instance tuée ne
 *    bloque pas le backfill pour toujours ;
 *  - **un lot ne mêle pas deux propriétaires.** Le texte d'une recette est
 *    saisi par son auteur ; mis dans le même prompt que la recette d'un autre
 *    compte, il pourrait orienter la réponse donnée pour elle. Les candidats
 *    sont donc groupés par `created_by`.
 */

import { randomUUID } from "node:crypto";
import { onCall } from "firebase-functions/v2/https";
import { Timestamp, getFirestore } from "firebase-admin/firestore";

import {
  ANTHROPIC_API_KEY,
  COLL_APP_CONFIG,
  COLL_RECIPES,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import {
  TIME_ESTIMATE_BATCH_SIZE,
  estimateRecipeTimes,
  type TimeEstimate,
  type TimeEstimateInput,
} from "../gemini/timeEstimate";
import { logError, logInfo } from "../logging";
import {
  BackfillReview,
  shortErrorMessage,
  withoutReviewList,
  type BackfillReviewList,
} from "./_backfillReview";
import {
  decideEstimatedTimes,
  doneEstimatedTimes,
  estimateContent,
  estimateFingerprint,
} from "../triggers/recipeEstimatedTimes";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient la dernière recette examinée et le verrou propre aux durées estimées. */
export const ESTIMATED_TIMES_CHECKPOINT_DOC_ID = "estimated_times_backfill_checkpoint";

const FEATURE = "backfill_time_estimate_batch";
const PAGE_SIZE = 100;
/** Délai maximal de la fonction, en secondes : aussi la durée de vie du verrou. */
const FUNCTION_TIMEOUT_SECONDS = 540;
/** Recettes soumises au modèle par appel du backfill, par défaut : vingt lots. */
const DEFAULT_MAX_RECIPES = 160;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Un lot dure jusqu'à une minute : ne pas en lancer un sans cette marge. */
const BATCH_MARGIN_MS = 70_000;
/** Trois lots en échec de suite : une panne, pas trois lots difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillEstimatedTimesRequest {
  maxMinutes?: number;
  maxRecipes?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillEstimatedTimesResponse {
  /** Un autre passage tenait le verrou : rien n'a été fait. */
  dejaEnCours: boolean;
  /** Recettes lues pendant ce passage. */
  examinees: number;
  /** Au moins une durée estimée et écrite. */
  estimees: number;
  /** Aucune durée estimée (le modèle n'a pas su) : écrit comme tel, non redemandé. */
  sansEstimation: number;
  /** Durées lues, estimation déjà à jour ou en cours, ou recette vide : rien d'appelé. */
  ignorees: number;
  /** Pages qui ne sont pas des recettes. */
  horsRecette: number;
  /**
   * Lot en échec, ou écriture impossible. Le curseur avance quand même : une
   * recette qui échoue toujours ne bloque pas le parcours. Elle est reprise
   * au parcours suivant, qui repart du début une fois la collection
   * parcourue — `completed` reste faux tant qu'un passage compte une erreur.
   */
  enErreur: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /**
   * Recettes à revoir, chacune avec son titre et la raison : lot en échec,
   * pas de réponse de l'IA, aucune durée estimée, écriture refusée. Recopiée
   * dans le `last_report` de l'état du backfill, jamais dans les journaux.
   */
  aRevoir: BackfillReviewList;
  /**
   * Vrai quand la collection a été parcourue en entier sans erreur. Le
   * curseur est remis au début dès qu'elle est parcourue, erreurs comprises.
   */
  completed: boolean;
}

export function emptyEstimatedTimesResponse(): BackfillEstimatedTimesResponse {
  return {
    dejaEnCours: false,
    examinees: 0,
    estimees: 0,
    sansEstimation: 0,
    ignorees: 0,
    horsRecette: 0,
    enErreur: 0,
    collectionParcourue: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
}

// ── Verrou ───────────────────────────────────────────────────────────────────

/** Vrai quand le document de reprise porte un verrou encore valide à `nowMs`. */
export function backfillLockHeld(
  data: Record<string, unknown> | undefined,
  nowMs: number,
): boolean {
  const until = data?.running_until;
  return until instanceof Timestamp && until.toMillis() > nowMs;
}

/** Pose le verrou ; faux si un autre passage le tient. */
async function acquireLock(db: FirebaseFirestore.Firestore, lockId: string): Promise<boolean> {
  const ref = db.collection(COLL_APP_CONFIG).doc(ESTIMATED_TIMES_CHECKPOINT_DOC_ID);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const now = Date.now();
    if (backfillLockHeld(snap.data(), now)) return false;
    tx.set(
      ref,
      {
        running_until: Timestamp.fromMillis(now + FUNCTION_TIMEOUT_SECONDS * 1000),
        running_id: lockId,
      },
      { merge: true },
    );
    return true;
  });
}

/** Lève le verrou s'il est toujours le sien. Ne lève jamais : l'échec est journalisé. */
async function releaseLock(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  lockId: string,
): Promise<void> {
  const ref = db.collection(COLL_APP_CONFIG).doc(ESTIMATED_TIMES_CHECKPOINT_DOC_ID);
  try {
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (snap.data()?.running_id !== lockId) return;
      tx.set(ref, { running_until: null, running_id: null }, { merge: true });
    });
  } catch (e) {
    // Le verrou expire de lui-même au bout du délai de la fonction.
    await logError("Durées estimées — verrou non levé", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      errorDescription: e instanceof Error ? e.message : String(e),
    });
  }
}

// ── Lots par propriétaire ────────────────────────────────────────────────────

interface Candidate {
  ref: FirebaseFirestore.DocumentReference;
  fingerprint: string;
  input: TimeEstimateInput;
}

/** Le propriétaire d'une recette, clé de regroupement des lots. */
export function recipeOwnerKey(data: Record<string, unknown>): string {
  return typeof data.created_by === "string" ? data.created_by : "";
}

/**
 * Candidats en attente, un groupe par propriétaire. `add` rend le groupe dès
 * qu'il atteint la taille d'un lot ; `drain` rend tous les groupes restants.
 */
export class OwnerBatches<T> {
  private readonly groups = new Map<string, T[]>();

  constructor(private readonly size: number) {}

  add(owner: string, item: T): T[] | null {
    const group = this.groups.get(owner) ?? [];
    group.push(item);
    if (group.length >= this.size) {
      this.groups.delete(owner);
      return group;
    }
    this.groups.set(owner, group);
    return null;
  }

  get pending(): number {
    let n = 0;
    for (const g of this.groups.values()) n += g.length;
    return n;
  }

  drain(): Array<[string, T[]]> {
    const out = [...this.groups.entries()];
    this.groups.clear();
    return out;
  }
}

/**
 * Pourquoi une recette d'un lot abouti reste à revoir, ou `null`.
 * `answer` : la réponse du modèle pour elle ; `written` : le champ écrit.
 */
export function answerReviewReason(
  answer: TimeEstimate | undefined,
  written: { prep: number | null; cook: number | null },
): string | null {
  if (answer === undefined) return "Pas de réponse de l'IA pour cette recette";
  if (written.prep == null && written.cook == null) return "L'IA n'a estimé aucune durée";
  return null;
}

/** Raison d'une recette d'un lot dont l'appel a échoué. */
export function batchFailureReason(err: unknown): string {
  return `Lot en échec : ${shortErrorMessage(err)}`;
}

/** Raison d'une recette dont l'écriture a échoué. */
export function writeFailureReason(err: unknown): string {
  return `Écriture refusée : ${shortErrorMessage(err)}`;
}

/**
 * Soumet un lot (un seul propriétaire) au modèle et écrit chaque réponse,
 * recette par recette, dans une transaction qui vérifie que le contenu n'a
 * pas changé entretemps. Rend vrai si l'appel a abouti.
 */
async function flushBatch(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  owner: string,
  batch: Candidate[],
  response: BackfillEstimatedTimesResponse,
  review: BackfillReview,
): Promise<boolean> {
  const toReview = (candidate: Candidate, reason: string) =>
    review.add({
      kind: "recipe",
      id: candidate.ref.id,
      label: candidate.input.titre || candidate.ref.id,
      reason,
    });
  let answers;
  try {
    answers = await estimateRecipeTimes(
      batch.map((c) => c.input),
      { ...ctx, feature: FEATURE, moduleType: "DESIGN", timeoutMs: 60_000 },
    );
  } catch (e) {
    response.enErreur += batch.length;
    await logError("Durées estimées — échec d'un lot", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      geminiStatus: "ERROR",
      feature: FEATURE,
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { owner, recipeIds: batch.map((c) => c.ref.id) },
    });
    for (const candidate of batch) toReview(candidate, batchFailureReason(e));
    return false;
  }

  for (const [index, candidate] of batch.entries()) {
    const answer = answers.get(index);
    const estimate = answer ?? { prep: null, cook: null };
    try {
      const written = await db.runTransaction(async (tx) => {
        const snap = await tx.get(candidate.ref);
        if (!snap.exists) return null;
        const current = snap.data() as Record<string, unknown>;
        const decision = decideEstimatedTimes(current, Date.now());
        if (decision.kind !== "estimate" || decision.fingerprint !== candidate.fingerprint) {
          return null;
        }
        const field = doneEstimatedTimes(candidate.fingerprint, estimate, current);
        tx.update(candidate.ref, { estimated_times: field });
        return field;
      });
      if (!written) {
        // Modifiée, ou estimée par le déclencheur, pendant l'appel : sa
        // prochaine écriture ou le prochain passage la reprendra si besoin.
        response.ignorees += 1;
      } else {
        const reason = answerReviewReason(answer, written);
        if (reason) {
          response.sansEstimation += 1;
          toReview(candidate, reason);
        } else {
          response.estimees += 1;
        }
      }
    } catch (e) {
      response.enErreur += 1;
      await logError("Durées estimées — écriture impossible sur une recette", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { recipeId: candidate.ref.id, owner },
      });
      toReview(candidate, writeFailureReason(e));
    }
  }
  return true;
}

export const backfillEstimatedTimesFn = onCall<BackfillEstimatedTimesRequest>(
  {
    region: REGION,
    timeoutSeconds: FUNCTION_TIMEOUT_SECONDS,
    memory: "512MiB",
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);
    return runBackfillFromCallable({
      key: "estimated_times",
      ctx,
      appVersion: req.data?.appVersion,
      summarize: summarizeEstimatedTimes,
      run: () => runEstimatedTimesPass(ctx, req.data),
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeEstimatedTimes(r: BackfillEstimatedTimesResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
  };
}

/**
 * Un passage sous le verrou propre aux durées estimées, posé avant le verrou
 * commun des backfills (`backfills/runner.ts`) et gardé : il protège aussi des
 * passages lancés par une version antérieure du client.
 */
async function runEstimatedTimesPass(
  ctx: AuthContext,
  data: BackfillEstimatedTimesRequest | undefined,
): Promise<BackfillEstimatedTimesResponse> {
  const db = getFirestore();
  const response = emptyEstimatedTimesResponse();

  const lockId = randomUUID();
  if (!(await acquireLock(db, lockId))) {
    response.dejaEnCours = true;
    await logInfo({
      message: "Durées estimées — passage déjà en cours, rien n'est lancé",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
    });
    return response;
  }

  try {
    await runBackfill(db, ctx, data, response);
  } finally {
    await releaseLock(db, ctx, lockId);
  }
  return response;
}

/** Une recette telle que le parcours la lit. */
export interface ScannedDoc<T> {
  id: string;
  data: Record<string, unknown>;
  /** Le candidat à soumettre, construit seulement si la recette en est un. */
  toCandidate: () => T;
}

/**
 * Le parcours du backfill, sans Firestore ni modèle : `nextPage` lit la page
 * qui suit un identifiant, `submit` soumet un lot d'un propriétaire et rend
 * faux en cas d'échec. Rend le curseur à écrire (`null` : parcours complet).
 *
 * - Le curseur ne dépasse pas une recette mise dans un lot avant que ce lot
 *   soit soumis ; il dépasse en revanche un lot en ÉCHEC (voir `enErreur`).
 * - Le quota de recettes (`maxRecipes`) compte les recettes soumises et en
 *   attente. Atteint, les groupes en attente sont soumis avant l'arrêt, si
 *   le délai le permet : sans cela, vingt propriétaires de moins de huit
 *   recettes rempliraient le quota sans qu'aucun lot parte, et le passage
 *   n'avancerait jamais.
 */
export async function scanForEstimates<T>(args: {
  startCursor: string | null;
  pageSize: number;
  nextPage: (after: string | null) => Promise<ScannedDoc<T>[]>;
  submit: (owner: string, batch: T[]) => Promise<boolean>;
  batchSize: number;
  maxRecipes: number;
  /** Faux quand il ne reste plus le temps de soumettre un lot. */
  canSubmit: () => boolean;
  /** Faux quand le délai du passage est dépassé. */
  inTime: () => boolean;
  now: () => number;
  response: BackfillEstimatedTimesResponse;
  onPageDone?: (cursor: string | null) => Promise<void>;
}): Promise<string | null> {
  const { response } = args;
  let cursor = args.startCursor;
  let lastSeen = args.startCursor;
  let submitted = 0;
  let consecutiveFailures = 0;
  const batches = new OwnerBatches<T>(args.batchSize);

  /** Soumet un lot ; faux s'il faut s'arrêter. */
  const flush = async (owner: string, batch: T[]): Promise<boolean> => {
    if (!args.canSubmit()) {
      response.stoppedByDeadline = true;
      return false;
    }
    const ok = await args.submit(owner, batch);
    submitted += batch.length;
    consecutiveFailures = ok ? 0 : consecutiveFailures + 1;
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      return false;
    }
    return true;
  };

  /** Soumet tous les groupes en attente ; faux s'il faut s'arrêter. */
  const flushAll = async (): Promise<boolean> => {
    for (const [owner, group] of batches.drain()) {
      if (!(await flush(owner, group))) return false;
    }
    cursor = lastSeen;
    return true;
  };

  pages: for (;;) {
    const page = await args.nextPage(lastSeen);
    if (page.length === 0) {
      if (await flushAll()) response.collectionParcourue = true;
      break;
    }

    for (const doc of page) {
      if (!args.inTime()) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (submitted + batches.pending >= args.maxRecipes) {
        response.stoppedByBudget = true;
        await flushAll();
        break pages;
      }

      response.examinees += 1;
      lastSeen = doc.id;
      // Une page sans `page_type` est une recette : le client n'écrit le
      // champ que pour les autres types.
      const pageType = typeof doc.data.page_type === "string" ? doc.data.page_type : "recipe";
      if (pageType !== "recipe") {
        response.horsRecette += 1;
        if (batches.pending === 0) cursor = doc.id;
        continue;
      }
      if (decideEstimatedTimes(doc.data, args.now()).kind !== "estimate") {
        response.ignorees += 1;
        if (batches.pending === 0) cursor = doc.id;
        continue;
      }

      const owner = recipeOwnerKey(doc.data);
      const full = batches.add(owner, doc.toCandidate());
      if (full && !(await flush(owner, full))) break pages;
      if (batches.pending === 0) cursor = doc.id;
    }

    if (!(await flushAll())) break;
    if (page.length < args.pageSize) {
      response.collectionParcourue = true;
      break;
    }
    await args.onPageDone?.(cursor);
  }

  return response.collectionParcourue ? null : cursor;
}

async function runBackfill(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  data: BackfillEstimatedTimesRequest | undefined,
  response: BackfillEstimatedTimesResponse,
): Promise<void> {
  const maxMinutesRaw = Number(data?.maxMinutes ?? 8);
  const maxMinutes = Number.isFinite(maxMinutesRaw) ? Math.max(1, Math.min(8.5, maxMinutesRaw)) : 8;
  const deadline = Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS;
  const maxRecipes = boundedMaxRecipes(data?.maxRecipes);
  const resumeFromCheckpoint = parseBoolean(data?.resumeFromCheckpoint, true);
  const resetCheckpoint = parseBoolean(data?.resetCheckpoint, false);

  const review = new BackfillReview();
  const startCursor = await getBackfillCursor({
    db,
    docId: ESTIMATED_TIMES_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint,
    resetCheckpoint,
  });

  const cursor = await scanForEstimates<Candidate>({
    startCursor,
    pageSize: PAGE_SIZE,
    nextPage: async (after) => {
      let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
      if (after) query = query.startAfter(after);
      const page = await query.get();
      return page.docs.map((doc) => {
        const recipe = doc.data() as Record<string, unknown>;
        return {
          id: doc.id,
          data: recipe,
          toCandidate: () => ({
            ref: doc.ref,
            fingerprint: estimateFingerprint(recipe),
            input: {
              titre: typeof recipe.titre === "string" ? recipe.titre : "",
              content: estimateContent(recipe),
              portions: typeof recipe.portions === "number" ? recipe.portions : null,
            },
          }),
        };
      });
    },
    submit: (owner, batch) => flushBatch(db, ctx, owner, batch, response, review),
    batchSize: TIME_ESTIMATE_BATCH_SIZE,
    maxRecipes,
    canSubmit: () => Date.now() + BATCH_MARGIN_MS <= deadline,
    inTime: () => Date.now() <= deadline,
    now: () => Date.now(),
    response,
    onPageDone: (pageCursor) =>
      setBackfillCursor({
        db,
        docId: ESTIMATED_TIMES_CHECKPOINT_DOC_ID,
        lastDocId: pageCursor,
        operation: FEATURE,
        adminUid: ctx.userId,
      }),
  });

  // Terminé seulement si la collection a été parcourue SANS erreur : une
  // recette en erreur sera reprise par le passage suivant, qui repart du
  // début et ignore sans appel tout ce qui est déjà estimé.
  response.completed = response.collectionParcourue && response.enErreur === 0;
  response.aRevoir = review.toJSON();

  // Le curseur revient au début quand tout est passé. Sinon il retient le
  // dernier document traité : un lot non soumis sera relu au prochain
  // passage. Le compte rendu part dans l'état du backfill (`backfills/runner.ts`).
  await setBackfillCursor({
    db,
    docId: ESTIMATED_TIMES_CHECKPOINT_DOC_ID,
    lastDocId: cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  await logInfo({
    message: "Durées estimées — rattrapage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    // Sans la liste : elle porte des titres de recettes privées.
    extra: { ...withoutReviewList(response), maxMinutes, maxRecipes },
  });
}

/**
 * Recettes soumises par passage : un lot au moins, quatre cents au plus. En
 * dessous d'un lot, aucun groupe n'atteindrait sa taille avant le quota.
 */
export function boundedMaxRecipes(raw: unknown): number {
  const value = Number(raw ?? DEFAULT_MAX_RECIPES);
  return Number.isFinite(value)
    ? Math.max(TIME_ESTIMATE_BATCH_SIZE, Math.min(400, Math.trunc(value)))
    : DEFAULT_MAX_RECIPES;
}
