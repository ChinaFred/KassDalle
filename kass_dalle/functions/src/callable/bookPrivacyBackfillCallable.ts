/**
 * Confidentialité des livres — pose `is_private` sur les livres qui ne le
 * portent pas.
 *
 * Depuis la v0.23.8, les règles Firestore ne laissent lire le livre d'un autre
 * que s'il porte `is_private == false` explicitement : un livre sans le champ
 * n'est plus visible que de son créateur et des administrateurs. Le client et
 * le serveur posent le champ à chaque création ; la reprise « Reprendre la
 * confidentialité » l'avait posé sur les RECETTES antérieures, pas sur les
 * livres. Ce backfill comble l'écart.
 *
 * Valeur posée : `true` pour « Mes Recettes Secrètes » (tag `__secretes`),
 * `false` sinon — la lecture que le client faisait déjà d'un champ absent
 * (`is_private ?? false`). Un livre qui porte déjà le champ n'est pas touché.
 * Passer de « absent » à `false` ne réveille pas la propagation de
 * `onBookWritten`, qui lit un champ absent comme `false`.
 *
 * Aucun appel de modèle. Réentrant, borné par le délai, par un nombre de
 * livres par appel et par trois échecs de suite ; reprend au curseur.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_BOOKS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient le dernier livre examiné, et le compte rendu du passage. */
export const BOOK_PRIVACY_CHECKPOINT_DOC_ID = "book_privacy_backfill_checkpoint";

const FEATURE = "book_privacy_backfill";

const DEFAULT_MAX_BOOKS = 2000;
const PAGE_SIZE = 300;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois livres difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillBookPrivacyRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

export interface BackfillBookPrivacyResponse {
  examines: number;
  /** `is_private: false` posé. */
  partages: number;
  /** `is_private: true` posé (livre « Mes Recettes Secrètes »). */
  prives: number;
  /** Le champ existait déjà : rien d'écrit. */
  dejaAJour: number;
  echoues: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
}

/**
 * La valeur à poser sur un livre, ou `null` s'il porte déjà un booléen.
 * Pure et exportée pour être testée.
 */
export function bookPrivacyToSet(data: Record<string, unknown>): boolean | null {
  if (typeof data.is_private === "boolean") return null;
  const tags = Array.isArray(data.tags) ? data.tags : [];
  return tags.includes("__secretes");
}

export const backfillBookPrivacyFn = onCall<BackfillBookPrivacyRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillBookPrivacyResponse> => {
    const ctx = await requireAdmin(req, FEATURE);
    const db = getFirestore();

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_BOOKS);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(10000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_BOOKS;
    const deadline = Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS;

    let cursor = await getBackfillCursor({
      db,
      docId: BOOK_PRIVACY_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    });

    const response: BackfillBookPrivacyResponse = {
      examines: 0,
      partages: 0,
      prives: 0,
      dejaAJour: 0,
      echoues: 0,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      stoppedByErrors: false,
      completed: false,
    };
    let consecutiveFailures = 0;

    pages: for (;;) {
      let query = db.collection(COLL_BOOKS).orderBy("__name__").limit(PAGE_SIZE);
      if (cursor) query = query.startAfter(cursor);
      const page = await query.get();
      if (page.empty) {
        response.completed = true;
        break;
      }

      for (const doc of page.docs) {
        if (Date.now() > deadline) {
          response.stoppedByDeadline = true;
          break pages;
        }
        if (response.examines >= maxDocs) {
          response.stoppedByBudget = true;
          break pages;
        }
        if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
          response.stoppedByErrors = true;
          break pages;
        }

        response.examines += 1;
        const value = bookPrivacyToSet(doc.data() as Record<string, unknown>);
        if (value === null) {
          response.dejaAJour += 1;
          cursor = doc.id;
          continue;
        }
        try {
          await doc.ref.update({ is_private: value });
          if (value) response.prives += 1;
          else response.partages += 1;
          consecutiveFailures = 0;
        } catch (e) {
          response.echoues += 1;
          consecutiveFailures += 1;
          await logError({
            message: "Confidentialité des livres — échec sur un livre",
            correlationId: ctx.correlationId,
            userId: ctx.userId,
            moduleType: "DESIGN",
            feature: FEATURE,
            errorDescription: e instanceof Error ? e.message : String(e),
            extra: { bookId: doc.id, consecutiveFailures },
          });
        }
        cursor = doc.id;
      }

      if (page.size < PAGE_SIZE) {
        response.completed = true;
        break;
      }
    }

    await setBackfillCursor({
      db,
      docId: BOOK_PRIVACY_CHECKPOINT_DOC_ID,
      lastDocId: response.completed ? null : cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
      lastReport: { ...response },
    });

    await logInfo({
      message: "Confidentialité des livres — reprise",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      extra: { ...response, maxMinutes, maxDocs },
    });

    return response;
  },
);
