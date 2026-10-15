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
 *    l'administrateur, analyses et comptes rendus de livraison) — rattrape
 *    un webhook perdu. Un ticket En cours relit aussi son état « PR prête »
 *    (`refreshTicketDelivery` : PR éligible, dernier run de la CI), sur une
 *    liste des PR ouvertes lue une fois par passe.
 *
 * 3. PR de livraison : un ticket livré depuis moins de trois jours sans
 *    `delivered_pr_number` est relu (`recordDeliveredPr`), si le webhook de
 *    fermeture a été perdu.
 *
 * Un jeton absent ou refusé arrête la passe : `token_invalid_since` est posé,
 * les tickets suivants ne sont pas essayés et n'usent pas leurs essais.
 * Chaque ticket est traité seul : une erreur est journalisée et la passe
 * continue.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_TICKETS, GITHUB_TICKETS_TOKEN, REGION, TICKET_MAX_SEND_ATTEMPTS } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { GithubError, githubToken, listOpenPullRequests } from "../tickets/github";
import {
  recordDeliveredPr,
  refreshTicketDelivery,
  type OpenPullRequests,
} from "../tickets/delivery";
import {
  clearTokenInvalid,
  markTokenInvalid,
  resyncTicket,
  sendTicket,
  type LogScope,
} from "../tickets/service";

/** Statuts relus sur GitHub. Les fins ne le sont pas (spécification V1). */
const RESYNC_STATUSES = ["received", "analyzed", "validated", "in_progress"];

/**
 * Un ticket livré depuis moins de trois jours sans PR de livraison est relu :
 * rattrape un webhook perdu. Au-delà, le backfill « PR des tickets livrés »
 * reprend le fonds, et une Issue fermée à la main n'est pas relue chaque heure.
 */
const DELIVERED_PR_WINDOW_MS = 3 * 24 * 60 * 60 * 1000;

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
  // Lue au premier ticket En cours, puis partagée par la passe.
  let openPrs: OpenPullRequests | null = null;
  for (const doc of snap.docs) {
    const issueNumber = doc.data().github_issue_number;
    if (typeof issueNumber !== "number") continue;
    try {
      if (await resyncTicket(token, doc.id, issueNumber, scope)) changed++;
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
      continue;
    }
    // Statut relu après la resynchronisation : seul un ticket encore En
    // cours a une livraison à préparer.
    try {
      const status = (await doc.ref.get()).data()?.status;
      if (status === "in_progress") {
        openPrs ??= await listOpenPullRequests(token);
        await refreshTicketDelivery(token, doc.id, issueNumber, openPrs);
      }
    } catch (err) {
      failed++;
      const kind = err instanceof GithubError ? err.kind : "other";
      await logError({
        message: `ticketsSyncSchedule : état « PR prête » du ticket ${doc.id} (Issue #${issueNumber}) non relu`,
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

async function catchUpDeliveredPrs(
  token: string,
  scope: LogScope,
): Promise<{ written: number; failed: number }> {
  const snap = await getFirestore()
    .collection(COLL_TICKETS)
    .where("status", "==", "delivered")
    .limit(MAX_PER_PASS)
    .get();
  const since = Date.now() - DELIVERED_PR_WINDOW_MS;
  let written = 0;
  let failed = 0;
  for (const doc of snap.docs) {
    const data = doc.data();
    const issueNumber = data.github_issue_number;
    if (typeof issueNumber !== "number" || data.delivered_pr_number != null) continue;
    const changedAt = data.status_changed_at;
    if (!(changedAt instanceof Timestamp) || changedAt.toMillis() < since) continue;
    try {
      if ((await recordDeliveredPr(token, doc.id, issueNumber)) === "written") written++;
    } catch (err) {
      failed++;
      const kind = err instanceof GithubError ? err.kind : "other";
      await logError({
        message: `ticketsSyncSchedule : PR de livraison du ticket ${doc.id} (Issue #${issueNumber}) non relevée`,
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
  return { written, failed };
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
      const deliveredPrs = await catchUpDeliveredPrs(token, scope);
      await logInfo({
        message:
          `ticketsSyncSchedule : ${resend.sent} ticket(s) envoyé(s), ${resend.failed} échec(s) ; ` +
          `${resync.changed} ticket(s) mis à jour, ${resync.failed} échec(s) de relecture ; ` +
          `${deliveredPrs.written} PR de livraison relevée(s), ${deliveredPrs.failed} échec(s)`,
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
