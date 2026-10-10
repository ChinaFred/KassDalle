/**
 * Profils publics — sème `user_profiles/{uid}` pour les comptes existants.
 *
 * Depuis la v0.23.14, `users/{uid}` ne se lit plus que par son titulaire et
 * par un administrateur, et les écrans qui affichent le nom d'un autre membre
 * lisent `user_profiles/{uid}`. Le déclencheur `syncUserClaims` tient ce
 * profil à jour à chaque écriture sur le compte ; un compte que personne n'a
 * touché depuis le déploiement n'en a pas encore, et son nom s'affiche
 * « Membre ». Ce backfill parcourt `users/` et crée, met à jour ou supprime
 * chaque profil par `syncPublicProfile`, la même fonction que le déclencheur.
 *
 * Aucun appel de modèle. Réentrant : un profil déjà à jour n'est pas réécrit.
 * Borné par le délai, par un nombre de comptes par appel et par trois échecs
 * de suite ; reprend au curseur.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_USERS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { syncPublicProfile } from "../triggers/userPublicProfile";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient le dernier compte examiné, et le compte rendu du passage. */
export const USER_PROFILES_CHECKPOINT_DOC_ID = "user_profiles_backfill_checkpoint";

const FEATURE = "user_profiles_backfill";

const DEFAULT_MAX_USERS = 2000;
const PAGE_SIZE = 300;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois comptes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillUserProfilesRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

export interface BackfillUserProfilesResponse {
  examines: number;
  /** Profil créé (compte approuvé sans profil). */
  crees: number;
  /** Profil réécrit (nom ou couverture différents). */
  misAJour: number;
  /** Profil retiré (compte en attente qui en portait un). */
  supprimes: number;
  /** Profil déjà conforme, ou compte en attente sans profil : rien d'écrit. */
  dejaAJour: number;
  echoues: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
}

export const backfillUserProfilesFn = onCall<BackfillUserProfilesRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillUserProfilesResponse> => {
    const ctx = await requireAdmin(req, FEATURE);
    const db = getFirestore();

    const maxMinutesRaw = Number(req.data?.maxMinutes ?? 8);
    const maxMinutes = Number.isFinite(maxMinutesRaw)
      ? Math.max(1, Math.min(8.5, maxMinutesRaw))
      : 8;
    const maxDocsRaw = Number(req.data?.maxDocs ?? DEFAULT_MAX_USERS);
    const maxDocs = Number.isFinite(maxDocsRaw)
      ? Math.max(1, Math.min(10000, Math.trunc(maxDocsRaw)))
      : DEFAULT_MAX_USERS;
    const deadline = Date.now() + maxMinutes * 60_000 - DEADLINE_MARGIN_MS;

    let cursor = await getBackfillCursor({
      db,
      docId: USER_PROFILES_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    });

    const response: BackfillUserProfilesResponse = {
      examines: 0,
      crees: 0,
      misAJour: 0,
      supprimes: 0,
      dejaAJour: 0,
      echoues: 0,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      stoppedByErrors: false,
      completed: false,
    };
    let consecutiveFailures = 0;

    pages: for (;;) {
      let query = db.collection(COLL_USERS).orderBy("__name__").limit(PAGE_SIZE);
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
        try {
          const outcome = await syncPublicProfile(doc.id, doc.data() as Record<string, unknown>);
          if (outcome === "created") response.crees += 1;
          else if (outcome === "updated") response.misAJour += 1;
          else if (outcome === "deleted") response.supprimes += 1;
          else response.dejaAJour += 1;
          consecutiveFailures = 0;
        } catch (e) {
          response.echoues += 1;
          consecutiveFailures += 1;
          await logError({
            message: "Profils publics — échec sur un compte",
            correlationId: ctx.correlationId,
            userId: ctx.userId,
            moduleType: "DESIGN",
            feature: FEATURE,
            errorDescription: e instanceof Error ? e.message : String(e),
            extra: { targetUid: doc.id, consecutiveFailures },
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
      docId: USER_PROFILES_CHECKPOINT_DOC_ID,
      lastDocId: response.completed ? null : cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
      lastReport: { ...response },
    });

    await logInfo({
      message: "Profils publics — reprise",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      extra: { ...response, maxMinutes, maxDocs },
    });

    return response;
  },
);
