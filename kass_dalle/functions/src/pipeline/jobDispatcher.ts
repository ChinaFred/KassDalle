/**
 * jobDispatcher — Firestore trigger (Phase 1.6).
 *
 * Déclenché quand un document `processing_jobs/{id}` ENTRE en état `queued` :
 * à sa création, et à chaque relance qui l'y ramène. Génère un correlationId,
 * log l'événement et enqueue une tâche Cloud Tasks vers `recipeProcessor`.
 *
 * Le déclencheur n'écoutait autrefois que la création. Une relance remettait
 * bien le job en `queued`, mais rien ne le réenquêtait : le client rejouait
 * alors son propre pipeline d'import, en parallèle de celui-ci et avec un code
 * différent. Un même fichier pouvait donner deux recettes différentes selon
 * qu'il avait été importé ou relancé.
 *
 * Pour bénéficier de la résolution automatique d'URL+OIDC, on utilise
 * `getFunctions().taskQueue("recipeProcessor")` (Firebase SDK Admin v12+).
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getFunctions } from "firebase-admin/functions";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { REGION, COLL_PROCESSING_JOBS, PROJECT_ID, TASK_QUEUE_FUNCTION } from "../config";
import { logInfo, logError, newCorrelationId } from "../logging";

export const jobDispatcher = onDocumentWritten(
  {
    region: REGION,
    document: `${COLL_PROCESSING_JOBS}/{jobId}`,
  },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) return; // suppression

    const jobId = event.params.jobId;
    const job = after.data() as Record<string, unknown>;
    const before = event.data?.before?.data() as Record<string, unknown> | undefined;
    const userId = (job.created_by as string) ?? "unknown";
    const correlationId = newCorrelationId("disp");

    // On n'enqueue que les jobs en état queued (évite l'enqueue sur édition manuelle).
    if (job.status && job.status !== "queued") {
      logInfo({
        message: `Job ${jobId} écrit avec status=${job.status}, pas d'enqueue`,
        moduleType: "IMPORT", jobId, userId, correlationId,
      });
      return;
    }

    // Le job était DÉJÀ en queued avant cette écriture : rien n'y est entré.
    // C'est le cas de notre propre marquage (correlation_id, dispatched_at)
    // juste en dessous — sans cette garde, il se redéclencherait sans fin.
    if (before?.status === "queued") return;

    try {
      // Marque le job avec le correlationId avant enqueue (traçabilité).
      await getFirestore().collection(COLL_PROCESSING_JOBS).doc(jobId).update({
        correlation_id: correlationId,
        dispatched_at: Timestamp.now(),
      });

      // Nom de ressource complet requis : sans cela, Cloud Tasks cherche
      // la queue dans us-central1 et renvoie "Queue does not exist".
      const queueResource = `projects/${PROJECT_ID}/locations/${REGION}/functions/${TASK_QUEUE_FUNCTION}`;
      const queue = getFunctions().taskQueue(queueResource);
      await queue.enqueue(
        { jobId, userId, correlationId },
        {
          // Cloud Tasks ajoutera retryCount automatiquement aux retries.
          dispatchDeadlineSeconds: 540,
        },
      );

      logInfo({
        message: `Job enqueued dans ${queueResource}`,
        moduleType: "IMPORT",
        jobId, userId, correlationId,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError({
        message: "Échec enqueue Cloud Tasks",
        errorDescription: message,
        moduleType: "IMPORT",
        jobId, userId, correlationId,
      });
      await getFirestore().collection(COLL_PROCESSING_JOBS).doc(jobId).update({
        status: "error",
        error_message: `Dispatcher: ${message}`,
        updated_at: Timestamp.now(),
      });
    }
  },
);
