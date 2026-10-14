/**
 * Analyses des tickets — écrit `tickets/{id}/admin/analysis` pour chaque
 * ticket publié sur GitHub, depuis les commentaires de son Issue, sans appel
 * de modèle.
 *
 * Depuis v0.23.62, le webhook (commentaire du mainteneur), la tâche horaire
 * (`resyncTicket`) et les décisions tiennent ce sous-document à jour. Les
 * analyses publiées avant restent sur GitHub seulement : ce ponctuel les
 * relève une fois.
 *
 * Réentrant : un ticket dont le sous-document existe déjà est sauté. Un
 * ticket sans numéro d'Issue (envoi en cours) est ignoré. Un appel GitHub par
 * ticket (deux au-delà de cent commentaires). Bornes : délai, 200 tickets
 * écrits par passage, trois échecs de suite ; un jeton refusé ou une limite
 * de débit arrête le passage.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_TICKETS, GITHUB_TICKETS_TOKEN, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { GithubError, githubToken } from "../tickets/github";
import { analysisRef, markTokenInvalid, refreshTicketAnalyses } from "../tickets/service";
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

const FEATURE = "ticket_analyses_backfill";

/** Tickets écrits par appel. */
const MAX_DOCS = 200;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois tickets difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

export interface BackfillTicketAnalysesResponse {
  examines: number;
  /** Sous-documents écrits. */
  ecrits: number;
  /** Analyses relevées, tous tickets confondus. */
  analyses: number;
  /** Sous-document déjà présent : sauté. */
  dejaAJour: number;
  /** Pas encore d'Issue (envoi en cours) : ignoré. */
  sansIssue: number;
  echoues: number;
  /** Tickets pas encore examinés à l'arrêt du passage. */
  restants: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  /** Tickets en échec, nommés, avec la raison. */
  aRevoir: BackfillReviewList;
}

interface BackfillTicketAnalysesRequest {
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export const backfillTicketAnalysesFn = onCall<BackfillTicketAnalysesRequest>(
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
      key: "ticket_analyses",
      ctx,
      appVersion: req.data?.appVersion,
      summarize: summarizeTicketAnalyses,
      run: () => runTicketAnalysesPass(ctx),
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeTicketAnalyses(r: BackfillTicketAnalysesResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restants,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Sans appel de modèle : un ticket en échec reste dans la liste à revoir,
    // ce qui empêche déjà de marquer le backfill terminé.
    unresolved: 0,
  };
}

function ticketLabel(id: string, data: Record<string, unknown>): string {
  const n = data.github_issue_number;
  return typeof n === "number" ? `Issue #${n}` : id;
}

/** Un passage sur tous les tickets, borné par le délai d'une fonction. */
async function runTicketAnalysesPass(ctx: AuthContext): Promise<BackfillTicketAnalysesResponse> {
  const db = getFirestore();
  const deadline = Date.now() + 540_000 - DEADLINE_MARGIN_MS;
  const response: BackfillTicketAnalysesResponse = {
    examines: 0,
    ecrits: 0,
    analyses: 0,
    dejaAJour: 0,
    sansIssue: 0,
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

  // Quelques centaines de tickets au plus : la collection tient en une lecture.
  const tickets = await db.collection(COLL_TICKETS).get();
  const token = githubToken();
  if (token === null) {
    await markTokenInvalid(scope, "secret GITHUB_TICKETS_TOKEN vide (backfill des analyses)");
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
    const issueNumber = data.github_issue_number;
    if (typeof issueNumber !== "number" || !Number.isSafeInteger(issueNumber) || issueNumber <= 0) {
      response.sansIssue += 1;
      continue;
    }
    try {
      const existing = await analysisRef(doc.id).get();
      if (existing.exists) {
        response.dejaAJour += 1;
        consecutiveFailures = 0;
        continue;
      }
      response.analyses += await refreshTicketAnalyses(token, doc.id, issueNumber);
      response.ecrits += 1;
      consecutiveFailures = 0;
    } catch (e) {
      const kind = e instanceof GithubError ? e.kind : "other";
      response.echoues += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "ticket",
        id: doc.id,
        label: ticketLabel(doc.id, data),
        reason:
          kind === "not_found"
            ? "Issue introuvable sur GitHub"
            : `Échec de relecture : ${shortErrorMessage(e)}`,
      });
      await logError("Analyses des tickets — échec sur un ticket", {
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
    message: "Analyses des tickets — passage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response) },
  });

  return response;
}
