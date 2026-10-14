/**
 * Décisions de l'administrateur sur un ticket : « Valider » et « Refuser ».
 *
 * Appelées par `validateTicket` et `refuseTicket` (`callable/ticketsCallable.ts`),
 * après `requireAdmin`. Les conditions sont pures (`tickets/rules.ts`) ; ce
 * module appelle GitHub puis écrit le ticket par `applyGithubUpdate`, sans
 * attendre le webhook.
 *
 * Valider : relit l'Issue (fermée → l'état relu est appliqué et l'appel
 * échoue), pose l'étiquette `validé`, écrit `validated`. Idempotent.
 *
 * Refuser : bail de deux minutes `decision_lease_until` pris en transaction
 * (deux refus simultanés ne publient pas deux motifs), relit l'Issue et ses
 * commentaires, publie `Réponse : <motif>` sauf si la dernière réponse du
 * mainteneur le porte déjà (reprise après échec partiel), ferme l'Issue
 * `not_planned`, écrit `refused` et `reply_text`. Le bail est libéré à la fin.
 *
 * Après chaque décision, les analyses du ticket sont réécrites (au mieux :
 * un échec est journalisé, la décision reste faite).
 *
 * Le bail (`claimDecision`, `releaseDecision`) et la traduction des échecs
 * GitHub (`githubFailure`, `tokenMissing`) servent aussi aux lancements de
 * sessions (`tickets/launch.ts`) : un lancement ne part pas pendant qu'une
 * décision tourne, et inversement.
 */

import { HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import { COLL_TICKETS } from "../config";
import { logError, logInfo, logWarn } from "../logging";
import {
  GithubError,
  addIssueLabels,
  closeIssueNotPlanned,
  createIssueComment,
  getIssue,
  githubToken,
  listIssueComments,
  type RemoteComment,
} from "./github";
import {
  LABEL_VALIDATED,
  REFUSAL_PARTIAL_REASON,
  decisionGithubFailure,
  isTicketType,
  shouldWriteValidated,
  storedTicketStatus,
  refusalCommentBody,
  refusePrecondition,
  sameReply,
  statusFromIssue,
  validatePrecondition,
  type TicketStatus,
  type TicketType,
} from "./rules";
import {
  applyGithubUpdate,
  lastReply,
  markTokenInvalid,
  writeTicketAnalyses,
  type LogScope,
} from "./service";

/** Durée du bail d'une décision, sur le modèle de `send_lease_until`. */
export const DECISION_LEASE_MS = 2 * 60 * 1000;

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function ticketRef(ticketId: string) {
  return getFirestore().collection(COLL_TICKETS).doc(ticketId);
}

function readStatus(data: FirebaseFirestore.DocumentData): TicketStatus {
  return storedTicketStatus(data.status);
}

function readType(data: FirebaseFirestore.DocumentData): TicketType {
  return isTicketType(data.type) ? data.type : "question";
}

function readIssueNumber(data: FirebaseFirestore.DocumentData): number | null {
  const n = data.github_issue_number;
  return typeof n === "number" && Number.isSafeInteger(n) && n > 0 ? n : null;
}

/**
 * Traduit un échec GitHub en `HttpsError`, après `logError`. Un jeton refusé
 * pose aussi `token_invalid_since`.
 */
export async function githubFailure(
  err: unknown,
  ticketId: string,
  step: string,
  scope: LogScope,
): Promise<HttpsError> {
  const kind = err instanceof GithubError ? err.kind : "other";
  await logError({
    message: `Tickets : décision sur le ticket ${ticketId} en échec (${step})`,
    errorDescription: describe(err),
    correlationId: scope.correlationId,
    userId: scope.userId,
    firestoreDocId: ticketId,
    feature: "tickets",
    extra: { kind, step },
  });
  if (kind === "token") await markTokenInvalid(scope, describe(err));
  const failure = decisionGithubFailure(kind);
  return new HttpsError(failure.code, failure.message, { reason: failure.reason });
}

/** Réécrit les analyses après une décision. Au mieux, journalisé. */
async function refreshAnalysesAfterDecision(
  ticketId: string,
  comments: readonly RemoteComment[] | null,
  token: string,
  issueNumber: number,
  scope: LogScope,
): Promise<void> {
  try {
    const list = comments ?? (await listIssueComments(token, issueNumber));
    await writeTicketAnalyses(ticketId, list);
  } catch (err) {
    await logError({
      message: `Tickets : analyses du ticket ${ticketId} non réécrites après la décision`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}

export async function tokenMissing(ticketId: string, scope: LogScope): Promise<HttpsError> {
  return githubFailure(
    new GithubError("token", null, "Jeton GitHub absent (secret GITHUB_TICKETS_TOKEN vide)."),
    ticketId,
    "jeton",
    scope,
  );
}

// ── Bail de décision ────────────────────────────────────────────────────────

/** Ce qu'une décision vérifie sur le ticket lu dans la transaction du bail. */
export type DecisionCheck = (args: {
  status: TicketStatus;
  type: TicketType;
  issueNumber: number | null;
}) => { kind: "go" } | { kind: "skip" } | { kind: "refused"; message: string; reason: string };

/**
 * Prend le bail de décision (`decision_lease_until`, deux minutes) en
 * transaction, après `check`. Valider, Refuser et les deux lancements
 * partagent ce bail : l'un ne part pas pendant que l'autre tourne. Rend `null` quand `check` dit qu'il n'y
 * a rien à faire (aucun bail pris), sinon le numéro d'Issue. Lève
 * `failed-precondition` si la décision n'est pas permise ou si le bail est pris.
 */
export async function claimDecision(
  ticketId: string,
  check: DecisionCheck,
): Promise<number | null> {
  const ref = ticketRef(ticketId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Ce ticket n'existe plus.", { reason: "ticket_not_found" });
    }
    const data = snap.data() ?? {};
    const issueNumber = readIssueNumber(data);
    const verdict = check({ status: readStatus(data), type: readType(data), issueNumber });
    if (verdict.kind === "skip") return null;
    if (verdict.kind === "refused" || issueNumber === null) {
      throw new HttpsError(
        "failed-precondition",
        verdict.kind === "refused" ? verdict.message : "Ce ticket n'a pas encore d'Issue GitHub.",
        { reason: verdict.kind === "refused" ? verdict.reason : "no_issue" },
      );
    }
    const lease = data.decision_lease_until;
    if (lease instanceof Timestamp && lease.toMillis() > Date.now()) {
      throw new HttpsError("failed-precondition", "Une décision est déjà en cours sur ce ticket.", {
        reason: "decision_in_progress",
      });
    }
    tx.update(ref, { decision_lease_until: Timestamp.fromMillis(Date.now() + DECISION_LEASE_MS) });
    return issueNumber;
  });
}

// ── Valider ─────────────────────────────────────────────────────────────────

/**
 * Écrit `validated` seulement si le ticket est encore `analyzed`, relu dans
 * la transaction d'écriture : un refus ou un retour de GitHub arrivé pendant
 * la validation n'est pas écrasé. Rend le statut du ticket après l'écriture.
 */
async function writeValidatedIfAnalyzed(
  ticketId: string,
): Promise<{ status: TicketStatus; changed: boolean }> {
  const ref = ticketRef(ticketId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) {
      throw new HttpsError("not-found", "Ce ticket n'existe plus.", { reason: "ticket_not_found" });
    }
    const current = readStatus(snap.data() ?? {});
    if (!shouldWriteValidated(current)) return { status: current, changed: false };
    const now = FieldValue.serverTimestamp();
    tx.update(ref, { status: "validated", status_changed_at: now, updated_at: now });
    return { status: "validated" as TicketStatus, changed: true };
  });
}

export async function validateTicketDecision(
  ticketId: string,
  scope: LogScope,
): Promise<{ status: TicketStatus; changed: boolean }> {
  const issueNumber = await claimDecision(ticketId, ({ status, type, issueNumber: n }) => {
    const pre = validatePrecondition({ status, type, hasIssue: n !== null });
    if (pre.kind === "already") return { kind: "skip" };
    if (pre.kind === "refused") {
      return { kind: "refused", message: pre.message, reason: "not_validatable" };
    }
    return { kind: "go" };
  });
  if (issueNumber === null) return { status: "validated", changed: false };

  try {
    const token = githubToken();
    if (token === null) throw await tokenMissing(ticketId, scope);

    let issue: Awaited<ReturnType<typeof getIssue>>;
    try {
      issue = await getIssue(token, issueNumber);
    } catch (err) {
      throw await githubFailure(err, ticketId, "lecture de l'Issue", scope);
    }
    if (issue.state === "closed") {
      await applyGithubUpdate(ticketId, {
        statusFor: (t) => statusFromIssue({ ...issue, hasOpenClosingPr: false }, t),
      });
      throw new HttpsError("failed-precondition", "Ce ticket a déjà été clos sur GitHub.", {
        reason: "issue_closed",
      });
    }

    if (!issue.labels.includes(LABEL_VALIDATED)) {
      try {
        await addIssueLabels(token, issueNumber, [LABEL_VALIDATED]);
      } catch (err) {
        throw await githubFailure(err, ticketId, "étiquette validé", scope);
      }
    }

    const written = await writeValidatedIfAnalyzed(ticketId);
    if (!written.changed && written.status !== "validated") {
      await logWarn({
        message: `Tickets : étiquette validé posée sur l'Issue #${issueNumber}, mais le ticket ${ticketId} est passé à ${written.status} entre-temps : statut laissé tel quel`,
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
    }
    await refreshAnalysesAfterDecision(ticketId, null, token, issueNumber, scope);
    await logInfo({
      message: `Tickets : ticket ${ticketId} validé (Issue #${issueNumber})`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
    return written;
  } finally {
    await releaseDecision(ticketId, scope);
  }
}

// ── Refuser ─────────────────────────────────────────────────────────────────

/** Libère le bail. Au mieux : un échec est journalisé, le bail expire seul. */
export async function releaseDecision(ticketId: string, scope: LogScope): Promise<void> {
  try {
    await ticketRef(ticketId).update({ decision_lease_until: FieldValue.delete() });
  } catch (err) {
    await logError({
      message: `Tickets : bail de décision du ticket ${ticketId} non libéré (expire seul en 2 min)`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}

export async function refuseTicketDecision(
  ticketId: string,
  reason: string,
  scope: LogScope,
): Promise<{ status: TicketStatus }> {
  const claimed = await claimDecision(ticketId, ({ status, issueNumber: n }) => {
    const refusal = refusePrecondition({ status, hasIssue: n !== null });
    return refusal === null
      ? { kind: "go" }
      : { kind: "refused", message: refusal, reason: "not_refusable" };
  });
  // Le contrôle du refus ne rend jamais « rien à faire » : sans numéro, c'est un défaut.
  if (claimed === null) throw new Error(`refus du ticket ${ticketId} : bail rendu sans Issue`);
  const issueNumber = claimed;
  try {
    const token = githubToken();
    if (token === null) throw await tokenMissing(ticketId, scope);

    let issue: Awaited<ReturnType<typeof getIssue>>;
    let comments: RemoteComment[];
    try {
      issue = await getIssue(token, issueNumber);
      comments = await listIssueComments(token, issueNumber);
    } catch (err) {
      throw await githubFailure(err, ticketId, "lecture de l'Issue", scope);
    }
    const previous = lastReply(comments);
    const alreadyPublished = sameReply(previous, reason);

    if (issue.state === "closed") {
      const refusedWithThisReason =
        alreadyPublished &&
        (issue.stateReason === "not_planned" || issue.stateReason === "duplicate");
      await applyGithubUpdate(ticketId, {
        statusFor: (t) => statusFromIssue({ ...issue, hasOpenClosingPr: false }, t),
        reply: previous,
      });
      if (refusedWithThisReason) {
        // Reprise d'un refus déjà fait sur GitHub dont l'écriture du ticket
        // avait échoué : l'état relu vient d'être appliqué.
        await refreshAnalysesAfterDecision(ticketId, comments, token, issueNumber, scope);
        return { status: "refused" };
      }
      throw new HttpsError("failed-precondition", "Ce ticket a déjà été clos sur GitHub.", {
        reason: "issue_closed",
      });
    }

    if (!alreadyPublished) {
      try {
        await createIssueComment(token, issueNumber, refusalCommentBody(reason));
      } catch (err) {
        throw await githubFailure(err, ticketId, "publication du motif", scope);
      }
    }

    try {
      await closeIssueNotPlanned(token, issueNumber);
    } catch (err) {
      const kind = err instanceof GithubError ? err.kind : "other";
      await logError({
        message: `Tickets : motif publié mais Issue #${issueNumber} non fermée (ticket ${ticketId})`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
        extra: { kind, step: "fermeture" },
      });
      if (kind === "token") await markTokenInvalid(scope, describe(err));
      throw new HttpsError("aborted", "Motif publié, mais l'Issue n'a pas été fermée. Réessayez.", {
        reason: REFUSAL_PARTIAL_REASON,
      });
    }

    try {
      await applyGithubUpdate(ticketId, { statusFor: () => "refused", reply: reason });
    } catch (err) {
      await logError({
        message: `Tickets : Issue #${issueNumber} fermée mais ticket ${ticketId} non mis à jour`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError(
        "internal",
        "Le refus est fait sur GitHub, mais le ticket n'a pas été mis à jour. Réessayez.",
        { reason: "ticket_not_updated" },
      );
    }
    await refreshAnalysesAfterDecision(ticketId, comments, token, issueNumber, scope);
    await logInfo({
      message: `Tickets : ticket ${ticketId} refusé (Issue #${issueNumber})`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { motif_deja_publie: alreadyPublished },
    });
    return { status: "refused" };
  } finally {
    await releaseDecision(ticketId, scope);
  }
}
