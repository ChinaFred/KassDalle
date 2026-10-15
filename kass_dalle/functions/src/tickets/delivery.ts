/**
 * Livraison d'un ticket (« Livrer », Admin › Tickets) : état « PR prête »,
 * comptes rendus de la session de livraison, verrou global.
 *
 * - `refreshTicketDelivery` relit sur GitHub les PR ouvertes, garde celles
 *   qui peuvent être livrées pour l'Issue (`isEligibleDeliveryPr`), relit le
 *   détail de la PR quand elle est seule (tête, corps), puis le dernier
 *   run « CI » de sa tête, et écrit `tickets/{id}/admin/delivery`
 *   (`deliveryState`). Appelé par le webhook (`pull_request`, `workflow_run`),
 *   la tâche horaire et le lancement.
 * - `writeDeliveryReports` relève les commentaires `## Livraison — blocage`
 *   et `## Livraison — terminée` du mainteneur dans le même document, et
 *   libère le verrou quand un blocage suit la livraison verrouillée.
 * - `claimDeliveryLock` et `releaseDeliveryLock` tiennent
 *   `app_config/tickets_status.delivery_running` : une livraison à la fois
 *   pour tout le dépôt.
 *
 * Aucun texte de GitHub n'est écrit hormis les comptes rendus du mainteneur,
 * lisibles par l'administrateur seul. Ce module ne lève que des erreurs
 * GitHub (`GithubError`), Firestore, ou le refus du verrou (`HttpsError`) ;
 * l'appelant journalise.
 */

import { HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_APP_CONFIG,
  COLL_TICKETS,
  GITHUB_TICKETS_MAINTAINER_ID,
  TICKET_ADMIN_SUBCOLLECTION,
  TICKET_DELIVERY_DOC_ID,
  TICKETS_STATUS_DOC_ID,
} from "../config";
import { logError, logInfo } from "../logging";
import {
  GITHUB_REPO_FULL_NAME,
  findDeliveredPullRequest,
  getPullRequest,
  listOpenPullRequests,
  listRunsForCommit,
  pubspecVersionAtCommit,
  type RemoteComment,
} from "./github";
import {
  LAUNCH_RETRY_MS,
  blockageReleasesLock,
  deliveryLockActive,
  deliveryReportsFromComments,
  deliveryRunningElsewhereMessage,
  deliveryState,
  isEligibleDeliveryPr,
  latestCiRun,
  type CiRunView,
  type DeliveryState,
  type PullRequestView,
} from "./rules";
import { deliveryBlockedAtMs, deliveryLockView } from "./stored";

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function ticketRef(ticketId: string) {
  return getFirestore().collection(COLL_TICKETS).doc(ticketId);
}

/** `tickets/{id}/admin/delivery` : lecture admin seule, écriture serveur seule. */
export function deliveryRef(ticketId: string) {
  return ticketRef(ticketId).collection(TICKET_ADMIN_SUBCOLLECTION).doc(TICKET_DELIVERY_DOC_ID);
}

function statusRef() {
  return getFirestore().collection(COLL_APP_CONFIG).doc(TICKETS_STATUS_DOC_ID);
}

function timestampOrNull(iso: string | null): Timestamp | null {
  if (iso === null) return null;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? null : Timestamp.fromMillis(ms);
}

// ── État « PR prête » ───────────────────────────────────────────────────────

/** Les PR ouvertes du dépôt, lues une fois et partagées par une passe. */
export type OpenPullRequests = { prs: PullRequestView[]; complete: boolean };

/** Ce qu'une relecture établit, avec la PR éligible quand elle est seule. */
export interface DeliveryReading {
  state: DeliveryState;
  /** Détail de la PR éligible quand elle est seule, sinon `null`. */
  pr: PullRequestView | null;
  ciRun: CiRunView | null;
}

/**
 * Relit sur GitHub ce qui fait une « PR prête » pour l'Issue `issueNumber`.
 * `openPrs` : la liste déjà lue par l'appelant (tâche horaire), sinon relue.
 * Le détail relu de la PR doit encore être éligible (état, brouillon, corps).
 */
export async function readDelivery(
  token: string,
  issueNumber: number,
  ticketStatus: unknown,
  openPrs?: OpenPullRequests,
): Promise<DeliveryReading> {
  const list = openPrs ?? (await listOpenPullRequests(token));
  const isEligible = (pr: PullRequestView) =>
    isEligibleDeliveryPr(pr, issueNumber, GITHUB_TICKETS_MAINTAINER_ID, GITHUB_REPO_FULL_NAME);
  let eligible = list.prs.filter(isEligible);
  let pr: PullRequestView | null = null;
  let ciRun: CiRunView | null = null;
  if (eligible.length === 1) {
    const detail = await getPullRequest(token, eligible[0].number);
    if (isEligible(detail)) {
      pr = detail;
      if (detail.headSha !== null) {
        ciRun = latestCiRun(await listRunsForCommit(token, detail.headSha), detail.headSha);
      }
    } else {
      eligible = [];
    }
  }
  return {
    state: deliveryState({
      ticketStatus,
      prListComplete: list.complete,
      eligible,
      pr,
      ciRun,
      repoFullName: GITHUB_REPO_FULL_NAME,
    }),
    pr,
    ciRun,
  };
}

/** Écrit l'état « PR prête » (fusion : les comptes rendus restent). Lève sur une panne. */
export async function writeDeliveryState(ticketId: string, state: DeliveryState): Promise<void> {
  await deliveryRef(ticketId).set(
    {
      ...state,
      ci_completed_at: timestampOrNull(state.ci_completed_at),
      updated_at: FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
}

/**
 * Relit l'état « PR prête » d'un ticket et l'écrit. Le statut du ticket est
 * relu dans Firestore. Rend l'état écrit, ou `null` si le ticket n'existe
 * plus. Lève une `GithubError` ou une erreur Firestore ; l'appelant journalise.
 */
export async function refreshTicketDelivery(
  token: string,
  ticketId: string,
  issueNumber: number,
  openPrs?: OpenPullRequests,
): Promise<DeliveryState | null> {
  const snap = await ticketRef(ticketId).get();
  if (!snap.exists) return null;
  const reading = await readDelivery(token, issueNumber, snap.data()?.status, openPrs);
  await writeDeliveryState(ticketId, reading.state);
  return reading.state;
}

// ── PR de livraison d'un ticket livré ───────────────────────────────────────

/**
 * Range sur `tickets/{id}` (`delivered_pr_number`, `delivered_pr_url`,
 * `delivered_version`) la PR fusionnée qui a fermé l'Issue et la version de
 * l'application à son commit de fusion. Les champs vivent sur le ticket, lisible
 * par son auteur : une PR d'un dépôt public ne contient aucune donnée privée.
 * Rend `not_delivered` si le ticket n'est pas (ou plus) livré, `no_pr` si
 * aucune PR ne l'a fermé (Issue fermée à la main) : les champs ne sont alors
 * pas touchés. Lève une `GithubError` ou une erreur Firestore ; l'appelant
 * journalise.
 */
export async function recordDeliveredPr(
  token: string,
  ticketId: string,
  issueNumber: number,
): Promise<"written" | "no_pr" | "not_delivered"> {
  const snap = await ticketRef(ticketId).get();
  if (!snap.exists || snap.data()?.status !== "delivered") return "not_delivered";
  const pr = await findDeliveredPullRequest(token, issueNumber);
  if (pr === null) return "no_pr";
  // La version est complémentaire : une lecture en échec n'empêche pas d'écrire la PR.
  // La reprise suivante complète le champ absent.
  let version: string | null = null;
  try {
    version = await pubspecVersionAtCommit(token, pr.commitSha);
  } catch (err) {
    await logError({
      message: `Tickets : version livrée du ticket ${ticketId} (Issue #${issueNumber}) non lue`,
      errorDescription: describe(err),
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
  await ticketRef(ticketId).update({
    delivered_pr_number: pr.number,
    delivered_pr_url: pr.url,
    delivered_version: version ?? FieldValue.delete(),
    updated_at: FieldValue.serverTimestamp(),
  });
  return "written";
}

// ── Comptes rendus de livraison ─────────────────────────────────────────────

/**
 * Réécrit `reports` de `tickets/{id}/admin/delivery` depuis les commentaires
 * de l'Issue (`deliveryReportsFromComments`, dix au plus), puis libère le
 * verrou global si un blocage suit la livraison qu'il porte. Rend le nombre
 * de comptes rendus. Lève sur une panne Firestore ; l'appelant journalise.
 */
export async function writeDeliveryReports(
  ticketId: string,
  comments: readonly RemoteComment[],
  scope: { correlationId: string; userId?: string },
): Promise<number> {
  const reports = deliveryReportsFromComments(comments, GITHUB_TICKETS_MAINTAINER_ID).map((r) => ({
    ...r,
    created_at: timestampOrNull(r.created_at),
    updated_at: timestampOrNull(r.updated_at),
  }));
  await deliveryRef(ticketId).set(
    { reports, reports_checked_at: FieldValue.serverTimestamp() },
    { merge: true },
  );
  const blockedAtMs = deliveryBlockedAtMs({ reports });
  if (blockedAtMs !== null) await releaseLockAfterBlockage(ticketId, blockedAtMs, scope);
  return reports.length;
}

/** Efface le verrou si un blocage postérieur au lancement est relevé sur ce ticket. */
async function releaseLockAfterBlockage(
  ticketId: string,
  blockedAtMs: number,
  scope: { correlationId: string; userId?: string },
): Promise<void> {
  const released = await getFirestore().runTransaction(async (tx) => {
    const snap = await tx.get(statusRef());
    const lock = deliveryLockView(snap.data()?.delivery_running);
    if (!blockageReleasesLock(lock, ticketId, blockedAtMs)) return false;
    tx.set(statusRef(), { delivery_running: null }, { merge: true });
    return true;
  });
  if (released) {
    await logInfo({
      message: `Tickets : verrou des livraisons libéré, blocage relevé sur le ticket ${ticketId}`,
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}

// ── Verrou global ───────────────────────────────────────────────────────────

/**
 * Prend le verrou des livraisons pour `ticketId`, en transaction. Refuse
 * (`failed-precondition`, `delivery_running_elsewhere`) si une livraison
 * d'un autre ticket le tient encore (`deliveryLockActive` : échéance non
 * passée, ticket verrouillé toujours En cours). Un verrou du même ticket est
 * écrasé : la règle « en cours » du ticket a déjà décidé.
 */
export async function claimDeliveryLock(
  ticketId: string,
  issueNumber: number,
  launchedAtMs: number,
): Promise<void> {
  const db = getFirestore();
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(statusRef());
    const lock = deliveryLockView(snap.data()?.delivery_running);
    if (lock !== null && typeof lock.ticketId === "string" && lock.ticketId !== ticketId) {
      const locked =
        lock.ticketId.length > 0 && !lock.ticketId.includes("/")
          ? await tx.get(ticketRef(lock.ticketId))
          : null;
      const active = deliveryLockActive({
        lock,
        lockedTicketRawStatus: locked?.exists ? locked.data()?.status : null,
        nowMs: Date.now(),
      });
      if (active) {
        throw new HttpsError(
          "failed-precondition",
          deliveryRunningElsewhereMessage(lock.issueNumber as number, lock.launchedAtMs as number),
          { reason: "delivery_running_elsewhere", ticketId: lock.ticketId },
        );
      }
    }
    tx.set(
      statusRef(),
      {
        delivery_running: {
          ticket_id: ticketId,
          issue_number: issueNumber,
          launched_at: Timestamp.fromMillis(launchedAtMs),
          retry_after: Timestamp.fromMillis(launchedAtMs + LAUNCH_RETRY_MS.livraison),
        },
      },
      { merge: true },
    );
  });
}

/**
 * Rend le verrou d'une livraison qui n'a pas eu lieu (refus, panne avant
 * l'appel, refus de l'API) : seulement s'il porte encore ce ticket et ce
 * lancement. Au mieux, journalisé : le verrou expire seul à son échéance.
 */
export async function releaseDeliveryLock(
  ticketId: string,
  launchedAtMs: number,
  scope: { correlationId: string; userId?: string },
): Promise<void> {
  try {
    await getFirestore().runTransaction(async (tx) => {
      const snap = await tx.get(statusRef());
      const lock = deliveryLockView(snap.data()?.delivery_running);
      if (lock === null || lock.ticketId !== ticketId || lock.launchedAtMs !== launchedAtMs) {
        return;
      }
      tx.set(statusRef(), { delivery_running: null }, { merge: true });
    });
  } catch (err) {
    await logError({
      message: `Tickets : verrou des livraisons du ticket ${ticketId} non rendu (expire seul en 3 h)`,
      errorDescription: describe(err),
      correlationId: scope.correlationId,
      userId: scope.userId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}
