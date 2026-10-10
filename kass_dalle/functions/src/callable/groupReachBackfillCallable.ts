/**
 * Portée des groupes — sème `group_reach/{uid}` pour les comptes existants.
 *
 * Les règles Firestore cloisonnent la lecture des livres et des recettes par
 * groupe familial, et lisent `group_reach/{uid}` pour savoir avec qui un
 * compte partage un groupe. Le déclencheur `syncGroupReach` tient ce document
 * à jour à chaque écriture sur un groupe ; un groupe que personne n'a touché
 * depuis le déploiement n'a encore donné de portée à aucun de ses membres, et
 * ceux-ci ne voient plus les livres de leur famille. Ce backfill parcourt
 * `users/` et écrit la portée de chaque compte.
 *
 * Il lit tous les groupes une fois, au début du passage, et calcule la portée
 * attendue de chaque compte par `reachFromGroups`, la fonction du
 * déclencheur. Un compte dont la portée stockée est déjà juste est sauté. Un
 * compte à écrire passe par `syncReachFor`, qui relit ses groupes dans une
 * transaction : un groupe modifié pendant le passage ne laisse pas une portée
 * périmée.
 *
 * Aucun appel de modèle, donc aucun secret. Réentrant : relancer ne réécrit
 * rien. Borné par le délai, par un nombre de comptes par appel et par trois
 * échecs de suite ; reprend au curseur.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import {
  COLL_GROUP_REACH,
  COLL_GROUPS,
  COLL_USERS,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { logError, logInfo } from "../logging";
import {
  GroupData,
  membersOf,
  reachFromGroups,
  sameReach,
  syncReachFor,
} from "../triggers/groupReach";
import { getBackfillCursor, parseBoolean, setBackfillCursor } from "./_backfillCursor";
import { requireAdmin } from "./_auth";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

/** Où l'on retient le dernier compte examiné, et le compte rendu du passage. */
export const GROUP_REACH_CHECKPOINT_DOC_ID = "group_reach_backfill_checkpoint";

const FEATURE = "group_reach_backfill";

const DEFAULT_MAX_USERS = 2000;
const PAGE_SIZE = 300;
/** Marge gardée sur le délai de la fonction, pour écrire le curseur avant la fin. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois comptes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillGroupReachRequest {
  maxMinutes?: number;
  maxDocs?: number;
  resumeFromCheckpoint?: boolean;
  resetCheckpoint?: boolean;
}

export interface BackfillGroupReachResponse {
  /** Groupes lus au début du passage. */
  groupes: number;
  examines: number;
  /** Portée écrite (document créé ou liste changée). */
  ecrits: number;
  /** Portée déjà juste : rien d'écrit. */
  dejaAJour: number;
  echoues: number;
  /** Comptes après le curseur, encore à examiner ; `null` si le comptage a échoué. */
  restants: number | null;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
}

/**
 * Les groupes de chaque compte, indexés par membre. Pure et exportée pour
 * être testée : le backfill la construit une fois pour tout le passage.
 */
export function groupsByMember(groups: Iterable<GroupData>): Map<string, GroupData[]> {
  const index = new Map<string, GroupData[]>();
  for (const group of groups) {
    for (const member of membersOf(group)) {
      const list = index.get(member);
      if (list) list.push(group);
      else index.set(member, [group]);
    }
  }
  return index;
}

export const backfillGroupReachFn = onCall<BackfillGroupReachRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    memory: "256MiB",
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<BackfillGroupReachResponse> => {
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
      docId: GROUP_REACH_CHECKPOINT_DOC_ID,
      resumeFromCheckpoint: parseBoolean(req.data?.resumeFromCheckpoint, true),
      resetCheckpoint: parseBoolean(req.data?.resetCheckpoint, false),
    });

    // Tous les groupes, une fois : une famille en compte quelques-uns.
    const groupsSnap = await db.collection(COLL_GROUPS).get();
    const index = groupsByMember(groupsSnap.docs.map((d) => d.data()));

    const response: BackfillGroupReachResponse = {
      groupes: groupsSnap.size,
      examines: 0,
      ecrits: 0,
      dejaAJour: 0,
      echoues: 0,
      restants: null,
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

      // La portée stockée de toute la page, en une lecture groupée.
      const reachRefs = page.docs.map((d) => db.collection(COLL_GROUP_REACH).doc(d.id));
      const storedSnaps = await db.getAll(...reachRefs);
      const stored = new Map(storedSnaps.map((s) => [s.id, s.exists ? s.data() : undefined]));

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
          const expected = reachFromGroups(doc.id, index.get(doc.id) ?? []);
          if (sameReach(stored.get(doc.id), expected)) {
            response.dejaAJour += 1;
          } else {
            const outcome = await syncReachFor(doc.id);
            if (outcome === "unchanged") response.dejaAJour += 1;
            else response.ecrits += 1;
          }
          consecutiveFailures = 0;
        } catch (e) {
          response.echoues += 1;
          consecutiveFailures += 1;
          await logError({
            message: "Portée des groupes — échec sur un compte",
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

    if (response.completed) {
      response.restants = 0;
    } else {
      try {
        let rest = db.collection(COLL_USERS).orderBy("__name__");
        if (cursor) rest = rest.startAfter(cursor);
        const count = await rest.count().get();
        response.restants = count.data().count;
      } catch (e) {
        // Le passage a eu lieu ; seul le décompte manque, et il s'affiche « ? ».
        await logError({
          message: "Portée des groupes — décompte des comptes restants impossible",
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: e instanceof Error ? e.message : String(e),
          extra: { cursor },
        });
      }
    }

    await setBackfillCursor({
      db,
      docId: GROUP_REACH_CHECKPOINT_DOC_ID,
      lastDocId: response.completed ? null : cursor,
      operation: FEATURE,
      adminUid: ctx.userId,
      lastReport: { ...response },
    });

    await logInfo({
      message: "Portée des groupes — reprise",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      extra: { ...response, maxMinutes, maxDocs },
    });

    return response;
  },
);
