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
import {
  REGION,
  COLL_PROCESSING_JOBS,
  COLL_SCAN_SPEND,
  PROJECT_ID,
  taskQueueFunctionFor,
} from "../config";
import { raiseImportCeiling, scanOwnerConflict } from "../ai/importBudget";
import { logInfo, logError, newCorrelationId, newScanId, qualify } from "../logging";

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

    // Le fil de l'import tout entier naît ici.
    //
    // Il s'appelait « disp », du nom de ce déclencheur. Or ce n'est pas lui
    // qu'il désigne : `recipeProcessor` reçoit ce même identifiant dans son
    // payload et journalise tout le traitement dessous. L'écran titrait donc
    // « Mise en file du traitement » un groupe qui contenait l'extraction, la
    // normalisation et l'enregistrement — d'où la question, légitime, « où est
    // la partie importation ? ». Elle était là, sous un nom de couloir.
    const correlationId = newCorrelationId("import_recette");

    // Le scan est l'acte de l'utilisateur ; ce traitement n'en est qu'une
    // étape. Le client le pose sur le job au moment de l'envoi, et il couvre
    // aussi le contrôle du fichier, qui a eu lieu avant que ce job existe.
    // Un job créé avant l'existence du champ n'en a pas : on en fabrique un,
    // qui rassemblera au moins l'import et ses suites.
    let scanId = typeof job.scan_id === "string" && job.scan_id ? job.scan_id : newScanId();

    // On n'enqueue que les jobs en état queued (évite l'enqueue sur édition manuelle).
    if (job.status && job.status !== "queued") {
      // Ce déclencheur part à CHAQUE écriture du job — queued, processing,
      // done — et la plupart du temps il n'a rien à faire. Chacun de ces
      // constats ouvrait son propre fil : trois groupes « Mise en file du
      // traitement » d'un message chacun, pour un import qui n'a été mis en
      // file qu'une fois. Le job porte déjà le fil de son import : on s'y
      // rattache, et le suivi du statut se lit à sa place, dans l'import.
      const existing = typeof job.correlation_id === "string" ? job.correlation_id : "";
      logInfo({
        message: `Job ${jobId} écrit avec status=${job.status}, pas d'enqueue`,
        moduleType: "IMPORT",
        jobId,
        userId,
        scanId,
        correlationId: existing || qualify("import_recette", "suivi-du-job"),
      });
      return;
    }

    // Le job était DÉJÀ en queued avant cette écriture : rien n'y est entré.
    // C'est le cas de notre propre marquage (correlation_id, dispatched_at)
    // juste en dessous — sans cette garde, il se redéclencherait sans fin.
    if (before?.status === "queued") return;

    // À la création, le `scan_id` vient du client. Il ne doit pas désigner le
    // compteur d'un autre compte : un éditeur qui reprenait le `scan_id` d'un
    // import d'autrui relevait son plafond et y imputait ses dépenses. Un
    // import de livre reçoit toujours un identifiant tiré ici ; un autre job
    // garde le sien, sauf si le compteur existant appartient à un autre compte.
    // Ensuite, le client ne peut plus changer `scan_id` (règles Firestore) :
    // une relance garde celui qu'on écrit plus bas.
    if (!before) {
      const clientScanId = scanId;
      try {
        const existingOwner =
          job.type === "bookDocumentScan"
            ? null
            : (await getFirestore().collection(COLL_SCAN_SPEND).doc(clientScanId).get()).get(
                "user_id",
              );
        const next = dispatchScanId({
          clientScanId,
          jobType: job.type,
          existingOwner,
          userId,
          generate: newScanId,
        });
        if (next !== clientScanId) {
          scanId = next;
          logInfo({
            message: "scan_id du client remplacé par un identifiant serveur",
            moduleType: "IMPORT",
            jobId,
            userId,
            scanId,
            extra: { clientScanId, jobType: job.type ?? null },
          });
        }
      } catch (err) {
        // Lecture impossible : on ne fait pas confiance au client.
        scanId = newScanId();
        await logError({
          message: "Propriétaire du scan illisible — identifiant serveur tiré à la place",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "IMPORT",
          jobId,
          userId,
          scanId,
          extra: { clientScanId },
        });
      }
    }

    // Une tranche de livre qui revient en `queued` après avoir existé est une
    // relance de l'utilisateur. Si l'import a atteint son plafond, la relance
    // l'ouvre d'un palier : sans cela, la tranche échouerait au même endroit.
    // Une création n'a pas d'état précédent, et n'y touche pas.
    if (before && job.book_window) {
      try {
        await raiseImportCeiling({ scanId, userId, jobId });
      } catch (err) {
        // Best-effort : la tranche est mise en file quand même. Si le plafond n'a
        // pas pu être relevé, elle s'arrêtera à nouveau, et l'erreur le dit.
        await logError({
          message: "Plafond de l'import non relevé par la relance",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "IMPORT",
          jobId,
          userId,
          scanId,
        });
      }
    }

    try {
      // Marque le job avec le correlationId avant enqueue (traçabilité).
      await getFirestore().collection(COLL_PROCESSING_JOBS).doc(jobId).update({
        correlation_id: correlationId,
        // Réécrit même quand il vient du client : une relance passe ici, et le
        // processeur doit retrouver le même scan qu'à la première tentative.
        scan_id: scanId,
        dispatched_at: Timestamp.now(),
      });

      // Nom de ressource complet requis : sans cela, Cloud Tasks cherche
      // la queue dans us-central1 et renvoie "Queue does not exist".
      const queueResource = `projects/${PROJECT_ID}/locations/${REGION}/functions/${taskQueueFunctionFor(job.type)}`;
      const queue = getFunctions().taskQueue(queueResource);
      await queue.enqueue(
        { jobId, userId, correlationId, scanId },
        {
          // Cloud Tasks ajoutera retryCount automatiquement aux retries.
          dispatchDeadlineSeconds: 540,
        },
      );

      logInfo({
        message: `Job enqueued dans ${queueResource}`,
        moduleType: "IMPORT",
        jobId,
        userId,
        correlationId,
        scanId,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError({
        message: "Échec enqueue Cloud Tasks",
        errorDescription: message,
        moduleType: "IMPORT",
        jobId,
        userId,
        correlationId,
        scanId,
      });
      await getFirestore()
        .collection(COLL_PROCESSING_JOBS)
        .doc(jobId)
        .update({
          status: "error",
          error_message: `Dispatcher: ${message}`,
          updated_at: Timestamp.now(),
        });
    }
  },
);

/**
 * Le `scan_id` d'un job à sa création. Pure, pour être testée.
 *
 * Un import de livre (`bookDocumentScan`) reçoit toujours un identifiant neuf :
 * c'est lui qui pose un plafond. Un autre job garde l'identifiant du client —
 * il relie le contrôle du fichier, passé avant le job, à son import — sauf si
 * le compteur existant appartient à un autre compte.
 */
export function dispatchScanId(args: {
  clientScanId: string;
  jobType: unknown;
  existingOwner: unknown;
  userId: string;
  generate: () => string;
}): string {
  if (args.jobType === "bookDocumentScan") return args.generate();
  if (scanOwnerConflict(args.existingOwner, args.userId)) return args.generate();
  return args.clientScanId;
}
