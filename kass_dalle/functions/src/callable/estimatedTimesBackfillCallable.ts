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
  type TimeEstimateInput,
} from "../gemini/timeEstimate";
import { logError, logInfo } from "../logging";
import {
  decideEstimatedTimes,
  doneEstimatedTimes,
  estimateContent,
  estimateFingerprint,
} from "../triggers/recipeEstimatedTimes";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin, type AuthContext } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient la dernière recette examinée, le dernier compte rendu et le verrou. */
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
  /** Lot en échec, ou écriture impossible : à reprendre au prochain passage. */
  enErreur: number;
  collectionParcourue: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand la collection a été parcourue en entier : le curseur est remis au début. */
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
): Promise<boolean> {
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
    return false;
  }

  for (const [index, candidate] of batch.entries()) {
    const estimate = answers.get(index) ?? { prep: null, cook: null };
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
      } else if (written.prep == null && written.cook == null) {
        response.sansEstimation += 1;
      } else {
        response.estimees += 1;
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
  async (req): Promise<BackfillEstimatedTimesResponse> => {
    const ctx = await requireAdmin(req, FEATURE);
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
      await runBackfill(db, ctx, req.data, response);
    } finally {
      await releaseLock(db, ctx, lockId);
    }
    return response;
  },
);

async function runBackfill(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  data: BackfillEstimatedTimesRequest | undefined,
  response: BackfillEstimatedTimesResponse,
): Promise<void> {
  const maxMinutesRaw = Number(data?.maxMinutes ?? 8);
  const maxMinutes = Number.isFinite(maxMinutesRaw) ? Math.max(1, Math.min(8.5, maxMinutesRaw)) : 8;
  const deadline = Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS;
  const maxRecipesRaw = Number(data?.maxRecipes ?? DEFAULT_MAX_RECIPES);
  const maxRecipes = Number.isFinite(maxRecipesRaw)
    ? Math.max(1, Math.min(400, Math.trunc(maxRecipesRaw)))
    : DEFAULT_MAX_RECIPES;
  const resumeFromCheckpoint = parseBoolean(data?.resumeFromCheckpoint, true);
  const resetCheckpoint = parseBoolean(data?.resetCheckpoint, false);

  // Le dernier document au-delà duquel rien n'est en attente. Une recette
  // mise dans un lot n'est traitée qu'une fois le lot soumis : le curseur ne
  // la dépasse pas avant. Un lot soumis en cours de page puis relu au
  // passage suivant est ignoré (estimation à jour), sans nouvel appel.
  let cursor = await getBackfillCursor({
    db,
    docId: ESTIMATED_TIMES_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint,
    resetCheckpoint,
  });

  let submitted = 0;
  let consecutiveFailures = 0;
  const batches = new OwnerBatches<Candidate>(TIME_ESTIMATE_BATCH_SIZE);
  let lastSeen: string | null = cursor;

  /** Soumet un lot ; faux s'il faut s'arrêter. */
  const flush = async (owner: string, batch: Candidate[]): Promise<boolean> => {
    if (Date.now() + BATCH_MARGIN_MS > deadline) {
      response.stoppedByDeadline = true;
      return false;
    }
    const ok = await flushBatch(db, ctx, owner, batch, response);
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
    let query = db.collection(COLL_RECIPES).orderBy("__name__").limit(PAGE_SIZE);
    if (lastSeen) query = query.startAfter(lastSeen);
    const page = await query.get();
    if (page.empty) {
      if (await flushAll()) response.collectionParcourue = true;
      break;
    }

    for (const doc of page.docs) {
      if (Date.now() > deadline) {
        response.stoppedByDeadline = true;
        break pages;
      }
      if (submitted + batches.pending >= maxRecipes) {
        response.stoppedByBudget = true;
        break pages;
      }

      response.examinees += 1;
      lastSeen = doc.id;
      const recipe = doc.data() as Record<string, unknown>;
      // Une page sans `page_type` est une recette : le client n'écrit le
      // champ que pour les autres types.
      const pageType = typeof recipe.page_type === "string" ? recipe.page_type : "recipe";
      if (pageType !== "recipe") {
        response.horsRecette += 1;
        if (batches.pending === 0) cursor = doc.id;
        continue;
      }

      const decision = decideEstimatedTimes(recipe, Date.now());
      if (decision.kind !== "estimate") {
        response.ignorees += 1;
        if (batches.pending === 0) cursor = doc.id;
        continue;
      }

      const owner = recipeOwnerKey(recipe);
      const candidate: Candidate = {
        ref: doc.ref,
        fingerprint: estimateFingerprint(recipe),
        input: {
          titre: typeof recipe.titre === "string" ? recipe.titre : "",
          content: estimateContent(recipe),
          portions: typeof recipe.portions === "number" ? recipe.portions : null,
        },
      };
      const full = batches.add(owner, candidate);
      if (full && !(await flush(owner, full))) break pages;
      if (batches.pending === 0) cursor = doc.id;
    }

    if (!(await flushAll())) break;
    if (page.size < PAGE_SIZE) {
      response.collectionParcourue = true;
      break;
    }

    await setBackfillCursor({
      db,
      docId: ESTIMATED_TIMES_CHECKPOINT_DOC_ID,
      lastDocId: cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
    });
  }

  response.completed = response.collectionParcourue;

  // Le curseur revient au début quand tout est passé. Sinon il retient le
  // dernier document traité : un lot non soumis sera relu au prochain
  // passage. Le compte rendu part avec lui, pour l'écran.
  await setBackfillCursor({
    db,
    docId: ESTIMATED_TIMES_CHECKPOINT_DOC_ID,
    lastDocId: response.collectionParcourue ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
    lastReport: { ...response },
  });

  await logInfo({
    message: "Durées estimées — rattrapage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...response, maxMinutes, maxRecipes },
  });
}
