/**
 * Tickets : envoi vers GitHub et application des retours de statut.
 *
 * Partagé par les callables (`callable/ticketsCallable.ts`), le webhook
 * (`tickets/webhook.ts`) et la tâche horaire
 * (`scheduled/ticketsSyncSchedule.ts`). Les règles de décision vivent dans
 * `tickets/rules.ts`, pures ; ce module lit et écrit.
 *
 * Envoi d'un ticket (`sendTicket`) :
 *  1. un bail de deux minutes (`send_lease_until`) est pris en transaction :
 *     deux envois simultanés du même ticket — la tâche horaire et un
 *     « Relancer l'envoi » — ne publient pas deux Issues ;
 *  2. sur une reprise, l'Issue est d'abord cherchée par la référence du
 *     ticket : une création réussie chez GitHub dont le numéro n'a pas été
 *     écrit ne repart pas une seconde fois ;
 *  3. succès : `github_issue_number`, `github_url` et `status: received` sont
 *     écrits avant que l'envoi soit tenu pour fait ;
 *  4. échec : `send_attempts` + 1, `last_send_error`, `logError`. Un jeton
 *     absent ou refusé n'use pas les essais — il pose
 *     `app_config/tickets_status.token_invalid_since`, et les tickets
 *     repartent au remplacement du jeton.
 */

import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_APP_CONFIG,
  COLL_TICKETS,
  GITHUB_TICKETS_MAINTAINER_ID,
  TICKET_ADMIN_SUBCOLLECTION,
  TICKET_ANALYSIS_DOC_ID,
  TICKETS_STATUS_DOC_ID,
} from "../config";
import { logError, logInfo, logWarn } from "../logging";
import { recordDeliveredPr, writeDeliveryReports } from "./delivery";
import {
  GITHUB_REPO_FULL_NAME,
  GithubError,
  createIssue,
  findIssueByTicketReference,
  getIssue,
  githubToken,
  lastValidatedLabelAt,
  listIssueComments,
  openPullRequestBodiesReferencing,
  type CreatedIssue,
  type RemoteComment,
} from "./github";
import {
  analysesFromComments,
  buildIssueBody,
  buildIssueTitle,
  closingIssueNumbers,
  creationLabels,
  isFinalStatus,
  isTicketStatus,
  isTicketType,
  isStaleIssueSnapshot,
  LABEL_VALIDATED,
  nextTicketStatus,
  openClosingPrFromTimeline,
  nextValidatedAt,
  readAnswerCommentIds,
  replyFromComment,
  statusFromIssue,
  type TicketPlatform,
  type TicketStatus,
  type TicketType,
} from "./rules";

const SEND_LEASE_MS = 2 * 60 * 1000;

export interface LogScope {
  correlationId: string;
  userId?: string;
}

function ticketRef(ticketId: string) {
  return getFirestore().collection(COLL_TICKETS).doc(ticketId);
}

/** `tickets/{id}/admin/analysis` : analyses du mainteneur, lecture admin seule. */
export function analysisRef(ticketId: string) {
  return ticketRef(ticketId).collection(TICKET_ADMIN_SUBCOLLECTION).doc(TICKET_ANALYSIS_DOC_ID);
}

function statusRef() {
  return getFirestore().collection(COLL_APP_CONFIG).doc(TICKETS_STATUS_DOC_ID);
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Statut lu sur un document ; une valeur inconnue se lit `sending`. */
function readStatus(data: FirebaseFirestore.DocumentData | undefined): TicketStatus {
  const status = data?.status;
  return isTicketStatus(status) ? status : "sending";
}

// ── État du jeton ───────────────────────────────────────────────────────────

/** Pose `token_invalid_since` s'il ne l'est pas déjà. Best-effort, journalisé. */
export async function markTokenInvalid(scope: LogScope, reason: string): Promise<void> {
  try {
    const db = getFirestore();
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(statusRef());
      if (snap.data()?.token_invalid_since instanceof Timestamp) return;
      tx.set(statusRef(), { token_invalid_since: Timestamp.now() }, { merge: true });
    });
    await logError({
      message: `Tickets : jeton GitHub invalide ou absent — ${reason}`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      feature: "tickets",
    });
  } catch (err) {
    await logError({
      message: "Tickets : état du jeton GitHub non enregistré",
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      feature: "tickets",
    });
  }
}

/** Efface `token_invalid_since` au premier succès. Best-effort, journalisé. */
export async function clearTokenInvalid(scope: LogScope): Promise<void> {
  try {
    const snap = await statusRef().get();
    if (snap.data()?.token_invalid_since == null) return;
    await statusRef().set({ token_invalid_since: null }, { merge: true });
    await logInfo({
      message: "Tickets : jeton GitHub de nouveau accepté",
      correlationId: scope.correlationId,
      feature: "tickets",
    });
  } catch (err) {
    await logError({
      message: "Tickets : effacement de l'alerte du jeton GitHub impossible",
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      feature: "tickets",
    });
  }
}

// ── Envoi ───────────────────────────────────────────────────────────────────

/** Résultat d'un envoi : le statut du ticket et, en échec, le genre d'erreur. */
export interface SendOutcome {
  status: TicketStatus;
  failure: GithubError["kind"] | "firestore" | null;
}

/**
 * Prend le bail d'envoi. `null` si le ticket n'a rien à envoyer (déjà parti,
 * autre statut) ou si un autre envoi est en cours ; sinon ses données.
 */
async function claimSend(
  ticketId: string,
): Promise<{ data: FirebaseFirestore.DocumentData } | { skip: TicketStatus }> {
  const ref = ticketRef(ticketId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new Error(`ticket ${ticketId} introuvable`);
    const data = snap.data() ?? {};
    const status = readStatus(data);
    if (status !== "sending" || data.github_issue_number != null) return { skip: status };
    const lease = data.send_lease_until;
    if (lease instanceof Timestamp && lease.toMillis() > Date.now()) return { skip: status };
    tx.update(ref, { send_lease_until: Timestamp.fromMillis(Date.now() + SEND_LEASE_MS) });
    return { data };
  });
}

async function recordSent(ticketId: string, issue: CreatedIssue): Promise<void> {
  const now = FieldValue.serverTimestamp();
  await ticketRef(ticketId).update({
    status: "received",
    github_issue_number: issue.number,
    github_url: issue.url,
    status_changed_at: now,
    updated_at: now,
    last_send_error: null,
    send_lease_until: FieldValue.delete(),
  });
}

async function recordFailure(
  ticketId: string,
  message: string,
  countsAsAttempt: boolean,
): Promise<void> {
  await ticketRef(ticketId).update({
    send_attempts: FieldValue.increment(countsAsAttempt ? 1 : 0),
    last_send_error: message.slice(0, 300),
    updated_at: FieldValue.serverTimestamp(),
    send_lease_until: FieldValue.delete(),
  });
}

/**
 * Publie l'Issue d'un ticket « Envoi en cours ».
 *
 * Ne lève pas : rend le statut du ticket après l'essai. `lookupFirst` cherche
 * d'abord une Issue déjà créée (reprise) ; le premier envoi s'en passe.
 */
export async function sendTicket(
  ticketId: string,
  scope: LogScope,
  opts: { lookupFirst: boolean },
): Promise<SendOutcome> {
  let claimed: Awaited<ReturnType<typeof claimSend>>;
  try {
    claimed = await claimSend(ticketId);
  } catch (err) {
    await logError({
      message: `Tickets : envoi du ticket ${ticketId} impossible à préparer`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
    return { status: "sending", failure: "firestore" };
  }
  if ("skip" in claimed) return { status: claimed.skip, failure: null };
  const data = claimed.data;

  const token = githubToken();
  if (token === null) {
    const message = "Jeton GitHub absent (secret GITHUB_TICKETS_TOKEN vide).";
    await safeRecordFailure(ticketId, message, false, scope);
    await markTokenInvalid(scope, message);
    return { status: "sending", failure: "token" };
  }

  let issue: CreatedIssue | null = null;
  try {
    if (opts.lookupFirst) issue = await findIssueByTicketReference(token, ticketId);
    if (issue !== null) {
      await logWarn({
        message: `Tickets : Issue #${issue.number} déjà créée pour le ticket ${ticketId}, rattachée sans nouvel envoi`,
        correlationId: scope.correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
    } else {
      const type: TicketType = isTicketType(data.type) ? data.type : "question";
      issue = await createIssue(token, {
        title: buildIssueTitle(String(data.title ?? "")),
        body: buildIssueBody({
          ticketId,
          type,
          description: String(data.description ?? ""),
          screen: String(data.screen ?? "inconnu"),
          app_version: String(data.app_version ?? "?"),
          platform: (data.platform ?? "web") as TicketPlatform,
        }),
        labels: creationLabels(type),
      });
    }
  } catch (err) {
    const kind = err instanceof GithubError ? err.kind : "other";
    const message = describe(err);
    await logError({
      message: `Tickets : envoi du ticket ${ticketId} vers GitHub en échec`,
      errorDescription: message,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { kind, attempts_before: data.send_attempts ?? 0 },
    });
    await safeRecordFailure(ticketId, message, kind !== "token", scope);
    if (kind === "token") await markTokenInvalid(scope, message);
    return { status: "sending", failure: kind };
  }

  try {
    await recordSent(ticketId, issue);
  } catch (err) {
    // L'Issue existe, le numéro n'est pas écrit : la reprise horaire la
    // retrouvera par sa référence au lieu d'en publier une seconde.
    await logError({
      message: `Tickets : Issue #${issue.number} créée mais non enregistrée sur le ticket ${ticketId}`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { issue_number: issue.number },
    });
    return { status: "sending", failure: "firestore" };
  }
  await logInfo({
    message: `Tickets : ticket ${ticketId} publié en Issue #${issue.number}`,
    correlationId: scope.correlationId,
    userId: scope.userId,
    firestoreDocId: ticketId,
    feature: "tickets",
  });
  await clearTokenInvalid(scope);
  return { status: "received", failure: null };
}

async function safeRecordFailure(
  ticketId: string,
  message: string,
  countsAsAttempt: boolean,
  scope: LogScope,
): Promise<void> {
  try {
    await recordFailure(ticketId, message, countsAsAttempt);
  } catch (err) {
    await logError({
      message: `Tickets : échec d'envoi du ticket ${ticketId} non enregistré`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}

// ── Retours de GitHub ───────────────────────────────────────────────────────

/** Ce qu'un événement GitHub propose pour un ticket. */
export interface GithubUpdate {
  /** Statut dérivé de l'Issue, selon le type du ticket. */
  statusFor?: (type: TicketType) => TicketStatus;
  /**
   * `true` : une PR ouverte référence l'Issue, le ticket avance à `in_progress`,
   * jamais depuis une fin. `false` : les PR ont été relues (`resyncTicket`) et
   * aucune ne ferme plus l'Issue, un ticket `in_progress` revient au statut de
   * ses étiquettes. Absent : les PR ne sont pas connues, rien ne recule.
   */
  openClosingPr?: boolean;
  /** Réponse de l'administrateur, déjà filtrée. */
  reply?: string;
  /**
   * Dernière modification de l'Issue dont vient `statusFor` (ISO). Un état
   * antérieur ou égal au dernier retour à « Reçu » d'une réponse
   * (`answer_reset_at`) est ignoré : un événement d'étiquette livré en retard
   * ne refait pas avancer le ticket.
   */
  issueUpdatedAt?: string | null;
  /**
   * Seule exception à « le statut ne recule jamais » : l'administrateur a
   * répondu à la dernière analyse (`answerTicketAnalysis`) et les étiquettes
   * de l'Issue sont repassées à `statut:à-analyser`. Un ticket Analysé ou
   * Validé repasse à Reçu, et `answer_reset_at` est écrit.
   */
  answerReset?: boolean;
}

/**
 * Applique un retour de GitHub au ticket, en transaction.
 *
 * Écrit seulement ce qui change. `status_changed_at` avance à chaque
 * changement de statut, et aussi quand une réponse arrive sur un ticket déjà
 * clos : c'est ce champ qui allume le point de notification du membre.
 * Rend `true` si le ticket a changé.
 */
export async function applyGithubUpdate(ticketId: string, update: GithubUpdate): Promise<boolean> {
  const ref = ticketRef(ticketId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return false;
    const data = snap.data() ?? {};
    const current = readStatus(data);
    const type: TicketType = isTicketType(data.type) ? data.type : "question";

    const resetAt = data.answer_reset_at;
    const stale = isStaleIssueSnapshot(
      update.issueUpdatedAt,
      resetAt instanceof Timestamp ? resetAt.toMillis() : null,
    );
    let next = current;
    if (update.statusFor && !stale) {
      next = nextTicketStatus(next, update.statusFor(type), update.openClosingPr === false);
    }
    if (update.openClosingPr && !isFinalStatus(next)) next = nextTicketStatus(next, "in_progress");

    const changes: Record<string, unknown> = {};
    if (update.answerReset && (current === "analyzed" || current === "validated")) {
      next = "received";
      changes.answer_reset_at = Timestamp.now();
    }
    if (next !== current) {
      changes.status = next;
      changes.status_changed_at = FieldValue.serverTimestamp();
    }
    // Ticket rouvert ou refermé autrement : la PR de livraison est périmée.
    if (
      next !== "delivered" &&
      (data.delivered_pr_number != null ||
        data.delivered_pr_url != null ||
        data.delivered_version != null)
    ) {
      changes.delivered_pr_number = FieldValue.delete();
      changes.delivered_pr_url = FieldValue.delete();
      changes.delivered_version = FieldValue.delete();
    }
    if (update.reply !== undefined && update.reply !== data.reply_text) {
      changes.reply_text = update.reply;
      if (isFinalStatus(next)) changes.status_changed_at = FieldValue.serverTimestamp();
    }
    if (Object.keys(changes).length === 0) return false;
    changes.updated_at = FieldValue.serverTimestamp();
    tx.update(ref, changes);
    return true;
  });
}

/** Identifiants des tickets publiés sous ce numéro d'Issue (zéro ou un). */
export async function ticketIdsForIssue(issueNumber: number): Promise<string[]> {
  const snap = await getFirestore()
    .collection(COLL_TICKETS)
    .where("github_issue_number", "==", issueNumber)
    .limit(2)
    .get();
  return snap.docs.map((d) => d.id);
}

/** La dernière réponse de l'administrateur parmi des commentaires, ou `undefined`. */
export function lastReply(
  comments: Array<{ authorId: number | null; body: string | null }>,
): string | undefined {
  let reply: string | undefined;
  for (const c of comments) {
    const r = replyFromComment(c, GITHUB_TICKETS_MAINTAINER_ID);
    if (r !== null) reply = r;
  }
  return reply;
}

function timestampOrNull(iso: string | null): Timestamp | null {
  if (iso === null) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : Timestamp.fromMillis(ms);
}

/**
 * Réécrit `analyses` et `checked_at` de `tickets/{id}/admin/analysis` depuis
 * les commentaires de l'Issue : les analyses du mainteneur et ses
 * `## Précisions…` (`analysesFromComments`, au plus dix, chacune tronquée à
 * 20 000 caractères, avec leur nature `kind`). Une précision n'est `reply`
 * que si son identifiant figure dans `answer_comment_ids`, lu dans la même
 * transaction ; sinon `unverified_reply`. Écriture fusionnée :
 * `validated_at` et `answer_comment_ids` restent tels quels. Rend le nombre
 * d'analyses écrites (réponses exclues). Lève sur une panne Firestore ;
 * l'appelant journalise.
 */
export async function writeTicketAnalyses(
  ticketId: string,
  comments: readonly RemoteComment[],
): Promise<number> {
  const ref = analysisRef(ticketId);
  return getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const answerIds = readAnswerCommentIds(snap.data()?.answer_comment_ids);
    const entries = analysesFromComments(comments, GITHUB_TICKETS_MAINTAINER_ID, answerIds);
    tx.set(
      ref,
      {
        analyses: entries.map((a) => ({
          comment_id: a.comment_id,
          kind: a.kind,
          body: a.body,
          created_at: timestampOrNull(a.created_at),
          updated_at: timestampOrNull(a.updated_at),
          truncated: a.truncated,
        })),
        checked_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    return entries.filter((a) => a.kind === "analysis").length;
  });
}

/**
 * Enregistre l'identifiant d'un commentaire publié par « Répondre » dans
 * `admin/analysis.answer_comment_ids` (écrit par le serveur seul) : seul un
 * commentaire de cette liste s'affiche comme réponse de l'administrateur.
 * Lève sur une panne Firestore.
 */
export async function recordAnswerCommentId(ticketId: string, commentId: number): Promise<void> {
  await analysisRef(ticketId).set(
    { answer_comment_ids: FieldValue.arrayUnion(commentId) },
    { merge: true },
  );
}

/**
 * Écrit `validated_at` (dernier « validé » du mainteneur) dans
 * `tickets/{id}/admin/analysis`, en transaction, selon `nextValidatedAt` :
 * tant que l'Issue porte `validé`, la date ne recule pas et ne repasse pas à
 * `null`. Rend la valeur stockée après l'écriture (`undefined` : champ
 * absent). Lève sur une panne Firestore.
 */
export async function updateValidatedAt(
  ticketId: string,
  fetchedMs: number | null,
  labelPresent: boolean,
): Promise<number | null | undefined> {
  const ref = analysisRef(ticketId);
  return getFirestore().runTransaction(async (tx) => {
    const data = (await tx.get(ref)).data();
    const raw = data?.validated_at;
    const stored =
      data === undefined || !("validated_at" in data)
        ? undefined
        : raw instanceof Timestamp
          ? raw.toMillis()
          : null;
    const next = nextValidatedAt(stored, fetchedMs, labelPresent);
    if (next === undefined) return stored;
    tx.set(
      ref,
      { validated_at: next === null ? null : Timestamp.fromMillis(next) },
      { merge: true },
    );
    return next;
  });
}

/**
 * Relit les commentaires d'une Issue et réécrit, depuis la même lecture, les
 * analyses (`admin/analysis`) et les comptes rendus de livraison
 * (`admin/delivery.reports`, qui peuvent libérer le verrou des livraisons).
 * Rend le nombre d'analyses. Lève une `GithubError` ou une erreur Firestore ;
 * l'appelant journalise.
 */
export async function refreshTicketComments(
  token: string,
  ticketId: string,
  issueNumber: number,
  scope: LogScope,
): Promise<number> {
  const comments = await listIssueComments(token, issueNumber);
  const count = await writeTicketAnalyses(ticketId, comments);
  await writeDeliveryReports(ticketId, comments, scope);
  return count;
}

/**
 * Relit une Issue et applique son état au ticket (tâche horaire, webhook
 * perdu), puis réécrit ses analyses et ses comptes rendus de livraison depuis
 * les commentaires déjà lus. Issue
 * ouverte : la date du dernier « validé » du mainteneur est lue dans ses
 * événements (`GET /issues/{n}/events`) et écrite par `updateValidatedAt`. Lève une `GithubError` ;
 * l'appelant journalise.
 */
export async function resyncTicket(
  token: string,
  ticketId: string,
  issueNumber: number,
  scope: LogScope,
): Promise<boolean> {
  const issue = await getIssue(token, issueNumber);
  if (issue.isPullRequest) return false;
  // `undefined` : chronologie tronquée, l'absence de PR n'est pas établie.
  let openClosingPr: boolean | undefined = false;
  let validatedAtIso: string | null | undefined;
  if (issue.state === "open") {
    const { bodies, complete } = await openPullRequestBodiesReferencing(token, issueNumber);
    const found = bodies.some((b) =>
      closingIssueNumbers(b, GITHUB_REPO_FULL_NAME).includes(issueNumber),
    );
    openClosingPr = openClosingPrFromTimeline(found, complete);
    validatedAtIso = await lastValidatedLabelAt(token, issueNumber);
  }
  const comments = await listIssueComments(token, issueNumber);
  const reply = lastReply(comments);
  const changed = await applyGithubUpdate(ticketId, {
    statusFor: (type) =>
      statusFromIssue({ ...issue, hasOpenClosingPr: openClosingPr === true }, type),
    openClosingPr,
    reply,
    issueUpdatedAt: issue.updatedAt,
  });
  await writeTicketAnalyses(ticketId, comments);
  await writeDeliveryReports(ticketId, comments, scope);
  if (validatedAtIso !== undefined) {
    const ms = validatedAtIso === null ? null : Date.parse(validatedAtIso);
    await updateValidatedAt(
      ticketId,
      ms === null || Number.isNaN(ms) ? null : ms,
      issue.labels.includes(LABEL_VALIDATED),
    );
  }
  // En dernier : une panne GitHub ici ne perd ni les analyses ni la date de validation.
  if (issue.state === "closed") await recordDeliveredPr(token, ticketId, issueNumber);
  return changed;
}
