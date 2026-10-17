/**
 * Décisions de l'administrateur sur un ticket : « Valider », « Refuser »,
 * « Répondre » à la dernière analyse et « Clore ».
 *
 * Appelées par `validateTicket`, `refuseTicket`, `answerTicketAnalysis` et
 * `closeTicket` (`callable/ticketsCallable.ts`),
 * après `requireAdmin`. Les conditions sont pures (`tickets/rules.ts`) ; ce
 * module appelle GitHub puis écrit le ticket par `applyGithubUpdate`, sans
 * attendre le webhook.
 *
 * Valider : relit l'Issue (fermée → l'état relu est appliqué et l'appel
 * échoue), pose l'étiquette `validé`, écrit `validated` et la date du
 * « validé » (`admin/analysis.validated_at`). Idempotent.
 *
 * Refuser : bail de deux minutes `decision_lease_until` pris en transaction
 * (deux refus simultanés ne publient pas deux motifs), relit l'Issue et ses
 * commentaires, publie `Réponse : <motif>` sauf si la dernière réponse du
 * mainteneur le porte déjà (reprise après échec partiel), ferme l'Issue
 * `not_planned`, écrit `refused` et `reply_text`. Le bail est libéré à la fin.
 *
 * Répondre : même bail, relit l'Issue et ses commentaires, publie
 * `## Précisions de l'administrateur` sauf si une réponse suit déjà la
 * dernière analyse (reprise après échec partiel), passe les étiquettes à
 * `statut:à-analyser` (pose `statut:à-analyser`, puis retire `statut:analysé`
 * et `validé`), et ramène le ticket à Reçu (`applyGithubUpdate` avec
 * `answerReset`). Rien n'est lancé.
 *
 * Clore : même bail, relit l'Issue et ses commentaires, publie
 * `Réponse : <commentaire>` sauf si la dernière réponse du mainteneur le
 * porte déjà, pose l'étiquette `statut:clos`, ferme l'Issue `completed`
 * (ordre : commentaire, étiquette, fermeture), écrit `closed` et `reply_text`.
 * Refusé tant qu'une livraison de ce ticket court. La PR ouverte d'un ticket
 * En cours n'est pas fermée.
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

import {
  COLL_APP_CONFIG,
  COLL_TICKETS,
  GITHUB_TICKETS_MAINTAINER_ID,
  TICKETS_STATUS_DOC_ID,
  TICKET_ADMIN_SUBCOLLECTION,
  TICKET_LAUNCHES_DOC_ID,
} from "../config";
import {
  deliveryBlockedAtMs,
  deliveryLockView,
  lastAnalysisMillis,
  launchEntryViews,
  storedValidatedAt,
} from "./stored";
import { deliveryRef } from "./delivery";
import { logError, logInfo, logWarn } from "../logging";
import {
  GithubError,
  addIssueLabels,
  closeIssueCompleted,
  closeIssueNotPlanned,
  createIssueComment,
  getIssue,
  githubToken,
  listIssueComments,
  removeIssueLabel,
  type RemoteComment,
} from "./github";
import {
  ANSWER_PARTIAL_REASON,
  CLOSE_DELIVERY_RUNNING_MESSAGE,
  CLOSE_PARTIAL_REASON,
  LABEL_ANALYZED,
  LABEL_CLOSED,
  LABEL_TO_ANALYZE,
  LABEL_VALIDATED,
  REFUSAL_PARTIAL_REASON,
  ANSWER_DEVELOPMENT_RUNNING_MESSAGE,
  analysisAnswerState,
  answerCommentBody,
  answerPrecondition,
  closePrecondition,
  deliveryLockActive,
  launchRunState,
  readAnswerCommentIds,
  ticketAwaitingReply,
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
  analysisRef,
  recordAnswerCommentId,
  updateValidatedAt,
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

function readMillis(raw: unknown): number | null {
  return raw instanceof Timestamp ? raw.toMillis() : null;
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
  /** `status_changed_at` du ticket, en millisecondes, ou `null`. */
  statusChangedAtMs: number | null;
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
    const verdict = check({
      status: readStatus(data),
      type: readType(data),
      issueNumber,
      statusChangedAtMs: readMillis(data.status_changed_at),
    });
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
      await recordValidatedAt(ticketId, scope);
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

/**
 * Écrit la date du « validé » qui vient d'être posé : une analyse publiée
 * après elle bloquera le développement. Au mieux : le webhook `labeled` et la
 * tâche horaire l'écrivent aussi.
 */
async function recordValidatedAt(ticketId: string, scope: LogScope): Promise<void> {
  try {
    await updateValidatedAt(ticketId, Date.now(), true);
  } catch (err) {
    await logError({
      message: `Tickets : date de validation du ticket ${ticketId} non écrite (le webhook et la tâche horaire la reprendront)`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
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

// ── Répondre à la dernière analyse ──────────────────────────────────────────

/**
 * Enregistre l'identifiant du commentaire publié (`answer_comment_ids`). Au
 * mieux : un échec est journalisé ; le commentaire s'affiche alors « Non
 * publiée depuis l'application », et une reprise le republierait.
 */
async function rememberAnswerComment(
  ticketId: string,
  issueNumber: number,
  commentId: number | null,
  scope: LogScope,
): Promise<void> {
  try {
    if (commentId === null) throw new Error("réponse de GitHub sans identifiant de commentaire");
    await recordAnswerCommentId(ticketId, commentId);
  } catch (err) {
    await logError({
      message: `Tickets : réponse publiée sur l'Issue #${issueNumber} mais son identifiant n'est pas enregistré (ticket ${ticketId})`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { comment_id: commentId },
    });
  }
}

/** Journalise une étiquette déjà absente au moment de la retirer (404). */
async function removeLabelLogged(
  token: string,
  issueNumber: number,
  label: string,
  ticketId: string,
  scope: LogScope,
): Promise<void> {
  if ((await removeIssueLabel(token, issueNumber, label)) === "removed") return;
  await logInfo({
    message: `Tickets : étiquette « ${label} » déjà absente de l'Issue #${issueNumber} au moment de la retirer (ticket ${ticketId})`,
    correlationId: scope.correlationId,
    userId: scope.userId,
    firestoreDocId: ticketId,
    feature: "tickets",
    extra: { issue_number: issueNumber, label },
  });
}

/**
 * Vrai si un lancement est en cours : une analyse sur un ticket Reçu, un
 * développement sur un ticket Validé non bloqué. « Répondre » est alors refusé. Un ticket bloqué (dernière analyse
 * postérieure au dernier « validé ») accepte une réponse même si son dernier
 * lancement n'a pas atteint son échéance : la session s'est arrêtée sur cette
 * analyse.
 */
async function developmentRunning(
  ticketId: string,
  type: TicketType,
  status: TicketStatus,
  statusChangedAtMs: number | null,
  analysisData: FirebaseFirestore.DocumentData | undefined,
): Promise<boolean> {
  if (status !== "validated" && status !== "received") return false;
  const awaiting = ticketAwaitingReply({
    rawStatus: status,
    type,
    lastAnalysisAtMs: lastAnalysisMillis(analysisData),
    validatedAtMs: storedValidatedAt(analysisData),
  });
  if (awaiting) return false;
  const launches = await ticketRef(ticketId)
    .collection(TICKET_ADMIN_SUBCOLLECTION)
    .doc(TICKET_LAUNCHES_DOC_ID)
    .get();
  return launchRunState({
    entries: launchEntryViews(launches.data()),
    action: status === "received" ? "analyse" : "developpement",
    rawStatus: status,
    nowMs: Date.now(),
    statusChangedAtMs,
    analysisPublishedAtMs: lastAnalysisMillis(analysisData),
  }).running;
}

/**
 * Publie la réponse de l'administrateur à la dernière analyse et ramène le
 * ticket à Reçu. Sur un ticket déjà Reçu, sans analyse, elle publie les
 * précisions seulement : ni statut ni étiquettes ne changent. Idempotente
 * après une analyse : une reprise après un échec partiel ne republie pas le
 * commentaire si la réponse déjà publiée depuis l'application
 * (`answer_comment_ids`) porte le même texte. Rien n'est lancé.
 */
export async function answerTicketDecision(
  ticketId: string,
  text: string,
  scope: LogScope,
): Promise<{ status: TicketStatus }> {
  const seen: { type: TicketType; status: TicketStatus; statusChangedAtMs: number | null } = {
    type: "question",
    status: "sending",
    statusChangedAtMs: null,
  };
  const claimed = await claimDecision(
    ticketId,
    ({ status, type, issueNumber: n, statusChangedAtMs }) => {
      seen.type = type;
      seen.status = status;
      seen.statusChangedAtMs = statusChangedAtMs;
      const refusal = answerPrecondition({ status, type, hasIssue: n !== null });
      return refusal === null
        ? { kind: "go" }
        : { kind: "refused", message: refusal, reason: "not_answerable" };
    },
  );
  // Le contrôle d'une réponse ne rend jamais « rien à faire ».
  if (claimed === null) throw new Error(`réponse au ticket ${ticketId} : bail rendu sans Issue`);
  const issueNumber = claimed;
  try {
    const analysisData = (await analysisRef(ticketId).get()).data();
    if (
      await developmentRunning(
        ticketId,
        seen.type,
        seen.status,
        seen.statusChangedAtMs,
        analysisData,
      )
    ) {
      throw new HttpsError("failed-precondition", ANSWER_DEVELOPMENT_RUNNING_MESSAGE, {
        reason: "launch_running",
      });
    }
    const answerIds = readAnswerCommentIds(analysisData?.answer_comment_ids);
    const body = answerCommentBody(text);

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
    if (issue.state === "closed") {
      await applyGithubUpdate(ticketId, {
        statusFor: (t) => statusFromIssue({ ...issue, hasOpenClosingPr: false }, t),
        issueUpdatedAt: issue.updatedAt,
      });
      throw new HttpsError("failed-precondition", "Ce ticket a déjà été clos sur GitHub.", {
        reason: "issue_closed",
      });
    }

    const state = analysisAnswerState(comments, GITHUB_TICKETS_MAINTAINER_ID, answerIds, body);
    const beforeAnalysis = seen.status === "received";
    if (!state.hasAnalysis && !beforeAnalysis) {
      throw new HttpsError("failed-precondition", "Aucune analyse à laquelle répondre.", {
        reason: "no_analysis",
      });
    }
    if (!state.samePublished) {
      let published: RemoteComment;
      try {
        published = await createIssueComment(token, issueNumber, body);
      } catch (err) {
        throw await githubFailure(err, ticketId, "publication de la réponse", scope);
      }
      await rememberAnswerComment(ticketId, issueNumber, published.id, scope);
    }

    // Ordre choisi pour qu'aucun état intermédiaire ne dépasse le statut de
    // départ : à-analyser posée d'abord, puis analysé et validé retirées.
    try {
      // Ticket Reçu : les étiquettes de l'Issue restent telles quelles.
      if (!beforeAnalysis && !issue.labels.includes(LABEL_TO_ANALYZE)) {
        await addIssueLabels(token, issueNumber, [LABEL_TO_ANALYZE]);
      }
      if (!beforeAnalysis && issue.labels.includes(LABEL_ANALYZED)) {
        await removeLabelLogged(token, issueNumber, LABEL_ANALYZED, ticketId, scope);
      }
      if (!beforeAnalysis && issue.labels.includes(LABEL_VALIDATED)) {
        await removeLabelLogged(token, issueNumber, LABEL_VALIDATED, ticketId, scope);
      }
    } catch (err) {
      const kind = err instanceof GithubError ? err.kind : "other";
      await logError({
        message: `Tickets : réponse publiée mais étiquettes de l'Issue #${issueNumber} inchangées (ticket ${ticketId})`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
        extra: { kind, step: "étiquettes", reponse_deja_publiee: state.samePublished },
      });
      if (kind === "token") await markTokenInvalid(scope, describe(err));
      throw new HttpsError(
        "aborted",
        "Réponse publiée, mais le statut n'a pas changé. Réessayez.",
        {
          reason: ANSWER_PARTIAL_REASON,
        },
      );
    }

    try {
      if (!beforeAnalysis) await applyGithubUpdate(ticketId, { answerReset: true });
    } catch (err) {
      await logError({
        message: `Tickets : réponse publiée sur l'Issue #${issueNumber} mais ticket ${ticketId} non ramené à Reçu`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError(
        "internal",
        "Réponse publiée sur GitHub, mais le ticket n'a pas été mis à jour. Réessayez.",
        { reason: "ticket_not_updated" },
      );
    }
    await refreshAnalysesAfterDecision(ticketId, null, token, issueNumber, scope);
    await logInfo({
      message: `Tickets : réponse à l'analyse du ticket ${ticketId} publiée (Issue #${issueNumber}), ticket ${beforeAnalysis ? "resté" : "repassé"} à Reçu`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { reponse_deja_publiee: state.samePublished },
    });
    return { status: "received" };
  } finally {
    await releaseDecision(ticketId, scope);
  }
}

// ── Clore ───────────────────────────────────────────────────────────────────

/**
 * Vrai si une livraison de ce ticket court : le dernier lancement de
 * livraison est « en cours » (`launchRunState`), ou le verrou global des
 * livraisons porte ce ticket et tient encore (`deliveryLockActive`).
 */
async function deliveryRunningOn(
  ticketId: string,
  status: TicketStatus,
  statusChangedAtMs: number | null,
): Promise<boolean> {
  const [launches, delivery, statusDoc] = await Promise.all([
    ticketRef(ticketId).collection(TICKET_ADMIN_SUBCOLLECTION).doc(TICKET_LAUNCHES_DOC_ID).get(),
    deliveryRef(ticketId).get(),
    getFirestore().collection(COLL_APP_CONFIG).doc(TICKETS_STATUS_DOC_ID).get(),
  ]);
  const run = launchRunState({
    entries: launchEntryViews(launches.data()),
    action: "livraison",
    rawStatus: status,
    nowMs: Date.now(),
    statusChangedAtMs,
    deliveryBlockedAtMs: deliveryBlockedAtMs(delivery.data()),
  });
  if (run.running) return true;
  const lock = deliveryLockView(statusDoc.data()?.delivery_running);
  if (lock === null || lock.ticketId !== ticketId) return false;
  return deliveryLockActive({ lock, lockedTicketRawStatus: status, nowMs: Date.now() });
}

export async function closeTicketDecision(
  ticketId: string,
  comment: string,
  scope: LogScope,
): Promise<{ status: TicketStatus }> {
  const seen: { status: TicketStatus; statusChangedAtMs: number | null } = {
    status: "sending",
    statusChangedAtMs: null,
  };
  const claimed = await claimDecision(ticketId, ({ status, issueNumber: n, statusChangedAtMs }) => {
    seen.status = status;
    seen.statusChangedAtMs = statusChangedAtMs;
    const refusal = closePrecondition({ status, hasIssue: n !== null });
    return refusal === null
      ? { kind: "go" }
      : { kind: "refused", message: refusal, reason: "not_closable" };
  });
  // Le contrôle de la clôture ne rend jamais « rien à faire » : sans numéro, c'est un défaut.
  if (claimed === null) throw new Error(`clôture du ticket ${ticketId} : bail rendu sans Issue`);
  const issueNumber = claimed;
  try {
    if (await deliveryRunningOn(ticketId, seen.status, seen.statusChangedAtMs)) {
      throw new HttpsError("failed-precondition", CLOSE_DELIVERY_RUNNING_MESSAGE, {
        reason: "delivery_running",
      });
    }
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
    const alreadyPublished = sameReply(previous, comment);

    if (issue.state === "closed") {
      const closedWithThisComment = alreadyPublished && issue.labels.includes(LABEL_CLOSED);
      await applyGithubUpdate(ticketId, {
        statusFor: (t) => statusFromIssue({ ...issue, hasOpenClosingPr: false }, t),
        reply: previous,
      });
      if (closedWithThisComment) {
        // Reprise d'une clôture déjà faite sur GitHub dont l'écriture du ticket
        // avait échoué : l'état relu vient d'être appliqué.
        await refreshAnalysesAfterDecision(ticketId, comments, token, issueNumber, scope);
        return { status: "closed" };
      }
      throw new HttpsError("failed-precondition", "Ce ticket a déjà été clos sur GitHub.", {
        reason: "issue_closed",
      });
    }

    if (!alreadyPublished) {
      try {
        await createIssueComment(token, issueNumber, refusalCommentBody(comment));
      } catch (err) {
        throw await githubFailure(err, ticketId, "publication du commentaire de clôture", scope);
      }
    }

    let step = "étiquette";
    try {
      if (!issue.labels.includes(LABEL_CLOSED)) {
        await addIssueLabels(token, issueNumber, [LABEL_CLOSED]);
      }
      step = "fermeture";
      await closeIssueCompleted(token, issueNumber);
    } catch (err) {
      const kind = err instanceof GithubError ? err.kind : "other";
      await logError({
        message: `Tickets : commentaire de clôture publié mais Issue #${issueNumber} non fermée (ticket ${ticketId})`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
        extra: { kind, step },
      });
      if (kind === "token") await markTokenInvalid(scope, describe(err));
      throw new HttpsError(
        "aborted",
        "Commentaire publié, mais l'Issue n'a pas été fermée. Réessayez.",
        { reason: CLOSE_PARTIAL_REASON },
      );
    }

    try {
      await applyGithubUpdate(ticketId, { statusFor: () => "closed", reply: comment });
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
        "La clôture est faite sur GitHub, mais le ticket n'a pas été mis à jour. Réessayez.",
        { reason: "ticket_not_updated" },
      );
    }
    await refreshAnalysesAfterDecision(ticketId, comments, token, issueNumber, scope);
    await logInfo({
      message: `Tickets : ticket ${ticketId} clos (Issue #${issueNumber})`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { commentaire_deja_publie: alreadyPublished },
    });
    return { status: "closed" };
  } finally {
    await releaseDecision(ticketId, scope);
  }
}
