/**
 * Planning — pose les règles de variété par défaut dans les contraintes
 * globales des comptes existants, sans appel de modèle.
 *
 * Le texte vient du client (`kDefaultGlobalConstraints`) : le serveur n'en
 * garde pas de copie, et une copie de plus serait un texte qui diverge.
 *
 * Pour chaque `planning_config/{uid}`, hors du compte qui lance l'opération :
 *   - contraintes vides ou absentes → le texte par défaut ;
 *   - contraintes déjà écrites → le texte ajouté à la suite, rien n'est effacé ;
 *   - texte déjà présent → rien.
 *
 * Réentrant par construction : un compte traité contient le texte et est
 * sauté au passage suivant. Un document par famille, quelques dizaines au
 * plus : pas de curseur, mais les mêmes bornes que les autres backfills.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_PLANNING_CONFIG, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "planning_defaults_backfill";

/** Longueur maximale du texte reçu : une consigne, pas un document. */
export const MAX_DEFAULT_CONSTRAINTS_LENGTH = 4000;
/** Comptes traités par appel. */
const MAX_DOCS = 500;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois comptes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillPlanningDefaultsRequest {
  text?: unknown;
}

export interface BackfillPlanningDefaultsResponse {
  examines: number;
  /** Contraintes vides : texte posé. */
  poses: number;
  /** Contraintes déjà écrites : texte ajouté à la suite. */
  completes: number;
  /** Texte déjà présent. */
  dejaAJour: number;
  /** Compte de l'administrateur qui lance l'opération. */
  ignores: number;
  echoues: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
}

/**
 * Ce qu'il faut écrire dans les contraintes [current] pour qu'elles portent
 * [text], ou `null` si elles le portent déjà. Pur, pour les tests.
 */
export function mergedConstraints(current: unknown, text: string): string | null {
  const existing = typeof current === "string" ? current.trim() : "";
  if (existing.length === 0) return text;
  if (existing.includes(text)) return null;
  return `${existing}\n\n${text}`;
}

export const backfillPlanningDefaultsFn = onCall<BackfillPlanningDefaultsRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillPlanningDefaultsResponse> => {
    const ctx = await requireAdmin(req, FEATURE);
    const raw = req.data?.text;
    const text = typeof raw === "string" ? raw.trim() : "";
    if (text.length === 0 || text.length > MAX_DEFAULT_CONSTRAINTS_LENGTH) {
      throw new HttpsError(
        "invalid-argument",
        `Texte par défaut absent ou trop long (${MAX_DEFAULT_CONSTRAINTS_LENGTH} caractères au plus).`,
      );
    }

    const db = getFirestore();
    const deadline = Date.now() + 540_000 - DEADLINE_MARGIN_MS;
    const response: BackfillPlanningDefaultsResponse = {
      examines: 0,
      poses: 0,
      completes: 0,
      dejaAJour: 0,
      ignores: 0,
      echoues: 0,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      stoppedByErrors: false,
      completed: false,
    };

    const snap = await db
      .collection(COLL_PLANNING_CONFIG)
      .limit(MAX_DOCS + 1)
      .get();
    let consecutiveFailures = 0;
    let treated = 0;
    for (const doc of snap.docs) {
      if (Date.now() > deadline) {
        response.stoppedByDeadline = true;
        break;
      }
      if (treated >= MAX_DOCS) {
        response.stoppedByBudget = true;
        break;
      }
      if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
        response.stoppedByErrors = true;
        break;
      }
      response.examines += 1;
      // Le compte qui lance l'opération garde ses propres règles.
      if (doc.id === ctx.userId) {
        response.ignores += 1;
        continue;
      }
      const current = doc.get("global_constraints") as unknown;
      const next = mergedConstraints(current, text);
      if (next == null) {
        response.dejaAJour += 1;
        continue;
      }
      try {
        await doc.ref.update({ global_constraints: next });
        if (typeof current === "string" && current.trim().length > 0) {
          response.completes += 1;
        } else {
          response.poses += 1;
        }
        treated += 1;
        consecutiveFailures = 0;
      } catch (e) {
        response.echoues += 1;
        consecutiveFailures += 1;
        await logError("Contraintes de variété par défaut — échec sur un compte", {
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { configUid: doc.id, consecutiveFailures },
        });
      }
    }
    response.completed =
      !response.stoppedByDeadline &&
      !response.stoppedByBudget &&
      !response.stoppedByErrors &&
      snap.size <= MAX_DOCS;

    await logInfo({
      message: "Contraintes de variété par défaut — passage",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      extra: { ...response },
    });
    return response;
  },
);
