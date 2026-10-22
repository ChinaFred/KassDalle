/**
 * `scheduledErrorReportsPurge` — purge des rapports d'erreur de plus de
 * 90 jours, tous les jours à 4 h (Europe/Paris). Ticket #162, point 3.
 *
 * `error_reports/{id}` reçoit un document par erreur remontée par le client
 * (`ErrorReportService`), de tout compte connecté, même en attente. Rien ne
 * les supprimait : la collection grossissait sans fin, et chaque rapport garde
 * un message, une pile et un contexte qui peuvent citer une donnée de
 * l'utilisateur.
 *
 * Le champ de date est `timestamp` (`ErrorReport.toFirestore`, un `Timestamp`
 * Firestore ; `firestore.rules` le veut absent ou de ce type). La requête
 * `timestamp < échéance` ne voit que les documents dont `timestamp` est un
 * `Timestamp` : un rapport sans date n'est pas supprimé, et reste lisible dans
 * Admin › Rapports d'erreurs.
 *
 * Suppression par lots de `PURGE_BATCH_SIZE`, `PURGE_MAX_BATCHES` lots au plus
 * par passage : un arriéré plus gros se termine les jours suivants. Un lot en
 * échec arrête la passe (le relire rendrait les mêmes documents) ; le nombre
 * déjà supprimé est journalisé dans tous les cas.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_ERROR_REPORTS, REGION } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";

/** Durée de conservation d'un rapport d'erreur, en jours. */
export const ERROR_REPORTS_RETENTION_DAYS = 90;

/** Documents supprimés par écriture groupée (plafond Firestore : 500). */
export const PURGE_BATCH_SIZE = 400;

/** Lots au plus par passage : 20 000 rapports. */
export const PURGE_MAX_BATCHES = 50;

const DAY_MS = 24 * 60 * 60 * 1000;

/** Échéance : un rapport daté d'avant cet instant est supprimé. */
export function errorReportsCutoff(now: Date): Date {
  return new Date(now.getTime() - ERROR_REPORTS_RETENTION_DAYS * DAY_MS);
}

/** Compte rendu d'une passe. */
export interface PurgeOutcome {
  deleted: number;
  batches: number;
  /** `true` si la dernière lecture a rendu moins d'un lot : rien ne reste. */
  complete: boolean;
  /** Message de l'erreur qui a arrêté la passe, s'il y en a une. */
  failure: string | null;
}

/**
 * Boucle de suppression, sans Firestore : [readBatch] rend au plus `limit`
 * éléments à supprimer, [deleteBatch] les supprime. Pure et exportée pour être
 * testée.
 */
export async function purgeInBatches<T>(
  readBatch: (limit: number) => Promise<T[]>,
  deleteBatch: (items: T[]) => Promise<void>,
  batchSize = PURGE_BATCH_SIZE,
  maxBatches = PURGE_MAX_BATCHES,
): Promise<PurgeOutcome> {
  let deleted = 0;
  let batches = 0;
  while (batches < maxBatches) {
    let items: T[];
    try {
      items = await readBatch(batchSize);
    } catch (err) {
      return { deleted, batches, complete: false, failure: describe(err) };
    }
    if (items.length === 0) return { deleted, batches, complete: true, failure: null };
    try {
      await deleteBatch(items);
    } catch (err) {
      return { deleted, batches, complete: false, failure: describe(err) };
    }
    deleted += items.length;
    batches += 1;
    if (items.length < batchSize) return { deleted, batches, complete: true, failure: null };
  }
  return { deleted, batches, complete: false, failure: null };
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export const scheduledErrorReportsPurge = onSchedule(
  {
    schedule: "0 4 * * *",
    timeZone: "Europe/Paris",
    region: REGION,
    memory: "256MiB",
    timeoutSeconds: 540,
    retryCount: 0,
  },
  async () => {
    const correlationId = newCorrelationId("error_reports_purge");
    const db = getFirestore();
    const cutoff = errorReportsCutoff(new Date());
    const query = db
      .collection(COLL_ERROR_REPORTS)
      .where("timestamp", "<", Timestamp.fromDate(cutoff));

    const outcome = await purgeInBatches(
      async (limit) => (await query.limit(limit).get()).docs.map((d) => d.ref),
      async (refs) => {
        const batch = db.batch();
        for (const ref of refs) batch.delete(ref);
        await batch.commit();
      },
    );

    const extra = {
      deleted: outcome.deleted,
      batches: outcome.batches,
      complete: outcome.complete,
      cutoff: cutoff.toISOString(),
      retentionDays: ERROR_REPORTS_RETENTION_DAYS,
    };
    if (outcome.failure !== null) {
      await logError({
        message: "scheduledErrorReportsPurge : passe interrompue",
        errorDescription: outcome.failure,
        correlationId,
        feature: "error_reports_purge",
        extra,
      });
      return;
    }
    await logInfo({
      message: `scheduledErrorReportsPurge : ${outcome.deleted} rapport(s) supprimé(s)`,
      correlationId,
      feature: "error_reports_purge",
      extra,
    });
  },
);
