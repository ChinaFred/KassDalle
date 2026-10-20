/**
 * deadLetterHandler — Callable functions admin (Phase 1.7).
 *
 * Expose les actions admin sur les dead letters :
 *  - relancer : recrée un processing_job (status=queued) à partir du DLQ,
 *    et met à jour dead_letters/{id}.relaunched_at, dans une même
 *    transaction ; un dead letter déjà relancé est refusé
 *  - supprimer : hard delete du document DLQ
 *
 * Les opérations sont protégées par requireAdmin().
 *
 * Le déclenchement du passage en DLQ est géré directement par
 * recipeProcessor lorsqu'il a épuisé ses retries (cf. moveToDeadLetter).
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { REGION, COLL_DEAD_LETTERS, COLL_PROCESSING_JOBS, MAX_CALLABLE_INSTANCES } from "../config";
import { requireAdmin } from "../callable/_auth";
import { logInfo } from "../logging";
import { isValidDocumentId } from "../moderation/promote";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const adminOpts = { region: REGION, cors: ALLOWED_ORIGINS, maxInstances: MAX_CALLABLE_INSTANCES };

export const ALREADY_RELAUNCHED_MESSAGE = "Ce job a déjà été relancé.";
const ORIGINAL_DELETED_MESSAGE = "Job original supprimé, relance impossible.";

/**
 * Refus de relancer un dead letter, ou `null` si permis. Pure et exportée pour
 * être testée.
 *
 * `dlq` nul : le document n'existe pas. `relaunched_at` non nul : une relance a
 * déjà eu lieu — un double appui, ou deux onglets ouverts sur l'écran, créaient
 * deux jobs, donc deux imports facturés. `originalExists` faux : le job
 * d'origine a été supprimé, ou son identifiant est illisible.
 */
export function relaunchDenial(args: {
  dlq: Record<string, unknown> | null;
  originalExists: boolean;
}): { code: "not-found" | "failed-precondition"; message: string } | null {
  if (args.dlq == null) return { code: "not-found", message: "Dead letter introuvable." };
  if (args.dlq.relaunched_at != null) {
    return { code: "failed-precondition", message: ALREADY_RELAUNCHED_MESSAGE };
  }
  if (!args.originalExists) {
    return { code: "failed-precondition", message: ORIGINAL_DELETED_MESSAGE };
  }
  return null;
}

/**
 * Relance un DLQ : copie les infos du job original (s'il existe encore) et crée
 * un nouveau processing_job avec status=queued, ce qui déclenche jobDispatcher.
 *
 * Une seule transaction lit le dead letter, vérifie `relaunched_at`, crée le
 * job et marque le dead letter : deux appels simultanés ne créent qu'un job,
 * le second reçoit `failed-precondition` (« Ce job a déjà été relancé. »).
 */
export const relaunchDeadLetterFn = onCall(adminOpts, async (req) => {
  const ctx = await requireAdmin(req, "relance_job_en_echec");
  const { deadLetterId } = (req.data ?? {}) as { deadLetterId?: unknown };
  if (!isValidDocumentId(deadLetterId)) {
    throw new HttpsError("invalid-argument", "deadLetterId requis.");
  }

  const db = getFirestore();
  const dlqRef = db.collection(COLL_DEAD_LETTERS).doc(deadLetterId);
  const newJob = db.collection(COLL_PROCESSING_JOBS).doc();

  const originalJobId = await db.runTransaction(async (tx) => {
    const dlqSnap = await tx.get(dlqRef);
    const dlq = dlqSnap.exists ? (dlqSnap.data() ?? {}) : null;
    const originalId = dlq?.original_job_id;
    const originalSnap = isValidDocumentId(originalId)
      ? await tx.get(db.collection(COLL_PROCESSING_JOBS).doc(originalId))
      : null;
    const denial = relaunchDenial({ dlq, originalExists: originalSnap?.exists === true });
    if (denial) throw new HttpsError(denial.code, denial.message);
    const original = originalSnap!.data() ?? {};

    tx.set(newJob, {
      ...original,
      status: "queued",
      current_step: "queued",
      error_message: null,
      error_code: null,
      error_id: null,
      attempt_count: 0,
      created_recipe_ids: [],
      relaunched_from: originalId,
      relaunched_from_dlq: deadLetterId,
      relaunched_by: ctx.userId,
      created_at: Timestamp.now(),
      updated_at: Timestamp.now(),
    });
    tx.update(dlqRef, {
      relaunched_at: FieldValue.serverTimestamp(),
      relaunched_by: ctx.userId,
      relaunched_into_job_id: newJob.id,
    });
    return originalId as string;
  });

  logInfo({
    message: `DLQ ${deadLetterId} relancé en job ${newJob.id}`,
    moduleType: "IMPORT",
    jobId: newJob.id,
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    extra: { deadLetterId, originalJobId },
  });

  return { newJobId: newJob.id };
});

/** Supprime définitivement un dead letter. */
export const deleteDeadLetterFn = onCall(adminOpts, async (req) => {
  const ctx = await requireAdmin(req, "suppression_job_en_echec");
  const { deadLetterId } = (req.data ?? {}) as { deadLetterId?: unknown };
  if (!isValidDocumentId(deadLetterId)) {
    throw new HttpsError("invalid-argument", "deadLetterId requis.");
  }

  await getFirestore().collection(COLL_DEAD_LETTERS).doc(deadLetterId).delete();

  logInfo({
    message: `DLQ ${deadLetterId} supprimé`,
    moduleType: "IMPORT",
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    extra: { deadLetterId },
  });

  return { success: true };
});
