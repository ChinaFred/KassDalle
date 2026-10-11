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
 * sauté au passage suivant. Un document par compte, quelques dizaines : pas
 * de curseur, mais les mêmes bornes que les autres backfills.
 */

import { createHash } from "node:crypto";

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_PLANNING_CONFIG, COLL_USERS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { requireAdmin, type AuthContext } from "./_auth";
import {
  BACKFILL_REVIEW_LIMIT,
  BackfillReview,
  shortErrorMessage,
  type BackfillReviewList,
} from "./_backfillReview";
import { SHORT_TEXT_MAX_CHARS } from "./_inputBounds";

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
  /**
   * Contraintes qui dépasseraient la longueur admise par la génération une
   * fois le texte ajouté : laissées telles quelles, sinon le compte ne
   * pourrait plus planifier.
   */
  tropLongs: number;
  echoues: number;
  /** Comptes pas encore examinés à l'arrêt du passage. */
  restants: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  /** Comptes laissés tels quels ou en échec, nommés, avec la raison. */
  aRevoir: BackfillReviewList;
}

/**
 * Nom lisible des comptes à revoir : `display_name`, à défaut l'adresse, à
 * défaut l'identifiant. Une lecture impossible est journalisée et laisse les
 * identifiants : la liste reste utilisable.
 */
async function accountLabels(
  db: FirebaseFirestore.Firestore,
  ctx: AuthContext,
  uids: readonly string[],
): Promise<Map<string, string>> {
  const labels = new Map<string, string>();
  if (uids.length === 0) return labels;
  try {
    const snaps = await db.getAll(...uids.map((uid) => db.collection(COLL_USERS).doc(uid)));
    for (const snap of snaps) {
      const data = (snap.data() ?? {}) as Record<string, unknown>;
      const name =
        (typeof data.display_name === "string" && data.display_name.trim()) ||
        (typeof data.email === "string" && data.email.trim()) ||
        "";
      if (name) labels.set(snap.id, name);
    }
  } catch (e) {
    await logError("Contraintes de variété par défaut — noms des comptes à revoir illisibles", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { uids: uids.slice(0, 50) },
    });
  }
  return labels;
}

/**
 * Ce qu'il faut écrire dans les contraintes [current] pour qu'elles portent
 * [text] : le texte fusionné, `null` si elles le portent déjà, ou
 * `"too_long"` si la fusion dépasserait `maxLength` — la génération refuse
 * au-delà, le compte ne pourrait plus planifier. Pur, pour les tests.
 */
export function mergedConstraints(
  current: unknown,
  text: string,
  maxLength: number = SHORT_TEXT_MAX_CHARS,
): string | null | "too_long" {
  const existing = typeof current === "string" ? current.trim() : "";
  if (existing.includes(text) && existing.length > 0) return null;
  const merged = existing.length === 0 ? text : `${existing}\n\n${text}`;
  return merged.length > maxLength ? "too_long" : merged;
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
      tropLongs: 0,
      echoues: 0,
      restants: 0,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      stoppedByErrors: false,
      completed: false,
      aRevoir: { items: [], total: 0 },
    };
    // Comptes à revoir, nommés à la fin du passage par une seule lecture.
    const toReview: { uid: string; reason: string }[] = [];

    // Un document par compte : toute la collection tient en une lecture.
    // Les comptes déjà à jour ne comptent pas dans la borne d'écritures,
    // si bien qu'une relance avance toujours au-delà des précédents.
    const snap = await db.collection(COLL_PLANNING_CONFIG).get();
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
      if (next === "too_long") {
        response.tropLongs += 1;
        toReview.push({
          uid: doc.id,
          reason: "Contraintes trop longues : texte non ajouté",
        });
        continue;
      }
      try {
        // Précondition sur la date d'écriture lue : si la personne enregistre
        // ses préférences entre-temps, l'écriture échoue au lieu d'écraser
        // son texte par l'ancien — relancer reprend le compte.
        await doc.ref.update({ global_constraints: next }, { lastUpdateTime: doc.updateTime });
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
        toReview.push({ uid: doc.id, reason: `Échec d'écriture : ${shortErrorMessage(e)}` });
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
    response.restants = snap.size - response.examines;
    response.completed = response.restants === 0 && !response.stoppedByErrors;
    const review = new BackfillReview();
    const labels = await accountLabels(
      db,
      ctx,
      toReview.slice(0, BACKFILL_REVIEW_LIMIT).map((r) => r.uid),
    );
    for (const r of toReview) {
      review.add({
        kind: "account",
        id: r.uid,
        label: labels.get(r.uid) ?? r.uid,
        reason: r.reason,
      });
    }
    response.aRevoir = review.toJSON();

    await logInfo({
      message: "Contraintes de variété par défaut — passage",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      // Le texte posé chez les autres se retrouve : sa longueur et son empreinte.
      extra: {
        ...response,
        textLength: text.length,
        textSha256: createHash("sha256").update(text).digest("hex"),
      },
    });
    return response;
  },
);
