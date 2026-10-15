/**
 * Tickets des membres : création, capture jointe, relance d'un envoi.
 *
 * - `submitTicket` — membre approuvé non révoqué (`requireAuth`). Valide les
 *   entrées (`tickets/rules.ts`), applique les plafonds du jour dans la
 *   transaction qui crée `tickets/{ticketId}` en `sending`, puis tente de
 *   publier l'Issue GitHub. Un envoi en échec ne fait pas échouer l'appel : le
 *   ticket reste « Envoi en cours » et la tâche horaire le reprend.
 *   Rend `{ ticketId, status, remaining_today }` (`null` pour l'admin).
 * - `attachTicketScreenshot` — l'auteur du ticket. Vérifie le chemin
 *   `tickets/{uid}/{ticketId}/screenshot.(png|jpg)` et l'objet Storage (type
 *   MIME, taille, et signature PNG ou JPEG de ses premiers octets), puis
 *   écrit `screenshot_path`. La capture ne part jamais sur GitHub.
 * - `retryTicketSend` — administrateur (`requireAdmin`). Remet le compteur
 *   d'essais à zéro et tente l'envoi une fois.
 * - `validateTicket` — administrateur. Pose l'étiquette `validé` sur l'Issue
 *   d'un ticket Analysé (hors Question) et écrit `validated`
 *   (`tickets/decisions.ts`). Rend `{ status, changed }`.
 * - `refuseTicket` — administrateur. Publie `Réponse : <motif>` sur l'Issue,
 *   la ferme `not_planned` et écrit `refused` et `reply_text`. Rend
 *   `{ status }`. Échec partiel (motif publié, Issue ouverte) : `aborted`,
 *   `details.reason = "reply_published_close_failed"`.
 * - `answerTicketAnalysis` — administrateur. Publie la réponse de
 *   l'administrateur à la dernière analyse (`## Précisions de
 *   l'administrateur`) sur l'Issue d'un ticket Analysé ou Validé (hors
 *   Question), passe ses étiquettes à `statut:à-analyser` (retire `validé`)
 *   et ramène le ticket à Reçu (`tickets/decisions.ts`). Texte de 5 à 4 000
 *   caractères, sans adresse e-mail (`details.reason = "contains_email"`).
 *   Rend `{ status }`. Échec partiel (réponse publiée, étiquettes
 *   inchangées) : `aborted`, `details.reason = "answer_published_labels_failed"` ;
 *   une reprise ne republie pas la réponse.
 *
 * - `launchTicketAnalysis` — administrateur. Lance la routine Claude Code
 *   d'analyse sur un ticket Reçu (`analyse #N`). Rend `{ outcome, session_url }`.
 * - `launchTicketDevelopment` — administrateur. Lance la routine de
 *   développement sur un ticket Validé (`developpement #N`). Même réponse. Refusé avant tout comptage
 *   quand la dernière analyse attend une réponse
 *   (`details.reason = "launch_needs_answer"`).
 *   Les deux suivent `tickets/launch.ts` : bail partagé avec les décisions,
 *   plafond quotidien (`launches_per_day`, 10 par défaut), Issue relue, appel
 *   unique sans relance. Deux callables plutôt qu'un seul avec `action` :
 *   chacune ne monte que les secrets de sa routine.
 *
 * Plafonds : `app_config/tickets` (`per_member_per_day`, `global_per_day`,
 * 5 et 30 si le document manque), jour calendaire Europe/Paris, compteurs
 * dans `ticket_quotas`. L'administrateur n'a pas de plafond et n'use pas le
 * plafond de la famille.
 *
 * Aucun appel de modèle : pas de poste d'IA.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { getStorage } from "firebase-admin/storage";

import {
  COLL_APP_CONFIG,
  COLL_TICKETS,
  COLL_TICKET_QUOTAS,
  GITHUB_TICKETS_TOKEN,
  MAX_CALLABLE_INSTANCES,
  REGION,
  TICKETS_CONFIG_DOC_ID,
  TICKETS_ROUTINE_ANALYSIS_ID,
  TICKETS_ROUTINE_ANALYSIS_TOKEN,
  TICKETS_ROUTINE_DEV_ID,
  TICKETS_ROUTINE_DEV_TOKEN,
} from "../config";
import { isAdminAccount, requireAdmin, requireAuth } from "./_auth";
import { SHORT_TEXT_MAX_CHARS, requireBoundedText } from "./_inputBounds";
import { logError, logInfo, logWarn } from "../logging";
import {
  SCREENSHOT_MAX_BYTES,
  SCREENSHOT_SIGNATURE_BYTES,
  TicketInputError,
  globalQuotaDocId,
  readAnswerText,
  readRefusalReason,
  isPlausibleDocId,
  memberQuotaDocId,
  parisDay,
  quotaMessage,
  quotaRefusal,
  readTicketInput,
  readTicketLimits,
  screenshotBytesMatch,
  screenshotContentType,
  screenshotPaths,
  type TicketStatus,
} from "../tickets/rules";
import { sendTicket } from "../tickets/service";
import {
  answerTicketDecision,
  refuseTicketDecision,
  validateTicketDecision,
} from "../tickets/decisions";
import { launchTicketSession, type LaunchResult } from "../tickets/launch";
import type { LaunchAction } from "../tickets/rules";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const opts = {
  region: REGION,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
  timeoutSeconds: 60,
};

/** Durée de vie d'un compteur du plafond (politique TTL sur `expires_at`). */
const QUOTA_TTL_DAYS = 7;

function readCount(data: FirebaseFirestore.DocumentData | undefined): number {
  const n = data?.count;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export interface SubmitTicketResult {
  ticketId: string;
  status: "received" | "sending";
  remaining_today: number | null;
}

export const submitTicket = onCall(
  { ...opts, secrets: [GITHUB_TICKETS_TOKEN] },
  async (req): Promise<SubmitTicketResult> => {
    const ctx = await requireAuth(req, "ticket");
    const raw = (req.data ?? {}) as Record<string, unknown>;

    // Garde de taille brute (`_inputBounds.ts`) avant tout nettoyage : un texte
    // de plusieurs mégaoctets est refusé sans être parcouru. Les bornes fines
    // (5 à 100, 1 à 2 000) sont celles de `readTicketInput`.
    for (const field of ["title", "description", "screen", "app_version"] as const) {
      requireBoundedText(raw[field], { field, max: SHORT_TEXT_MAX_CHARS });
    }

    let input: ReturnType<typeof readTicketInput>;
    try {
      input = readTicketInput(raw);
    } catch (err) {
      if (err instanceof TicketInputError) {
        throw new HttpsError("invalid-argument", err.message, { field: err.field });
      }
      throw err;
    }
    if (input.screenReplaced) {
      await logWarn({
        message:
          "submitTicket : écran reçu sans forme de modèle de route, remplacé par « inconnu »",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        feature: "tickets",
      });
    }

    const db = getFirestore();
    const isAdmin = await isAdminAccount(ctx.userId);

    const configSnap = await db.collection(COLL_APP_CONFIG).doc(TICKETS_CONFIG_DOC_ID).get();
    const limits = readTicketLimits(configSnap.exists ? configSnap.data() : undefined);
    if (limits === null) {
      await logError({
        message: "submitTicket : app_config/tickets illisible, envoi refusé",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        feature: "tickets",
        extra: { config: configSnap.data() ?? null },
      });
      throw new HttpsError(
        "failed-precondition",
        "Le réglage des tickets est illisible. Prévenez l'administrateur.",
      );
    }

    const now = new Date();
    const day = parisDay(now);
    const memberRef = db.collection(COLL_TICKET_QUOTAS).doc(memberQuotaDocId(ctx.userId, day));
    const globalRef = db.collection(COLL_TICKET_QUOTAS).doc(globalQuotaDocId(day));
    const ticketDoc = db.collection(COLL_TICKETS).doc();
    const expiresAt = Timestamp.fromMillis(now.getTime() + QUOTA_TTL_DAYS * 86_400_000);

    let outcome:
      | { refused: { reason: "member_daily_limit" | "global_daily_limit"; limit: number } }
      | { memberCountAfter: number };
    try {
      outcome = await db.runTransaction(async (tx) => {
        const [memberSnap, globalSnap] = await Promise.all([tx.get(memberRef), tx.get(globalRef)]);
        const memberCount = readCount(memberSnap.data());
        const globalCount = readCount(globalSnap.data());
        const refused = quotaRefusal({ isAdmin, memberCount, globalCount, limits });
        if (refused) return { refused };

        if (!isAdmin) {
          const counter = { day, count: FieldValue.increment(1), expires_at: expiresAt };
          tx.set(memberRef, { ...counter, uid: ctx.userId }, { merge: true });
          tx.set(globalRef, counter, { merge: true });
        }
        const serverNow = FieldValue.serverTimestamp();
        tx.create(ticketDoc, {
          type: input.type,
          title: input.title,
          description: input.description,
          screen: input.screen,
          app_version: input.app_version,
          platform: input.platform,
          screenshot_path: null,
          author_uid: ctx.userId,
          created_at: serverNow,
          updated_at: serverNow,
          status: "sending",
          status_changed_at: serverNow,
          seen_by_author_at: null,
          github_issue_number: null,
          github_url: null,
          send_attempts: 0,
          last_send_error: null,
          reply_text: null,
        });
        return { memberCountAfter: memberCount + 1 };
      });
    } catch (err) {
      await logError({
        message: "submitTicket : ticket non enregistré",
        errorDescription: describe(err),
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        feature: "tickets",
      });
      throw new HttpsError("internal", "Le ticket n'a pas pu être enregistré. Réessayez.");
    }

    if ("refused" in outcome) {
      const { reason, limit } = outcome.refused;
      await logInfo({
        message: `submitTicket : plafond atteint (${reason}, ${limit})`,
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        feature: "tickets",
      });
      throw new HttpsError("resource-exhausted", quotaMessage(reason, limit), { reason, limit });
    }

    await logInfo({
      message: `submitTicket : ticket ${ticketDoc.id} enregistré (${input.type})`,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: ticketDoc.id,
      feature: "tickets",
    });

    const sent = await sendTicket(
      ticketDoc.id,
      { correlationId: ctx.correlationId, userId: ctx.userId },
      { lookupFirst: false },
    );
    return {
      ticketId: ticketDoc.id,
      status: sent.status === "received" ? "received" : "sending",
      remaining_today: isAdmin
        ? null
        : Math.max(0, limits.per_member_per_day - outcome.memberCountAfter),
    };
  },
);

export const attachTicketScreenshot = onCall(opts, async (req): Promise<{ ok: true }> => {
  const ctx = await requireAuth(req, "ticket_capture");
  const raw = (req.data ?? {}) as Record<string, unknown>;
  const ticketId = raw.ticketId;
  const path = raw.path;
  if (!isPlausibleDocId(ticketId)) {
    throw new HttpsError("invalid-argument", "Identifiant de ticket invalide.");
  }
  if (typeof path !== "string" || !screenshotPaths(ctx.userId, ticketId).includes(path)) {
    throw new HttpsError("invalid-argument", "Chemin de capture invalide.");
  }

  const ref = getFirestore().collection(COLL_TICKETS).doc(ticketId);
  try {
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Ce ticket n'existe plus.");
    if (snap.data()?.author_uid !== ctx.userId) {
      throw new HttpsError("permission-denied", "Ce ticket ne vous appartient pas.");
    }

    const file = getStorage().bucket().file(path);
    const [exists] = await file.exists();
    if (!exists) throw new HttpsError("not-found", "La capture n'a pas été trouvée.");
    const [metadata] = await file.getMetadata();
    const size = Number(metadata.size ?? 0);
    const contentType = String(metadata.contentType ?? "")
      .split(";")[0]
      .trim();
    if (
      contentType !== screenshotContentType(path) ||
      !(size > 0 && size <= SCREENSHOT_MAX_BYTES)
    ) {
      throw new HttpsError(
        "invalid-argument",
        "Seules les images PNG ou JPEG de 5 Mo au plus sont acceptées.",
      );
    }

    // Le type MIME est posé par le client : seuls les octets disent le format.
    const [head] = await file.download({ start: 0, end: SCREENSHOT_SIGNATURE_BYTES - 1 });
    if (!screenshotBytesMatch(head, contentType)) {
      await logWarn({
        message: `attachTicketScreenshot : capture refusée, octets autres que ${contentType}`,
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError(
        "invalid-argument",
        "Seules les images PNG ou JPEG de 5 Mo au plus sont acceptées.",
      );
    }

    await ref.update({ screenshot_path: path, updated_at: FieldValue.serverTimestamp() });
    await logInfo({
      message: `attachTicketScreenshot : capture jointe au ticket ${ticketId}`,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
    return { ok: true };
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    await logError({
      message: `attachTicketScreenshot : capture non jointe au ticket ${ticketId}`,
      errorDescription: describe(err),
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
    throw new HttpsError("internal", "La capture n'a pas pu être jointe. Réessayez.");
  }
});

export const retryTicketSend = onCall(
  { ...opts, secrets: [GITHUB_TICKETS_TOKEN] },
  async (req): Promise<{ status: TicketStatus }> => {
    const ctx = await requireAdmin(req, "ticket_relance");
    const ticketId = (req.data as Record<string, unknown> | undefined)?.ticketId;
    if (!isPlausibleDocId(ticketId)) {
      throw new HttpsError("invalid-argument", "Identifiant de ticket invalide.");
    }
    const ref = getFirestore().collection(COLL_TICKETS).doc(ticketId);
    try {
      const snap = await ref.get();
      if (!snap.exists) throw new HttpsError("not-found", "Ce ticket n'existe plus.");
      const data = snap.data() ?? {};
      if (data.status !== "sending" || data.github_issue_number != null) {
        return { status: data.status as TicketStatus };
      }
      await ref.update({ send_attempts: 0, updated_at: FieldValue.serverTimestamp() });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      await logError({
        message: `retryTicketSend : relance du ticket ${ticketId} impossible`,
        errorDescription: describe(err),
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError("internal", "La relance n'a pas pu être lancée. Réessayez.");
    }

    const sent = await sendTicket(
      ticketId,
      { correlationId: ctx.correlationId, userId: ctx.userId },
      { lookupFirst: true },
    );
    await logInfo({
      message: `retryTicketSend : ticket ${ticketId} relancé, statut ${sent.status}`,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
    return { status: sent.status };
  },
);

/** Identifiant de ticket d'une requête de décision. Lève `invalid-argument`. Pure. */
export function readTicketIdArg(data: unknown): string {
  const ticketId = (data as Record<string, unknown> | undefined)?.ticketId;
  if (!isPlausibleDocId(ticketId)) {
    throw new HttpsError("invalid-argument", "Identifiant de ticket invalide.");
  }
  return ticketId;
}

/** Motif de refus d'une requête. Lève `invalid-argument` (champ `reason`). Pure. */
export function readRefusalArg(data: unknown): string {
  const raw = (data as Record<string, unknown> | undefined)?.reason;
  requireBoundedText(raw, { field: "reason", max: SHORT_TEXT_MAX_CHARS });
  try {
    return readRefusalReason(raw);
  } catch (err) {
    if (err instanceof TicketInputError) {
      throw new HttpsError("invalid-argument", err.message, { field: err.field });
    }
    throw err;
  }
}

/**
 * Réponse de l'administrateur d'une requête. Lève `invalid-argument` (champ
 * `answer`, et `reason = "contains_email"` pour une adresse e-mail). Pure.
 */
export function readAnswerArg(data: unknown): string {
  const raw = (data as Record<string, unknown> | undefined)?.answer;
  requireBoundedText(raw, { field: "answer", max: SHORT_TEXT_MAX_CHARS });
  try {
    return readAnswerText(raw);
  } catch (err) {
    if (err instanceof TicketInputError) {
      throw new HttpsError("invalid-argument", err.message, {
        field: err.field,
        ...(err.reason !== null ? { reason: err.reason } : {}),
      });
    }
    throw err;
  }
}

export const validateTicket = onCall(
  { ...opts, secrets: [GITHUB_TICKETS_TOKEN] },
  async (req): Promise<{ status: TicketStatus; changed: boolean }> => {
    const ctx = await requireAdmin(req, "ticket_validation");
    const ticketId = readTicketIdArg(req.data);
    try {
      return await validateTicketDecision(ticketId, {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
      });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      await logError({
        message: `validateTicket : ticket ${ticketId} non validé`,
        errorDescription: describe(err),
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError("internal", "Le ticket n'a pas pu être validé. Réessayez.");
    }
  },
);

export const refuseTicket = onCall(
  { ...opts, secrets: [GITHUB_TICKETS_TOKEN] },
  async (req): Promise<{ status: TicketStatus }> => {
    const ctx = await requireAdmin(req, "ticket_refus");
    const ticketId = readTicketIdArg(req.data);
    const reason = readRefusalArg(req.data);
    try {
      return await refuseTicketDecision(ticketId, reason, {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
      });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      await logError({
        message: `refuseTicket : ticket ${ticketId} non refusé`,
        errorDescription: describe(err),
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError("internal", "Le ticket n'a pas pu être refusé. Réessayez.");
    }
  },
);

export const answerTicketAnalysis = onCall(
  { ...opts, secrets: [GITHUB_TICKETS_TOKEN] },
  async (req): Promise<{ status: TicketStatus }> => {
    const ctx = await requireAdmin(req, "ticket_reponse");
    const ticketId = readTicketIdArg(req.data);
    const answer = readAnswerArg(req.data);
    try {
      return await answerTicketDecision(ticketId, answer, {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
      });
    } catch (err) {
      if (err instanceof HttpsError) throw err;
      await logError({
        message: `answerTicketAnalysis : réponse au ticket ${ticketId} non publiée`,
        errorDescription: describe(err),
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      throw new HttpsError("internal", "La réponse n'a pas pu être publiée. Réessayez.");
    }
  },
);

/**
 * Corps commun des deux lancements. Les refus attendus (`HttpsError`) passent
 * tels quels ; toute autre panne est journalisée et rendue sans `reason` :
 * le client ne sait pas si la session est partie, et le dit.
 */
async function launch(
  req: Parameters<typeof requireAdmin>[0],
  action: LaunchAction,
): Promise<LaunchResult> {
  const ctx = await requireAdmin(req, `ticket_lancement_${action}`);
  const ticketId = readTicketIdArg(req.data);
  try {
    return await launchTicketSession(ticketId, action, {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
    });
  } catch (err) {
    if (err instanceof HttpsError) throw err;
    await logError({
      message: `launchTicket (${action}) : ticket ${ticketId} en échec inattendu`,
      errorDescription: describe(err),
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
    throw new HttpsError(
      "internal",
      "Le lancement a échoué. Regardez la section Lancements avant de relancer.",
    );
  }
}

/** Délai d'un lancement : relecture GitHub (15 s) + appel de la routine (30 s) + écritures. */
const launchOpts = { ...opts, timeoutSeconds: 120 };

export const launchTicketAnalysis = onCall(
  {
    ...launchOpts,
    secrets: [GITHUB_TICKETS_TOKEN, TICKETS_ROUTINE_ANALYSIS_ID, TICKETS_ROUTINE_ANALYSIS_TOKEN],
  },
  async (req): Promise<LaunchResult> => launch(req, "analyse"),
);

export const launchTicketDevelopment = onCall(
  {
    ...launchOpts,
    secrets: [GITHUB_TICKETS_TOKEN, TICKETS_ROUTINE_DEV_ID, TICKETS_ROUTINE_DEV_TOKEN],
  },
  async (req): Promise<LaunchResult> => launch(req, "developpement"),
);
