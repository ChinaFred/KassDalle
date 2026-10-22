/**
 * Conservation — supprime les rapports d'erreur de plus de 90 jours et les
 * captures de ticket orphelines. Aucun appel de modèle.
 *
 * Backfill récurrent (`retention`) : chaque jour apporte de nouveaux rapports
 * à faire vieillir. Il se programme dans Admin › Backfills, et un passage
 * programmé part par `scheduledBackfills`.
 *
 * Pas de TTL Firestore : il demanderait que le client écrive une date
 * d'expiration dans chaque rapport, et une application restée sur une
 * ancienne version (APK, cache web) ne l'écrirait pas — ses rapports ne
 * seraient jamais effacés. Ici, l'âge se lit sur `timestamp`, que tous les
 * clients écrivent.
 *
 * Deux phases :
 *  1. Rapports : `error_reports` dont `timestamp` est antérieur à
 *     maintenant − 90 jours, par lots, plus anciens d'abord. Un rapport sans
 *     `timestamp` n'est pas lu par la requête et reste.
 *  2. Captures : fichiers `tickets/{uid}/{ticketId}/…` de Storage, créés il y
 *     a plus d'un jour (un dépôt en cours n'est pas encore rattaché), dont le
 *     ticket n'existe pas, appartient à un autre compte, ou ne pointe pas sur
 *     ce fichier (`screenshot_path`). Une capture rattachée reste, quel que
 *     soit son âge : elle fait partie du ticket.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import { COLL_TICKETS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { isPlausibleDocId } from "../tickets/rules";
import { logError, logInfo } from "../logging";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "retention_backfill";
const COLL_ERROR_REPORTS = "error_reports";

/** Durée de conservation d'un rapport d'erreur. */
export const ERROR_REPORT_RETENTION_DAYS = 90;
/** Âge minimal d'une capture avant d'être jugée orpheline : son dépôt est fini. */
export const ORPHAN_SCREENSHOT_MIN_AGE_MS = 24 * 60 * 60 * 1000;

/** Rapports supprimés par passage, par défaut. */
const DEFAULT_MAX_REPORTS = 5000;
/** Lot d'une écriture groupée (plafond Firestore : 500). */
const BATCH_SIZE = 400;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;
/** Captures examinées par passage, au plus. */
const MAX_SCREENSHOTS_PER_PASS = 5000;
/** Fichiers de `tickets/` listés par page. */
const SCREENSHOT_PAGE_SIZE = 500;
/** Trois échecs de suite : une panne, pas trois éléments difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface RetentionRequest {
  maxMinutes?: number;
  maxDocs?: number;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface RetentionResponse {
  /** Rapports d'erreur supprimés. */
  rapportsSupprimes: number;
  /** Tous les rapports trop anciens sont partis. */
  rapportsParcourus: boolean;
  /** Tentatives de suppression d'un lot de rapports en échec. */
  lotsRapportsEchoues: number;
  /** Captures examinées dans `tickets/`. */
  capturesExaminees: number;
  /** Captures orphelines supprimées. */
  capturesSupprimees: number;
  /** Captures trop récentes pour être jugées. */
  capturesRecentes: number;
  capturesEchouees: number;
  /** Toutes les captures ont été examinées. */
  capturesParcourues: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  aRevoir: BackfillReviewList;
}

function emptyResponse(): RetentionResponse {
  return {
    rapportsSupprimes: 0,
    rapportsParcourus: false,
    lotsRapportsEchoues: 0,
    capturesExaminees: 0,
    capturesSupprimees: 0,
    capturesRecentes: 0,
    capturesEchouees: 0,
    capturesParcourues: false,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
}

/** Instant avant lequel un rapport d'erreur est supprimé. */
export function reportCutoff(nowMs: number): Date {
  return new Date(nowMs - ERROR_REPORT_RETENTION_DAYS * 24 * 60 * 60 * 1000);
}

/** `tickets/{uid}/{ticketId}/{fichier}` découpé, ou `null` pour un autre chemin. */
export function parseScreenshotPath(
  path: string,
): { uid: string; ticketId: string; fileName: string } | null {
  const parts = path.split("/");
  if (parts.length !== 4 || parts[0] !== "tickets") return null;
  const [, uid, ticketId, fileName] = parts;
  if (!uid || !ticketId || !fileName) return null;
  return { uid, ticketId, fileName };
}

/**
 * Une capture est orpheline quand son ticket n'existe pas, appartient à un
 * autre compte, ou ne la désigne pas comme sa capture.
 */
export function isOrphanScreenshot(
  path: string,
  uid: string,
  ticket: Record<string, unknown> | undefined,
): boolean {
  if (!ticket) return true;
  if (ticket.author_uid !== uid) return true;
  return ticket.screenshot_path !== path;
}

interface Bounds {
  deadline: number;
  maxDocs: number;
}

// ── Phase 1 : rapports d'erreur ─────────────────────────────────────────────

async function runReportsPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  response: RetentionResponse,
): Promise<void> {
  const cutoff = Timestamp.fromDate(reportCutoff(Date.now()));
  let consecutiveFailures = 0;
  for (;;) {
    if (Date.now() > bounds.deadline) {
      response.stoppedByDeadline = true;
      return;
    }
    if (response.rapportsSupprimes >= bounds.maxDocs) {
      response.stoppedByBudget = true;
      return;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      return;
    }
    const size = Math.min(BATCH_SIZE, bounds.maxDocs - response.rapportsSupprimes);
    const page = await db
      .collection(COLL_ERROR_REPORTS)
      .where("timestamp", "<", cutoff)
      .orderBy("timestamp")
      .limit(size)
      .get();
    if (page.empty) {
      response.rapportsParcourus = true;
      return;
    }
    try {
      const batch = db.batch();
      for (const doc of page.docs) batch.delete(doc.ref);
      await batch.commit();
      response.rapportsSupprimes += page.size;
      consecutiveFailures = 0;
    } catch (e) {
      // Le lot est relu au tour suivant ; trois échecs de suite arrêtent la
      // phase, qui n'est alors pas parcourue. Pas d'entrée « à revoir » : un
      // rapport ne s'ouvre pas depuis la liste ; le compteur et le journal
      // disent l'échec.
      consecutiveFailures += 1;
      response.lotsRapportsEchoues += 1;
      await logError("Conservation — échec de suppression d'un lot de rapports d'erreur", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { firstReportId: page.docs[0].id, size: page.size, consecutiveFailures },
      });
      continue;
    }
    if (page.size < size) {
      response.rapportsParcourus = true;
      return;
    }
  }
}

// ── Phase 2 : captures de ticket orphelines ─────────────────────────────────

async function runScreenshotsPhase(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  bounds: Bounds,
  response: RetentionResponse,
  review: BackfillReview,
): Promise<void> {
  const bucket = getStorage().bucket();
  const nowMs = Date.now();
  let consecutiveFailures = 0;
  let pageToken: string | undefined;
  let unreadableSeen = false;

  // Par pages : le nombre de fichiers sous `tickets/` dépend de ce que les
  // comptes déposent, et le délai se vérifie entre deux pages.
  for (;;) {
    if (Date.now() > bounds.deadline) {
      response.stoppedByDeadline = true;
      return;
    }
    const [files, next] = await bucket.getFiles({
      prefix: "tickets/",
      maxResults: SCREENSHOT_PAGE_SIZE,
      autoPaginate: false,
      ...(pageToken ? { pageToken } : {}),
    });
    const tickets = await readTickets(db, ctx, files);
    if (tickets.unreadable.size > 0) unreadableSeen = true;

    for (const file of files) {
      if (Date.now() > bounds.deadline) {
        response.stoppedByDeadline = true;
        return;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        return;
      }
      if (response.capturesExaminees >= MAX_SCREENSHOTS_PER_PASS) {
        response.stoppedByBudget = true;
        return;
      }
      const parsed = parseScreenshotPath(file.name);
      if (!parsed) continue;
      response.capturesExaminees += 1;

      const created = Date.parse(String(file.metadata?.timeCreated ?? ""));
      if (!Number.isFinite(created) || nowMs - created < ORPHAN_SCREENSHOT_MIN_AGE_MS) {
        response.capturesRecentes += 1;
        continue;
      }
      // Lot de tickets illisible : aucun fichier de ce lot n'est jugé.
      if (tickets.unreadable.has(parsed.ticketId)) continue;
      if (!isOrphanScreenshot(file.name, parsed.uid, tickets.found.get(parsed.ticketId))) {
        continue;
      }

      try {
        await file.delete();
        response.capturesSupprimees += 1;
        consecutiveFailures = 0;
      } catch (e) {
        response.capturesEchouees += 1;
        consecutiveFailures += 1;
        review.add({
          kind: "ticket",
          id: parsed.ticketId,
          label: `Capture du ticket ${parsed.ticketId}`,
          reason: `Échec de suppression : ${shortErrorMessage(e)}`,
        });
        await logError("Conservation — échec de suppression d'une capture orpheline", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { ticketId: parsed.ticketId, consecutiveFailures },
        });
      }
    }

    pageToken = (next as { pageToken?: string } | null)?.pageToken;
    if (!pageToken) {
      // Un lot de tickets illisible, sur n'importe quelle page, laisse des
      // captures non jugées : le parcours n'est pas fini.
      response.capturesParcourues = !unreadableSeen;
      return;
    }
  }
}

/**
 * Identifiant de ticket lisible par Firestore. Un dépôt Storage accepte tout
 * segment ; `__x__` est réservé par Firestore et ferait échouer la lecture
 * groupée. Un tel identifiant ne peut désigner aucun ticket.
 */
export function isReadableTicketId(id: string): boolean {
  return isPlausibleDocId(id) && !/^__.*__$/.test(id);
}

/**
 * Les tickets des fichiers d'une page, lus par lots de cent. Un identifiant
 * illisible est traité comme un ticket absent ; un lot en échec est
 * journalisé et ses identifiants sont mis à part (`unreadable`).
 */
async function readTickets(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  files: { name: string }[],
): Promise<{ found: Map<string, Record<string, unknown>>; unreadable: Set<string> }> {
  const ids = new Set<string>();
  for (const file of files) {
    const parsed = parseScreenshotPath(file.name);
    if (parsed && isReadableTicketId(parsed.ticketId)) ids.add(parsed.ticketId);
  }
  const found = new Map<string, Record<string, unknown>>();
  const unreadable = new Set<string>();
  const list = [...ids];
  for (let i = 0; i < list.length; i += 100) {
    const chunk = list.slice(i, i + 100);
    try {
      const snaps = await db.getAll(...chunk.map((id) => db.collection(COLL_TICKETS).doc(id)));
      for (const snap of snaps) {
        if (snap.exists) found.set(snap.id, snap.data() as Record<string, unknown>);
      }
    } catch (e) {
      for (const id of chunk) unreadable.add(id);
      await logError("Conservation — lecture d'un lot de tickets impossible", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { tickets: chunk.length },
      });
    }
  }
  return { found, unreadable };
}

// ── Point d'entrée ──────────────────────────────────────────────────────────

export const backfillRetentionFn = onCall<RetentionRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "512MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_REPORTS);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(20_000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_REPORTS;

    return runBackfillFromCallable({
      key: "retention",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runRetentionPass(ctx, { deadlineMs: Date.now() + maxMinutes * 60_000, maxDocs }),
      summarize: summarizeRetention,
    });
  },
);

/** Ce qu'un passage a le droit de faire. */
export interface RetentionPassOptions {
  /** Instant de fin du passage ; la marge est déduite ici. */
  deadlineMs: number;
  /** Rapports d'erreur supprimés au plus. */
  maxDocs: number;
}

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeRetention(r: RetentionResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.completed ? 0 : null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    // Parcours fini mais captures en échec : « incomplet » sans reprise
    // horaire ; elles se retentent au prochain passage programmé.
    unresolved: r.capturesEchouees,
  };
}

/** Un passage, quelle que soit son entrée : le callable ou `scheduledBackfills`. */
export async function runRetentionPass(
  ctx: AuthContext,
  options: RetentionPassOptions,
): Promise<RetentionResponse> {
  const db = getFirestore();
  const bounds: Bounds = {
    deadline: options.deadlineMs - DEADLINE_MARGIN_MS,
    maxDocs: options.maxDocs,
  };
  const response = emptyResponse();
  const review = new BackfillReview();

  await runReportsPhase(db, ctx, bounds, response);
  if (!response.stoppedByDeadline && !response.stoppedByErrors) {
    await runScreenshotsPhase(db, ctx, bounds, response, review);
  }

  // Le parcours seul ; les captures en échec partent dans `unresolved`.
  response.completed = response.rapportsParcourus && response.capturesParcourues;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "Conservation — rapports d'erreur et captures orphelines",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response), maxDocs: options.maxDocs },
  });

  return response;
}
