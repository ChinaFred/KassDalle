/**
 * deadLetterHandler — Callable functions admin (Phase 1.7).
 *
 * Expose les actions admin sur les dead letters :
 *  - relancer : recrée un processing_job (status=queued) à partir du DLQ,
 *    et met à jour dead_letters/{id}.relaunched_at
 *  - supprimer : hard delete du document DLQ
 *
 * Les opérations sont protégées par requireAdmin().
 *
 * Le déclenchement du passage en DLQ est géré directement par
 * recipeProcessor lorsqu'il a épuisé ses retries (cf. moveToDeadLetter).
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, COLL_DEAD_LETTERS, COLL_PROCESSING_JOBS } from "../config";
import { requireAdmin } from "../callable/_auth";
import { logInfo } from "../logging";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const adminOpts = { region: REGION, cors: ALLOWED_ORIGINS };

/**
 * Relance un DLQ : copie les infos du job original (s'il existe encore) et crée
 * un nouveau processing_job avec status=queued, ce qui déclenche jobDispatcher.
 */
export const relaunchDeadLetterFn = onCall(adminOpts, async (req) => {
  const ctx = await requireAdmin(req);
  const { deadLetterId } = (req.data ?? {}) as { deadLetterId?: string };
  if (!deadLetterId) throw new HttpsError("invalid-argument", "deadLetterId requis.");

  const db = getFirestore();
  const dlqRef = db.collection(COLL_DEAD_LETTERS).doc(deadLetterId);
  const dlqSnap = await dlqRef.get();
  if (!dlqSnap.exists) throw new HttpsError("not-found", "Dead letter introuvable.");
  const dlq = dlqSnap.data()!;

  const originalJobId = dlq.original_job_id as string;
  const originalJobRef = db.collection(COLL_PROCESSING_JOBS).doc(originalJobId);
  const originalSnap = await originalJobRef.get();
  if (!originalSnap.exists) {
    throw new HttpsError("failed-precondition", "Job original supprimé, relance impossible.");
  }
  const original = originalSnap.data()!;

  const newJob = db.collection(COLL_PROCESSING_JOBS).doc();
  await newJob.set({
    ...original,
    status: "queued",
    current_step: "queued",
    error_message: null,
    error_id: null,
    attempt_count: 0,
    created_recipe_ids: [],
    relaunched_from: originalJobId,
    relaunched_from_dlq: deadLetterId,
    relaunched_by: ctx.userId,
    created_at: Timestamp.now(),
    updated_at: Timestamp.now(),
  });

  await dlqRef.update({
    relaunched_at: FieldValue.serverTimestamp(),
    relaunched_by: ctx.userId,
    relaunched_into_job_id: newJob.id,
  });

  logInfo({
    message: `DLQ ${deadLetterId} relancé en job ${newJob.id}`,
    moduleType: "IMPORT",
    jobId: newJob.id, userId: ctx.userId, correlationId: ctx.correlationId,
    extra: { deadLetterId, originalJobId },
  });

  return { newJobId: newJob.id };
});

/** Supprime définitivement un dead letter. */
export const deleteDeadLetterFn = onCall(adminOpts, async (req) => {
  const ctx = await requireAdmin(req);
  const { deadLetterId } = (req.data ?? {}) as { deadLetterId?: string };
  if (!deadLetterId) throw new HttpsError("invalid-argument", "deadLetterId requis.");

  await getFirestore().collection(COLL_DEAD_LETTERS).doc(deadLetterId).delete();

  logInfo({
    message: `DLQ ${deadLetterId} supprimé`,
    moduleType: "IMPORT",
    userId: ctx.userId, correlationId: ctx.correlationId,
    extra: { deadLetterId },
  });

  return { success: true };
});
