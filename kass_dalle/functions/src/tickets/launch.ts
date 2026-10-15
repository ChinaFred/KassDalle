/**
 * Lancement d'une session Claude Code sur un ticket, par une Routine :
 * « Lancer l'analyse » (ticket Reçu), « Lancer le développement » (ticket
 * Validé) et « Livrer » (ticket En cours, routine de développement, texte
 * `livraison #N`), appelés par `launchTicketAnalysis`,
 * `launchTicketDevelopment` et `launchTicketDelivery`
 * (`callable/ticketsCallable.ts`) après `requireAdmin`.
 *
 * Dans l'ordre :
 *  1. secrets de la routine présents, sinon « Lancement non configuré »,
 *     rien compté ;
 *  2. statut et Issue (`launchPrecondition`), puis bail de décision partagé
 *     avec Valider, Refuser et Répondre (`claimDecision`) ;
 *  3. développement seulement : ticket bloqué (`ticketAwaitingReply`, la
 *     dernière analyse est postérieure au dernier « validé » du mainteneur),
 *     refusé avec `launch_needs_answer`, rien compté. La date du « validé »
 *     vient de `admin/analysis.validated_at`, ou des événements de l'Issue
 *     quand elle manque ;
 *  3 bis. aucun lancement du même type en cours (`launchRunState` ; un
 *     lancement antérieur au dernier changement de statut ne compte pas ;
 *     une livraison suivie d'un blocage relevé est finie) ;
 *  3 ter. livraison seulement, rien compté en cas de refus : une seule PR
 *     éligible, aucun fichier sensible, dernier run « CI » vert sur sa tête
 *     (relus sur GitHub, état écrit dans `admin/delivery`), puis verrou
 *     global des livraisons (`delivery_running`) ;
 *  4. plafond du jour (`app_config/tickets.launches_per_day`, 10 par défaut ;
 *     50 pour le compte fondateur, `launchLimitFor`) :
 *     le lancement est compté en transaction (`ticket_quotas/launch_<jour>`,
 *     compteurs de `app_config/tickets_status`) ;
 *  5. Issue relue sur GitHub : fermée, ou étiquettes qui donnent un autre
 *     statut → l'état relu est appliqué, rien n'est lancé (une livraison
 *     vient de relire sa PR : l'Issue ouverte dit « En cours ») ;
 *  6. entrée d'historique écrite `unknown` AVANT l'appel : une fonction
 *     coupée pendant l'appel laisse une trace qui bloque comme un succès ;
 *  7. appel unique de l'API (`fireRoutine`, 30 s, aucune relance) ;
 *  8. entrée mise à jour : `launched` (compté), `failed` (compte rendu),
 *     ou laissée `unknown` (compté, bloque) sans réponse (délai, réseau) ou sur
 *     une réponse 5xx : la session a pu partir.
 * Le bail est libéré à la fin, réussite ou échec. Le verrou des livraisons
 * est rendu quand rien n'est parti (refus, panne avant l'appel, refus de
 * l'API) ; il reste tenu sur un lancement abouti ou au résultat inconnu.
 *
 * Rien n'est écrit dans `tickets/{id}`, que l'auteur lit : ni lien de
 * session, ni nom d'administrateur.
 */

import { randomUUID } from "node:crypto";

import { HttpsError, type FunctionsErrorCode } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_APP_CONFIG,
  COLL_TICKETS,
  COLL_TICKET_QUOTAS,
  COLL_USERS,
  TICKET_ADMIN_SUBCOLLECTION,
  TICKET_LAUNCHES_DOC_ID,
  TICKETS_CONFIG_DOC_ID,
  TICKETS_STATUS_DOC_ID,
} from "../config";
import { founderUid } from "../ai/budget";
import { logError, logInfo, logWarn } from "../logging";
import { claimDecision, githubFailure, releaseDecision, tokenMissing } from "./decisions";
import {
  claimDeliveryLock,
  deliveryRef,
  readDelivery,
  releaseDeliveryLock,
  writeDeliveryState,
} from "./delivery";
import { getIssue, githubToken, lastValidatedLabelAt, listPullRequestFiles } from "./github";
import {
  DELIVERY_NO_PR_MESSAGE,
  DELIVERY_SENSITIVE_REASON,
  LAUNCH_FROM_STATUS,
  LAUNCH_ROUTINE,
  LAUNCH_HISTORY_MAX,
  LAUNCH_NEEDS_ANSWER_MESSAGE,
  launchCommandText,
  launchLimitFor,
  launchPrecondition,
  launchQuotaDocId,
  launchQuotaMessage,
  launchRetryAfterMs,
  launchRunState,
  launchRunningMessage,
  nextLaunchCounters,
  parisDay,
  readLaunchesPerDay,
  sensitiveDeliveryPath,
  statusFromIssue,
  ticketAwaitingReply,
  deliveryCiNotGreenMessage,
  deliveryFilesUnreadableMessage,
  deliveryMultiplePrMessage,
  deliverySensitiveMessage,
  isGreenCiRun,
  type LaunchAction,
  type TicketType,
} from "./rules";
import {
  fireRoutine,
  routineConfig,
  routineFailureMessage,
  ROUTINE_SERVER_ERROR_MESSAGE,
  type FireOutcome,
  type RoutineFailureKind,
} from "./routine";
import {
  deliveryBlockedAtMs,
  lastAnalysisMillis,
  launchEntryViews,
  readLaunchEntries,
  storedValidatedAt,
} from "./stored";
import { analysisRef, applyGithubUpdate, updateValidatedAt, type LogScope } from "./service";

/** Durée de vie d'un compteur du jour (politique TTL sur `expires_at`). */
const QUOTA_TTL_DAYS = 7;

export const LAUNCH_NOT_CONFIGURED_MESSAGE =
  "Lancement non configuré : ajoutez l'identifiant et le jeton de la routine dans Secret Manager.";

export const LAUNCH_TICKET_CHANGED_MESSAGE = "Le ticket a changé sur GitHub. Rien n'a été lancé.";

/** Ce que rend un lancement abouti ou au résultat inconnu. */
export interface LaunchResult {
  outcome: "launched" | "unknown";
  /** Message à montrer pour un résultat inconnu venu d'un 5xx, sinon `null`. */
  message: string | null;
  session_url: string | null;
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function ticketRef(ticketId: string) {
  return getFirestore().collection(COLL_TICKETS).doc(ticketId);
}

function launchesRef(ticketId: string) {
  return ticketRef(ticketId).collection(TICKET_ADMIN_SUBCOLLECTION).doc(TICKET_LAUNCHES_DOC_ID);
}

function statusRef() {
  return getFirestore().collection(COLL_APP_CONFIG).doc(TICKETS_STATUS_DOC_ID);
}

/** Code d'erreur rendu au client pour un échec de l'API. */
function failureCode(failure: RoutineFailureKind): FunctionsErrorCode {
  if (failure === "rate_limit") return "resource-exhausted";
  return "failed-precondition";
}

/** Le nom de l'administrateur, tel que la famille le voit. Au mieux. */
async function adminName(uid: string, scope: LogScope): Promise<string> {
  try {
    const data = (await getFirestore().collection(COLL_USERS).doc(uid).get()).data() ?? {};
    const preferred = typeof data.preferred_name === "string" ? data.preferred_name.trim() : "";
    if (preferred.length > 0) return preferred.slice(0, 80);
    const display = typeof data.display_name === "string" ? data.display_name.trim() : "";
    const first = display.split(/\s+/)[0] ?? "";
    return first.length > 0 ? first.slice(0, 80) : "Administrateur";
  } catch (err) {
    await logError({
      message: "Tickets : nom de l'administrateur illisible pour l'historique des lancements",
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      feature: "tickets",
    });
    return "Administrateur";
  }
}

// ── Compteur du jour ────────────────────────────────────────────────────────

/**
 * Compte le lancement si le plafond le permet, en transaction : compteur du
 * jour (`ticket_quotas/launch_<jour>`) et compteurs affichés
 * (`app_config/tickets_status`). Lève `resource-exhausted` au plafond.
 */
async function reserveLaunch(day: string, limit: number): Promise<void> {
  const db = getFirestore();
  const quotaRef = db.collection(COLL_TICKET_QUOTAS).doc(launchQuotaDocId(day));
  await db.runTransaction(async (tx) => {
    const [quotaSnap, statusSnap] = await Promise.all([tx.get(quotaRef), tx.get(statusRef())]);
    const raw = quotaSnap.data()?.count;
    const count = typeof raw === "number" && Number.isFinite(raw) && raw > 0 ? raw : 0;
    if (count >= limit) {
      throw new HttpsError("resource-exhausted", launchQuotaMessage(limit), {
        reason: "launch_daily_limit",
        limit,
      });
    }
    tx.set(
      quotaRef,
      {
        day,
        count: count + 1,
        expires_at: Timestamp.fromMillis(Date.now() + QUOTA_TTL_DAYS * 86_400_000),
      },
      { merge: true },
    );
    const status = statusSnap.data() ?? {};
    const next = nextLaunchCounters(
      { today: status.launches_today, month: status.launches_month },
      day,
      1,
    );
    tx.set(
      statusRef(),
      { launches_today: next.today, launches_month: next.month },
      { merge: true },
    );
  });
}

/** Rend un lancement compté qui n'a pas eu lieu. Au mieux, journalisé. */
async function releaseLaunch(day: string, ticketId: string, scope: LogScope): Promise<void> {
  const db = getFirestore();
  const quotaRef = db.collection(COLL_TICKET_QUOTAS).doc(launchQuotaDocId(day));
  try {
    await db.runTransaction(async (tx) => {
      const [quotaSnap, statusSnap] = await Promise.all([tx.get(quotaRef), tx.get(statusRef())]);
      const raw = quotaSnap.data()?.count;
      if (typeof raw === "number" && raw > 0) tx.update(quotaRef, { count: raw - 1 });
      const status = statusSnap.data() ?? {};
      const next = nextLaunchCounters(
        { today: status.launches_today, month: status.launches_month },
        day,
        -1,
      );
      const changes: Record<string, unknown> = {};
      if (next.today !== null) changes.launches_today = next.today;
      if (next.month !== null) changes.launches_month = next.month;
      if (Object.keys(changes).length > 0) tx.set(statusRef(), changes, { merge: true });
    });
  } catch (err) {
    await logError({
      message: `Tickets : lancement non abouti du ticket ${ticketId} resté compté pour le ${day}`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}

// ── Historique ──────────────────────────────────────────────────────────────

/** Ajoute une entrée en tête de l'historique, vingt au plus. Lève sur une panne. */
async function recordLaunch(ticketId: string, entry: Record<string, unknown>): Promise<void> {
  const ref = launchesRef(ticketId);
  await getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const list = [entry, ...readLaunchEntries(snap.data())].slice(0, LAUNCH_HISTORY_MAX);
    tx.set(ref, { launches: list, updated_at: FieldValue.serverTimestamp() });
  });
}

/** Met à jour l'entrée `id`. Au mieux : l'entrée reste `unknown` et bloque. */
async function updateLaunch(
  ticketId: string,
  id: string,
  patch: Record<string, unknown>,
  scope: LogScope,
): Promise<void> {
  const ref = launchesRef(ticketId);
  try {
    await getFirestore().runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const list = readLaunchEntries(snap.data()).map((e) =>
        e !== null && typeof e === "object" && (e as Record<string, unknown>).id === id
          ? { ...(e as Record<string, unknown>), ...patch }
          : e,
      );
      tx.set(ref, { launches: list, updated_at: FieldValue.serverTimestamp() });
    });
  } catch (err) {
    await logError({
      message: `Tickets : résultat du lancement ${id} du ticket ${ticketId} non enregistré (reste « inconnu »)`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { patch_outcome: patch.outcome ?? null },
    });
  }
}

// ── Jeton de la routine refusé ──────────────────────────────────────────────

/**
 * Pose `routine_invalid_since.<routine>` s'il ne l'est pas (la livraison
 * marque la routine de développement). Au mieux, journalisé.
 */
async function markRoutineInvalid(launch: LaunchAction, scope: LogScope): Promise<void> {
  const action = LAUNCH_ROUTINE[launch];
  try {
    await getFirestore().runTransaction(async (tx) => {
      const snap = await tx.get(statusRef());
      const current = snap.data()?.routine_invalid_since;
      const map =
        current !== null && typeof current === "object" ? (current as Record<string, unknown>) : {};
      if (map[action] instanceof Timestamp) return;
      tx.set(
        statusRef(),
        { routine_invalid_since: { [action]: Timestamp.now() } },
        { merge: true },
      );
    });
  } catch (err) {
    await logError({
      message: `Tickets : refus du jeton de la routine ${action} non enregistré`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      feature: "tickets",
    });
  }
}

/** Efface `routine_invalid_since.<routine>` après un lancement réussi. Au mieux. */
async function clearRoutineInvalid(launch: LaunchAction, scope: LogScope): Promise<void> {
  const action = LAUNCH_ROUTINE[launch];
  try {
    const snap = await statusRef().get();
    const current = snap.data()?.routine_invalid_since;
    if (current === null || typeof current !== "object") return;
    if ((current as Record<string, unknown>)[action] == null) return;
    await statusRef().set({ routine_invalid_since: { [action]: null } }, { merge: true });
  } catch (err) {
    await logError({
      message: `Tickets : alerte du jeton de la routine ${action} non effacée`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      feature: "tickets",
    });
  }
}

// ── Ticket bloqué ───────────────────────────────────────────────────────────

/**
 * Refuse un développement sur un ticket bloqué, avant tout comptage. Sans
 * `validated_at` stocké, la date est lue dans les événements de l'Issue, puis
 * écrite (au mieux) pour l'écran.
 */
async function refuseIfAwaitingReply(
  ticketId: string,
  issueNumber: number,
  type: TicketType,
  scope: LogScope,
): Promise<void> {
  const data = (await analysisRef(ticketId).get()).data();
  const lastAnalysisAtMs = lastAnalysisMillis(data);
  if (lastAnalysisAtMs === null) return;
  let validatedAtMs: number | null;
  const stored = storedValidatedAt(data);
  if (stored !== undefined) {
    validatedAtMs = stored;
  } else {
    const token = githubToken();
    if (token === null) throw await tokenMissing(ticketId, scope);
    let iso: string | null;
    try {
      iso = await lastValidatedLabelAt(token, issueNumber);
    } catch (err) {
      throw await githubFailure(err, ticketId, "lecture des événements de l'Issue", scope);
    }
    const fetched = iso === null ? null : Date.parse(iso);
    validatedAtMs = fetched === null || Number.isNaN(fetched) ? null : fetched;
    try {
      // Ticket Validé : l'étiquette est présente, la date ne recule pas.
      const written = await updateValidatedAt(ticketId, validatedAtMs, true);
      if (written !== undefined) validatedAtMs = written;
    } catch (err) {
      await logError({
        message: `Tickets : date de validation du ticket ${ticketId} lue sur GitHub mais non écrite`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
    }
  }
  const awaiting = ticketAwaitingReply({
    rawStatus: LAUNCH_FROM_STATUS.developpement,
    type,
    lastAnalysisAtMs,
    validatedAtMs,
  });
  if (!awaiting) return;
  await logInfo({
    message: `Tickets : développement du ticket ${ticketId} refusé, la dernière analyse attend une réponse`,
    correlationId: scope.correlationId,
    userId: scope.userId,
    firestoreDocId: ticketId,
    feature: "tickets",
  });
  throw new HttpsError("failed-precondition", LAUNCH_NEEDS_ANSWER_MESSAGE, {
    reason: "launch_needs_answer",
  });
}

// ── Lancement ───────────────────────────────────────────────────────────────

export async function launchTicketSession(
  ticketId: string,
  action: LaunchAction,
  scope: LogScope & { userId: string },
): Promise<LaunchResult> {
  const config = routineConfig(action);
  if (config === null) {
    await logError({
      message: `Tickets : lancement ${action} du ticket ${ticketId} refusé, routine non configurée`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { action },
    });
    throw new HttpsError("failed-precondition", LAUNCH_NOT_CONFIGURED_MESSAGE, {
      reason: "routine_not_configured",
    });
  }

  const fromStatus = LAUNCH_FROM_STATUS[action];
  const seen: { type: TicketType; statusChangedAtMs: number | null } = {
    type: "question",
    statusChangedAtMs: null,
  };
  const claimed = await claimDecision(
    ticketId,
    ({ status, type, issueNumber, statusChangedAtMs }) => {
      seen.type = type;
      seen.statusChangedAtMs = statusChangedAtMs;
      const refusal = launchPrecondition({ status, type, hasIssue: issueNumber !== null }, action);
      return refusal === null
        ? { kind: "go" }
        : { kind: "refused", message: refusal, reason: "not_launchable" };
    },
  );
  // Le contrôle d'un lancement ne rend jamais « rien à faire ».
  if (claimed === null) throw new Error(`lancement du ticket ${ticketId} : bail rendu sans Issue`);
  const issueNumber = claimed;

  let reservedDay: string | null = null;
  let keepCount = false;
  // Livraison : instant du lancement, fixé à la prise du verrou.
  let plannedLaunchedAtMs: number | null = null;
  let lockedAtMs: number | null = null;
  try {
    // 3. Ticket bloqué : la dernière analyse attend une réponse.
    if (action === "developpement") {
      await refuseIfAwaitingReply(ticketId, issueNumber, seen.type, scope);
    }

    // 3 bis. Un lancement du même type en cours.
    const views = launchEntryViews((await launchesRef(ticketId).get()).data());
    const run = launchRunState({
      entries: views,
      action,
      rawStatus: fromStatus,
      nowMs: Date.now(),
      statusChangedAtMs: seen.statusChangedAtMs,
      deliveryBlockedAtMs:
        action === "livraison"
          ? deliveryBlockedAtMs((await deliveryRef(ticketId).get()).data())
          : null,
    });
    if (run.running && run.runningSinceMs !== null) {
      throw new HttpsError(
        "failed-precondition",
        launchRunningMessage(
          action,
          run.runningSinceMs,
          launchRetryAfterMs(action, run.runningSinceMs),
        ),
        { reason: "launch_running" },
      );
    }

    // 3 ter. Livraison : PR, fichiers et CI relus, puis verrou global.
    if (action === "livraison") {
      await checkDeliveryLaunch(ticketId, issueNumber, scope);
      plannedLaunchedAtMs = Date.now();
      await claimDeliveryLock(ticketId, issueNumber, plannedLaunchedAtMs);
      lockedAtMs = plannedLaunchedAtMs;
    }

    // 4. Plafond du jour.
    const configSnap = await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(TICKETS_CONFIG_DOC_ID)
      .get();
    const configured = readLaunchesPerDay(configSnap.exists ? configSnap.data() : undefined);
    if (configured === null) {
      await logError({
        message: "Tickets : app_config/tickets.launches_per_day illisible, lancement refusé",
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
        extra: { launches_per_day: configSnap.data()?.launches_per_day ?? null },
      });
      throw new HttpsError(
        "failed-precondition",
        "Le réglage des lancements (launches_per_day) est illisible. Corrigez app_config/tickets.",
        { reason: "launch_config_unreadable" },
      );
    }
    const limit = launchLimitFor(configured, (await founderUid()) === scope.userId);
    const day = parisDay(new Date());
    await reserveLaunch(day, limit);
    reservedDay = day;

    // 5. Issue relue sur GitHub.
    const token = githubToken();
    if (token === null) throw await tokenMissing(ticketId, scope);
    let issue: Awaited<ReturnType<typeof getIssue>>;
    try {
      issue = await getIssue(token, issueNumber);
    } catch (err) {
      throw await githubFailure(err, ticketId, "lecture de l'Issue avant lancement", scope);
    }
    // Une livraison vient de relire sa PR ouverte : l'Issue ouverte dit « En cours ».
    const hasOpenClosingPr = action === "livraison";
    const remote = statusFromIssue({ ...issue, hasOpenClosingPr }, seen.type);
    if (issue.state === "closed" || remote !== fromStatus) {
      await applyGithubUpdate(ticketId, {
        statusFor: (t) => statusFromIssue({ ...issue, hasOpenClosingPr }, t),
      });
      await logWarn({
        message: `Tickets : lancement ${action} du ticket ${ticketId} annulé, l'Issue #${issueNumber} dit ${remote}`,
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError("failed-precondition", LAUNCH_TICKET_CHANGED_MESSAGE, {
        reason: "ticket_changed",
      });
    }

    // 6. Trace écrite avant l'appel.
    const text = launchCommandText(action, issueNumber);
    const launchedAtMs = plannedLaunchedAtMs ?? Date.now();
    const id = randomUUID();
    try {
      await recordLaunch(ticketId, {
        id,
        action,
        launched_at: Timestamp.fromMillis(launchedAtMs),
        launched_by_uid: scope.userId,
        launched_by_name: await adminName(scope.userId, scope),
        outcome: "unknown",
        session_id: null,
        session_url: null,
        error_reason: null,
        from_status: fromStatus,
        retry_after: Timestamp.fromMillis(launchRetryAfterMs(action, launchedAtMs)),
      });
    } catch (err) {
      await logError({
        message: `Tickets : historique du ticket ${ticketId} non écrit, lancement ${action} abandonné`,
        errorDescription: describe(err),
        correlationId: scope.correlationId,
        userId: scope.userId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError(
        "internal",
        "Le lancement n'a pas pu être préparé. Rien n'a été lancé.",
        {
          reason: "launch_not_recorded",
        },
      );
    }

    // 7. Appel unique. À partir d'ici, une session a pu partir.
    const outcome: FireOutcome = await fireRoutine(config, text);
    keepCount = true;
    return await settleLaunch(ticketId, action, issueNumber, id, outcome, scope, () => {
      keepCount = false;
    });
  } finally {
    if (reservedDay !== null && !keepCount) await releaseLaunch(reservedDay, ticketId, scope);
    if (lockedAtMs !== null && !keepCount) await releaseDeliveryLock(ticketId, lockedAtMs, scope);
    await releaseDecision(ticketId, scope);
  }
}

// ── Livraison ───────────────────────────────────────────────────────────────

/**
 * Contrôles d'une livraison avant tout comptage, relus sur GitHub : une seule
 * PR éligible, aucun fichier sensible (`sensitiveDeliveryPath`), dernier run
 * « CI » vert sur sa tête. L'état relu est écrit dans `admin/delivery` (au
 * mieux). Lève `failed-precondition` avec sa raison ; un échec GitHub suit
 * `decisionGithubFailure`.
 */
async function checkDeliveryLaunch(
  ticketId: string,
  issueNumber: number,
  scope: LogScope,
): Promise<void> {
  const token = githubToken();
  if (token === null) throw await tokenMissing(ticketId, scope);
  let reading: Awaited<ReturnType<typeof readDelivery>>;
  try {
    reading = await readDelivery(token, issueNumber, LAUNCH_FROM_STATUS.livraison);
  } catch (err) {
    throw await githubFailure(err, ticketId, "lecture de la pull request avant livraison", scope);
  }
  try {
    await writeDeliveryState(ticketId, reading.state);
  } catch (err) {
    await logError({
      message: `Tickets : état « PR prête » du ticket ${ticketId} relu au lancement mais non écrit`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
  const refuse = async (message: string, reason: string): Promise<never> => {
    await logInfo({
      message: `Tickets : livraison du ticket ${ticketId} refusée (${reason})`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
      extra: { reason, pr_number: reading.state.pr_number },
    });
    throw new HttpsError("failed-precondition", message, { reason });
  };
  const count = reading.state.eligible_pr_count;
  if (count > 1)
    await refuse(deliveryMultiplePrMessage(count, issueNumber), "delivery_multiple_prs");
  const pr = reading.pr;
  if (pr === null) return refuse(DELIVERY_NO_PR_MESSAGE, "delivery_no_pr");

  let files: Awaited<ReturnType<typeof listPullRequestFiles>>;
  try {
    files = await listPullRequestFiles(token, pr.number);
  } catch (err) {
    throw await githubFailure(err, ticketId, "lecture des fichiers de la pull request", scope);
  }
  if (!files.complete) {
    await refuse(deliveryFilesUnreadableMessage(pr.number), "delivery_files_unreadable");
  }
  const sensitive = sensitiveDeliveryPath(files.files);
  if (sensitive !== null) {
    await refuse(deliverySensitiveMessage(pr.number, sensitive), DELIVERY_SENSITIVE_REASON);
  }
  if (!isGreenCiRun(reading.ciRun)) {
    await refuse(deliveryCiNotGreenMessage(pr.number), "delivery_ci_not_green");
  }
}

/** Enregistre le résultat de l'appel et le traduit pour le client. */
async function settleLaunch(
  ticketId: string,
  action: LaunchAction,
  issueNumber: number,
  id: string,
  outcome: FireOutcome,
  scope: LogScope,
  uncount: () => void,
): Promise<LaunchResult> {
  const base = {
    correlationId: scope.correlationId,
    userId: scope.userId,
    firestoreDocId: ticketId,
    feature: "tickets",
  };
  if (outcome.kind === "launched") {
    await updateLaunch(
      ticketId,
      id,
      { outcome: "launched", session_id: outcome.sessionId, session_url: outcome.sessionUrl },
      scope,
    );
    await clearRoutineInvalid(action, scope);
    if (outcome.note !== null) {
      await logWarn({
        ...base,
        message: `Tickets : session ${action} lancée pour l'Issue #${issueNumber}, réponse sans lien lisible`,
        extra: { note: outcome.note },
      });
    }
    await logInfo({
      ...base,
      message: `Tickets : session ${action} lancée pour le ticket ${ticketId} (Issue #${issueNumber})`,
    });
    return { outcome: "launched", session_url: outcome.sessionUrl, message: null };
  }

  if (outcome.kind === "unknown") {
    // Délai, réseau ou 5xx : la session a pu partir. L'entrée reste
    // `unknown`, comptée, et bloque un nouveau lancement jusqu'à l'échéance.
    const serverError = outcome.status !== null;
    await logError({
      ...base,
      message: serverError
        ? `Tickets : lancement ${action} du ticket ${ticketId} en HTTP ${outcome.status}, résultat inconnu`
        : `Tickets : lancement ${action} du ticket ${ticketId} sans réponse, résultat inconnu`,
      errorDescription: outcome.detail,
      extra: { action, issue_number: issueNumber, status: outcome.status },
    });
    if (serverError) {
      await updateLaunch(ticketId, id, { error_reason: ROUTINE_SERVER_ERROR_MESSAGE }, scope);
    }
    return {
      outcome: "unknown",
      session_url: null,
      message: serverError ? ROUTINE_SERVER_ERROR_MESSAGE : null,
    };
  }

  const message = routineFailureMessage(outcome.failure, outcome.retryMinutes);
  uncount();
  await logError({
    ...base,
    message: `Tickets : lancement ${action} du ticket ${ticketId} refusé par l'API (HTTP ${outcome.status}, ${outcome.failure})`,
    errorDescription: outcome.detail,
    extra: { action, issue_number: issueNumber, status: outcome.status, failure: outcome.failure },
  });
  await updateLaunch(ticketId, id, { outcome: "failed", error_reason: message }, scope);
  if (outcome.failure === "token") await markRoutineInvalid(action, scope);
  throw new HttpsError(failureCode(outcome.failure), message, {
    reason: `routine_${outcome.failure}`,
  });
}
