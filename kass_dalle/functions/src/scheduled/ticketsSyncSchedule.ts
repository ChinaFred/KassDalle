/**
 * `ticketsSyncSchedule` — reprise des envois et resynchronisation des tickets,
 * toutes les heures.
 *
 * 1. Reprise : chaque ticket `sending` sans numéro d'Issue, avec moins de
 *    `TICKET_MAX_SEND_ATTEMPTS` essais, repart (`sendTicket`, avec recherche
 *    préalable d'une Issue déjà créée). Au-delà, le ticket est « en anomalie »
 *    et attend « Relancer l'envoi » dans Admin › Tickets.
 * 2. Resynchronisation : chaque ticket non final publié est relu sur GitHub
 *    (état, étiquettes, PR ouvertes qui le ferment, réponse de
 *    l'administrateur) — rattrape un webhook perdu.
 *
 * Un jeton absent ou refusé arrête la passe : `token_invalid_since` est posé,
 * les tickets suivants ne sont pas essayés et n'usent pas leurs essais.
 * Chaque ticket est traité seul : une erreur est journalisée et la passe
 * continue.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_TICKETS, GITHUB_TICKETS_TOKEN, REGION, TICKET_MAX_SEND_ATTEMPTS } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { GithubError, githubToken } from "../tickets/github";
import {
  clearTokenInvalid,
  markTokenInvalid,
  resyncTicket,
  sendTicket,
  type LogScope,
} from "../tickets/service";

/** Statuts relus sur GitHub. Les fins ne le sont pas (spécification V1). */
const RESYNC_STATUSES = ["received", "analyzed", "validated", "in_progress"];

/** Plafond de tickets traités par passe, pour tenir dans le délai. */
const MAX_PER_PASS = 200;

async function retryPendingSends(scope: LogScope): Promise<{ sent: number; failed: number }> {
  const snap = await getFirestore()
    .collection(COLL_TICKETS)
    .where("status", "==", "sending")
    .limit(MAX_PER_PASS)
    .get();
  let sent = 0;
  let failed = 0;
  for (const doc of snap.docs) {
    const data = doc.data();
    if (data.github_issue_number != null) continue;
    const attempts = typeof data.send_attempts === "number" ? data.send_attempts : 0;
    if (attempts >= TICKET_MAX_SEND_ATTEMPTS) continue;
    const outcome = await sendTicket(doc.id, scope, { lookupFirst: true });
    if (outcome.status === "received") sent++;
    if (outcome.failure !== null) failed++;
    if (outcome.failure === "token") break;
  }
  return { sent, failed };
}

async function resyncOpenTickets(
  token: string,
  scope: LogScope,
): Promise<{ changed: number; failed: number }> {
  const snap = await getFirestore()
    .collection(COLL_TICKETS)
    .where("status", "in", RESYNC_STATUSES)
    .limit(MAX_PER_PASS)
    .get();
  let changed = 0;
  let failed = 0;
  let reachedGithub = false;
  for (const doc of snap.docs) {
    const issueNumber = doc.data().github_issue_number;
    if (typeof issueNumber !== "number") continue;
    try {
      if (await resyncTicket(token, doc.id, issueNumber)) changed++;
      reachedGithub = true;
    } catch (err) {
      failed++;
      const kind = err instanceof GithubError ? err.kind : "other";
      await logError({
        message: `ticketsSyncSchedule : ticket ${doc.id} (Issue #${issueNumber}) non resynchronisé`,
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: scope.correlationId,
        firestoreDocId: doc.id,
        feature: "tickets",
        extra: { kind },
      });
      if (kind === "token") {
        await markTokenInvalid(scope, err instanceof Error ? err.message : String(err));
        break;
      }
      if (kind === "rate_limit") break;
    }
  }
  if (reachedGithub) await clearTokenInvalid(scope);
  return { changed, failed };
}

export const ticketsSyncSchedule = onSchedule(
  {
    schedule: "every 60 minutes",
    timeZone: "Europe/Paris",
    region: REGION,
    memory: "256MiB",
    timeoutSeconds: 300,
    retryCount: 0,
    secrets: [GITHUB_TICKETS_TOKEN],
  },
  async () => {
    const scope: LogScope = { correlationId: newCorrelationId("tickets_sync") };
    try {
      const token = githubToken();
      if (token === null) {
        await markTokenInvalid(scope, "secret GITHUB_TICKETS_TOKEN vide");
        return;
      }
      const resend = await retryPendingSends(scope);
      const resync = await resyncOpenTickets(token, scope);
      await logInfo({
        message:
          `ticketsSyncSchedule : ${resend.sent} ticket(s) envoyé(s), ${resend.failed} échec(s) ; ` +
          `${resync.changed} ticket(s) mis à jour, ${resync.failed} échec(s) de relecture`,
        correlationId: scope.correlationId,
        feature: "tickets",
      });
    } catch (err) {
      await logError({
        message: "ticketsSyncSchedule : passe interrompue",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: scope.correlationId,
        feature: "tickets",
      });
    }
  },
);
