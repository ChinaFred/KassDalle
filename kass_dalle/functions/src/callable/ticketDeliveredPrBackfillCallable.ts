/**
 * PR des tickets livrés — écrit `delivered_pr_number` et `delivered_pr_url`
 * sur chaque ticket `delivered` qui n'en porte pas, depuis la PR fusionnée qui
 * a fermé son Issue, sans appel de modèle.
 *
 * Depuis ce passage, le webhook de fermeture, la tâche horaire et
 * `resyncTicket` tiennent les deux champs à jour. Les tickets livrés avant
 * restent sans numéro : ce ponctuel les reprend une fois.
 *
 * Réentrant : un ticket qui porte déjà un numéro est sauté. Un ticket livré
 * sans PR retrouvable (Issue fermée à la main) est compté « sans PR » et listé
 * dans « À revoir ». Un à deux appels GitHub par ticket. Bornes : délai, 100
 * tickets repris par passage, trois échecs de suite ; un jeton refusé ou une
 * limite de débit arrête le passage.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_TICKETS, GITHUB_TICKETS_TOKEN, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { recordDeliveredPr } from "../tickets/delivery";
import { GithubError, githubToken } from "../tickets/github";
import { markTokenInvalid } from "../tickets/service";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  shortErrorMessage,
  withoutReviewList,
  type BackfillReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "ticket_delivered_pr_backfill";

/** Tickets repris par appel. */
const MAX_DOCS = 100;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois tickets difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

export interface BackfillTicketDeliveredPrResponse {
  /** Tickets livrés examinés. */
  examines: number;
  /** Tickets dont la PR a été écrite. */
  ecrits: number;
  /** Ticket qui porte déjà un numéro : sauté. */
  dejaAJour: number;
  /** Aucune PR n'a fermé l'Issue : listé dans « À revoir ». */
  sansPr: number;
  echoues: number;
  /** Tickets livrés pas encore examinés à l'arrêt du passage. */
  restants: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  aRevoir: BackfillReviewList;
}

interface BackfillTicketDeliveredPrRequest {
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export const backfillTicketDeliveredPrFn = onCall<BackfillTicketDeliveredPrRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
    secrets: [GITHUB_TICKETS_TOKEN],
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);
    return runBackfillFromCallable({
      key: "ticket_delivered_pr",
      ctx,
      appVersion: req.data?.appVersion,
      summarize: summarizeTicketDeliveredPr,
      run: () => runTicketDeliveredPrPass(ctx),
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeTicketDeliveredPr(r: BackfillTicketDeliveredPrResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restants,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Sans appel de modèle : un ticket en échec ou sans PR reste dans la liste
    // à revoir, ce qui empêche déjà de marquer le backfill terminé.
    unresolved: 0,
  };
}

/** Un passage sur les tickets livrés, borné par le délai d'une fonction. */
async function runTicketDeliveredPrPass(
  ctx: AuthContext,
): Promise<BackfillTicketDeliveredPrResponse> {
  const deadline = Date.now() + 540_000 - DEADLINE_MARGIN_MS;
  const response: BackfillTicketDeliveredPrResponse = {
    examines: 0,
    ecrits: 0,
    dejaAJour: 0,
    sansPr: 0,
    echoues: 0,
    restants: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
  const review = new BackfillReview();
  const scope = { correlationId: ctx.correlationId, userId: ctx.userId };

  const tickets = await getFirestore()
    .collection(COLL_TICKETS)
    .where("status", "==", "delivered")
    .get();
  const token = githubToken();
  if (token === null) {
    await markTokenInvalid(scope, "secret GITHUB_TICKETS_TOKEN vide (backfill des PR livrées)");
    response.stoppedByErrors = true;
    response.restants = tickets.size;
    // Aucun ticket relu : le reste non nul empêche de marquer le backfill terminé.
    return response;
  }

  let consecutiveFailures = 0;
  for (const doc of tickets.docs) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    if (response.ecrits >= MAX_DOCS) {
      response.stoppedByBudget = true;
      break;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      break;
    }
    response.examines += 1;
    const data = doc.data() as Record<string, unknown>;
    if (data.delivered_pr_number != null) {
      response.dejaAJour += 1;
      continue;
    }
    const issueNumber = data.github_issue_number;
    if (typeof issueNumber !== "number" || !Number.isSafeInteger(issueNumber) || issueNumber <= 0) {
      response.sansPr += 1;
      review.add({ kind: "ticket", id: doc.id, label: doc.id, reason: "Aucune Issue liée" });
      continue;
    }
    try {
      const outcome = await recordDeliveredPr(token, doc.id, issueNumber);
      consecutiveFailures = 0;
      if (outcome === "written") {
        response.ecrits += 1;
      } else if (outcome === "no_pr") {
        response.sansPr += 1;
        review.add({
          kind: "ticket",
          id: doc.id,
          label: `Issue #${issueNumber}`,
          reason: "Aucune PR fusionnée n'a fermé l'Issue (fermée à la main ?)",
        });
      }
    } catch (e) {
      const kind = e instanceof GithubError ? e.kind : "other";
      response.echoues += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "ticket",
        id: doc.id,
        label: `Issue #${issueNumber}`,
        reason:
          kind === "not_found"
            ? "Issue introuvable sur GitHub"
            : `Échec de relecture : ${shortErrorMessage(e)}`,
      });
      await logError("PR des tickets livrés — échec sur un ticket", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        firestoreDocId: doc.id,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { issueNumber, kind, consecutiveFailures },
      });
      if (kind === "token") {
        await markTokenInvalid(scope, e instanceof Error ? e.message : String(e));
        response.stoppedByErrors = true;
        break;
      }
      if (kind === "rate_limit") {
        response.stoppedByErrors = true;
        break;
      }
    }
  }
  response.restants = tickets.size - response.examines;
  response.completed = response.restants === 0 && !response.stoppedByErrors;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "PR des tickets livrés — passage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response) },
  });

  return response;
}
