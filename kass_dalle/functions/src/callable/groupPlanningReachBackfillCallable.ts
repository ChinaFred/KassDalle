/**
 * Portée des groupes et des plannings — recalcule `group_reach/{uid}` et
 * `planning_reach/{uid}` pour chaque membre d'un groupe familial, sans appel
 * de modèle.
 *
 * Le planning de groupe ajoute à `planning_reach` les listes
 * `group_ids` (groupes actifs dont le compte est membre, lues par les règles
 * de `planned_meals`) et `masked_group_ids` (groupes masqués par un
 * propriétaire rétrogradé, lues par l'écran des groupes). Il retire aussi de
 * `group_reach` les groupes dont le propriétaire ne planifie plus. Les
 * déclencheurs tiennent ces documents à jour dès qu'un groupe, un rôle ou un
 * partage change ; un groupe que personne n'a touché depuis le déploiement
 * n'a encore donné de `group_ids` à aucun de ses membres, et ceux-ci ne
 * lisent pas son planning.
 *
 * Il lit tous les groupes une fois, au début du passage, et recalcule les
 * deux portées de chacun de leurs membres par `syncReachFor` et
 * `syncPlanningReachFor`, les fonctions des déclencheurs. Un document déjà
 * juste n'est pas réécrit.
 *
 * Réentrant : relancer ne réécrit rien. Borné par le délai, par un nombre de
 * comptes réécrits par appel et par trois échecs de suite.
 */

import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_GROUPS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { membersOf, type GroupData } from "../triggers/groupMembers";
import { syncReachFor } from "../triggers/groupReach";
import { syncPlanningReachFor } from "../triggers/planningReach";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import { BackfillReview, shortErrorMessage, withoutReviewList } from "./_backfillReview";
import type { BackfillReviewList } from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "group_planning_reach_backfill";

/** Comptes dont au moins une portée a été réécrite, par appel. */
const MAX_DOCS = 500;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;
/** Trois échecs de suite : une panne, pas trois comptes difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

/**
 * Les comptes à recalculer : les membres de tous les groupes, triés, sans
 * doublon. Pure, testée.
 */
export function groupAccounts(groups: Iterable<GroupData>): string[] {
  const accounts = new Set<string>();
  for (const group of groups) for (const member of membersOf(group)) accounts.add(member);
  return [...accounts].sort();
}

export interface BackfillGroupPlanningReachResponse {
  /** Groupes lus au début du passage. */
  groupes: number;
  examines: number;
  /** Comptes dont au moins une portée a été écrite. */
  ecrits: number;
  /** Comptes dont les deux portées étaient déjà justes. */
  dejaAJour: number;
  echoues: number;
  /** Comptes pas encore examinés à l'arrêt du passage. */
  restants: number;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  /** Comptes en échec, nommés, avec la raison. */
  aRevoir: BackfillReviewList;
}

interface BackfillGroupPlanningReachRequest {
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export const backfillGroupPlanningReachFn = onCall<BackfillGroupPlanningReachRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);
    return runBackfillFromCallable({
      key: "group_planning_reach",
      ctx,
      appVersion: req.data?.appVersion,
      summarize: summarizeGroupPlanningReach,
      run: () => runGroupPlanningReachPass(ctx),
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeGroupPlanningReach(r: BackfillGroupPlanningReachResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restants,
    toReview: r.aRevoir.total,
    spendCapHit: false,
  };
}

/** Un passage sur tous les membres de groupes, borné par le délai d'une fonction. */
async function runGroupPlanningReachPass(
  ctx: AuthContext,
): Promise<BackfillGroupPlanningReachResponse> {
  const db = getFirestore();
  const deadline = Date.now() + 540_000 - DEADLINE_MARGIN_MS;
  const review = new BackfillReview();

  // Tous les groupes, une fois : une famille en compte quelques-uns.
  const groups = await db.collection(COLL_GROUPS).get();
  const accounts = groupAccounts(groups.docs.map((d) => d.data()));
  const response: BackfillGroupPlanningReachResponse = {
    groupes: groups.size,
    examines: 0,
    ecrits: 0,
    dejaAJour: 0,
    echoues: 0,
    restants: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };

  let consecutiveFailures = 0;
  for (const uid of accounts) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    if (response.ecrits >= MAX_DOCS) {
      response.stoppedByBudget = true;
      break;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      break;
    }
    response.examines += 1;
    try {
      // Les deux, même si la première échoue : l'une peut manquer sans l'autre.
      const [books, plannings] = await Promise.allSettled([
        syncReachFor(uid),
        syncPlanningReachFor(uid),
      ]);
      const failed = [books, plannings].find((r) => r.status === "rejected");
      if (failed) throw (failed as PromiseRejectedResult).reason;
      const outcomes = [books, plannings].map((r) => (r as PromiseFulfilledResult<string>).value);
      if (outcomes.every((o) => o === "unchanged")) response.dejaAJour += 1;
      else response.ecrits += 1;
      consecutiveFailures = 0;
    } catch (e) {
      response.echoues += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "account",
        id: uid,
        label: uid,
        reason: `Portée non recalculée : ${shortErrorMessage(e)}`,
      });
      await logError("Portée des groupes et des plannings — échec sur un compte", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { accountUid: uid, consecutiveFailures },
      });
    }
  }
  response.restants = accounts.length - response.examines;
  response.completed = response.restants === 0 && response.echoues === 0;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "Portée des groupes et des plannings — passage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response) },
  });

  return response;
}
