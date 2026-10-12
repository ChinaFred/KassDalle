/**
 * Un passage de backfill, quelle que soit son entrée : verrou, statut, compte
 * rendu, et pose automatique de « terminé » pour un ponctuel.
 *
 * Chaque backfill a son document d'état, `app_config/backfill_run_<clé>`
 * (`doc_type: "backfill_run"`), que l'écran Admin › Backfills lit en continu :
 *
 *  - `dernier_passage_statut` : `en_cours` (verrou posé), `termine`,
 *    `incomplet` ou `erreur` ; `en_cours_depuis` date le verrou. Un verrou plus
 *    vieux que `BACKFILL_LOCK_TTL_MS` est celui d'un passage interrompu : il se
 *    reprend, et l'écran l'affiche « En erreur — passage interrompu ».
 *  - `dernier_passage_le`, `dernier_passage_origine` (`manuel` / `programme`),
 *    `dernier_passage_erreur`, `arret_plafond`, `last_report` (la réponse du
 *    passage, liste « à revoir » comprise) ;
 *  - `reprise_due`, `dernier_creneau` : ce que la tâche planifiée lit pour
 *    décider d'une reprise (`schedule.ts`) ;
 *  - `termine_le`, `termine_version`, `termine_par` (`auto` / `manuel`),
 *    `termine_par_uid` : un ponctuel passé sans reste, ou marqué à la main.
 *
 * Le verrou se pose par transaction : deux passages du même backfill — deux
 * clics, ou un clic pendant un passage programmé — ne tournent jamais
 * ensemble. Deux backfills différents, si.
 */

import { randomUUID } from "node:crypto";

import { HttpsError } from "firebase-functions/v2/https";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG } from "../config";
import { logError, logWarn } from "../logging";
import { shortErrorMessage } from "../callable/_backfillReview";
import { backfillDefinition, type BackfillKey } from "./registry";
import {
  lockExpired,
  passStatus,
  repriseDueAfter,
  sanitizeAppVersion,
  shouldAutoMarkDone,
  type PassSummary,
  type RunOrigin,
} from "./schedule";

/** Valeur de `doc_type` des documents d'état : l'écran les lit par cette requête. */
export const BACKFILL_RUN_DOC_TYPE = "backfill_run";

/** Identifiant du document d'état d'un backfill. */
export function backfillRunDocId(key: BackfillKey): string {
  return `backfill_run_${key}`;
}

function runRef(db: FirebaseFirestore.Firestore, key: BackfillKey) {
  return db.collection(COLL_APP_CONFIG).doc(backfillRunDocId(key));
}

/** Millisecondes d'un `Timestamp` stocké, ou `null`. */
export function readMillis(value: unknown): number | null {
  return value instanceof Timestamp ? value.toMillis() : null;
}

/** Un passage du même backfill tient le verrou. */
export class BackfillBusyError extends Error {
  constructor(readonly title: string) {
    super(`Un passage de « ${title} » est déjà en cours.`);
    this.name = "BackfillBusyError";
  }
}

/** Le compte rendu tel qu'il s'écrit dans Firestore : sans `undefined`. */
function plain(value: object): Record<string, unknown> {
  return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
}

interface PassArgs<R extends object> {
  key: BackfillKey;
  origin: RunOrigin;
  /** Qui lance : l'administrateur, ou celui qui a programmé. */
  actorUid: string | null;
  /** Version de l'application qui lance, pour `termine_version`. */
  appVersion: string | null;
  correlationId: string;
  /** Créneau programmé (`AAAA-MM-JJTHH`), pour ne pas lancer deux fois le même. */
  creneau?: string | null;
  run: () => Promise<R>;
  summarize: (response: R) => PassSummary;
}

export interface PassResult<R> {
  response: R;
  summary: PassSummary;
  /** Ce passage vient de marquer le ponctuel terminé. */
  termineAuto: boolean;
}

/** Pose le verrou ; lève `BackfillBusyError` si un passage vivant le tient. */
async function acquireLock(
  db: FirebaseFirestore.Firestore,
  key: BackfillKey,
  title: string,
  args: { origin: RunOrigin; actorUid: string | null; lockId: string; creneau: string | null },
): Promise<{ interrupted: boolean }> {
  const ref = runRef(db, key);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const data = (snap.data() ?? {}) as Record<string, unknown>;
    const nowMs = Date.now();
    const enCours = data.dernier_passage_statut === "en_cours";
    if (enCours && !lockExpired(readMillis(data.en_cours_depuis), nowMs)) {
      throw new BackfillBusyError(title);
    }
    tx.set(
      ref,
      {
        doc_type: BACKFILL_RUN_DOC_TYPE,
        key,
        dernier_passage_statut: "en_cours",
        en_cours_origine: args.origin,
        en_cours_depuis: Timestamp.fromMillis(nowMs),
        en_cours_id: args.lockId,
        en_cours_par_uid: args.actorUid,
        ...(args.creneau ? { dernier_creneau: args.creneau } : {}),
        updated_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return { interrupted: enCours };
  });
}

/**
 * Lance un passage sous verrou et enregistre son issue. Lève
 * `BackfillBusyError` si un autre passage du même backfill tourne, et
 * relève l'erreur du passage après l'avoir enregistrée.
 */
export async function runBackfillPass<R extends object>(args: PassArgs<R>): Promise<PassResult<R>> {
  const def = backfillDefinition(args.key);
  if (!def) throw new Error(`Backfill inconnu : ${args.key}`);
  const db = getFirestore();
  const ref = runRef(db, args.key);
  const lockId = randomUUID();

  const { interrupted } = await acquireLock(db, args.key, def.title, {
    origin: args.origin,
    actorUid: args.actorUid,
    lockId,
    creneau: args.creneau ?? null,
  });
  if (interrupted) {
    await logWarn({
      message: `Backfill ${args.key} — verrou expiré repris : le passage précédent a été interrompu`,
      correlationId: args.correlationId,
      userId: args.actorUid ?? undefined,
      moduleType: "DESIGN",
      extra: { key: args.key, origin: args.origin },
    });
  }

  let response: R;
  try {
    response = await args.run();
  } catch (err) {
    await recordFinish(db, ref, lockId, args, {
      dernier_passage_statut: "erreur",
      dernier_passage_erreur: shortErrorMessage(err),
      arret_plafond: false,
      reprise_due: false,
    });
    throw err;
  }

  const summary = args.summarize(response);
  let termineAuto = false;
  await recordFinish(db, ref, lockId, args, (data) => {
    const autoDone = shouldAutoMarkDone(def.kind, summary) && data.termine_le == null;
    termineAuto = autoDone;
    return {
      dernier_passage_statut: passStatus(summary),
      dernier_passage_erreur: null,
      arret_plafond: summary.spendCapHit,
      reprise_due: repriseDueAfter(args.origin, summary, data.reprise_due === true),
      last_report: plain(response),
      ...(autoDone
        ? {
            termine_le: FieldValue.serverTimestamp(),
            termine_version: sanitizeAppVersion(args.appVersion),
            termine_par: "auto",
            termine_par_uid: args.actorUid,
          }
        : {}),
    };
  });
  return { response, summary, termineAuto };
}

/**
 * Écrit l'issue du passage et lève le verrou, s'il est toujours le sien.
 * Ne lève jamais : le travail est fait, un statut non écrit est journalisé
 * et le verrou expire seul au bout de `BACKFILL_LOCK_TTL_MS`.
 */
async function recordFinish(
  db: FirebaseFirestore.Firestore,
  ref: FirebaseFirestore.DocumentReference,
  lockId: string,
  args: Pick<PassArgs<object>, "key" | "origin" | "correlationId" | "actorUid">,
  fields: Record<string, unknown> | ((data: Record<string, unknown>) => Record<string, unknown>),
): Promise<void> {
  try {
    const written = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const data = (snap.data() ?? {}) as Record<string, unknown>;
      if (data.en_cours_id !== lockId) return false;
      const values = typeof fields === "function" ? fields(data) : fields;
      tx.set(
        ref,
        {
          ...values,
          dernier_passage_le: FieldValue.serverTimestamp(),
          dernier_passage_origine: args.origin,
          last_correlation_id: args.correlationId,
          en_cours_depuis: null,
          en_cours_id: null,
          en_cours_origine: null,
          en_cours_par_uid: null,
          updated_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return true;
    });
    if (!written) {
      await logWarn({
        message: `Backfill ${args.key} — verrou repris par un autre passage, issue non écrite`,
        correlationId: args.correlationId,
        userId: args.actorUid ?? undefined,
        moduleType: "DESIGN",
        extra: { key: args.key },
      });
    }
  } catch (err) {
    await logError({
      message: `Backfill ${args.key} — issue du passage non enregistrée`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.correlationId,
      userId: args.actorUid ?? undefined,
      moduleType: "DESIGN",
      extra: { key: args.key, origin: args.origin },
    });
  }
}

/**
 * Entrée d'un callable : même passage, origine `manuel`, et un passage déjà
 * en cours devient une `failed-precondition` que l'écran reconnaît. La
 * réponse du backfill est rendue telle quelle, plus `termineAuto`.
 */
export async function runBackfillFromCallable<R extends object>(args: {
  key: BackfillKey;
  ctx: { userId: string; correlationId: string };
  appVersion: unknown;
  run: () => Promise<R>;
  summarize: (response: R) => PassSummary;
}): Promise<R & { termineAuto: boolean }> {
  try {
    const result = await runBackfillPass({
      key: args.key,
      origin: "manuel",
      actorUid: args.ctx.userId,
      appVersion: sanitizeAppVersion(args.appVersion),
      correlationId: args.ctx.correlationId,
      run: args.run,
      summarize: args.summarize,
    });
    return { ...result.response, termineAuto: result.termineAuto };
  } catch (err) {
    if (err instanceof BackfillBusyError) {
      throw new HttpsError("failed-precondition", err.message);
    }
    throw err;
  }
}

/**
 * La tâche planifiée n'a pas eu le temps de lancer ce passage : il reprend
 * au tick suivant. `creneau` retient le créneau consommé.
 */
export async function markBackfillDeferred(
  key: BackfillKey,
  creneau: string | null,
): Promise<void> {
  await runRef(getFirestore(), key).set(
    {
      doc_type: BACKFILL_RUN_DOC_TYPE,
      key,
      reprise_due: true,
      ...(creneau ? { dernier_creneau: creneau } : {}),
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

/**
 * Passage programmé refusé avant de commencer : le plafond de dépense de
 * l'administrateur qui l'a programmé est atteint. Statut « incomplet, arrêt
 * par plafond » ; la reprise attend le prochain créneau.
 */
export async function recordSpendCapSkip(
  key: BackfillKey,
  creneau: string | null,
  correlationId: string,
): Promise<void> {
  await runRef(getFirestore(), key).set(
    {
      doc_type: BACKFILL_RUN_DOC_TYPE,
      key,
      dernier_passage_statut: "incomplet",
      dernier_passage_origine: "programme",
      dernier_passage_le: FieldValue.serverTimestamp(),
      dernier_passage_erreur: null,
      arret_plafond: true,
      reprise_due: false,
      last_correlation_id: correlationId,
      ...(creneau ? { dernier_creneau: creneau } : {}),
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

/** Pose ou retire « terminé » à la main sur un ponctuel. */
export async function setBackfillDone(args: {
  key: BackfillKey;
  done: boolean;
  adminUid: string;
  appVersion: string | null;
}): Promise<void> {
  await runRef(getFirestore(), args.key).set(
    {
      doc_type: BACKFILL_RUN_DOC_TYPE,
      key: args.key,
      ...(args.done
        ? {
            termine_le: FieldValue.serverTimestamp(),
            termine_version: args.appVersion,
            termine_par: "manuel",
            termine_par_uid: args.adminUid,
          }
        : {
            termine_le: null,
            termine_version: null,
            termine_par: null,
            termine_par_uid: null,
          }),
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}
