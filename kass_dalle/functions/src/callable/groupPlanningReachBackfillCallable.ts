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
 * Deuxième phase, les repas : un repas personnel porte désormais
 * `group_id: null` explicite. Les plannings personnels partagés se lisent par
 * `uid == propriétaire` ET `group_id == null` — la règle ne laisse plus lire
 * par le partage personnel les repas des groupes du propriétaire —, et une
 * égalité à `null` ne trouve pas un document sans le champ. Le passage
 * parcourt `planned_meals` par identifiant, depuis un point de reprise, et
 * pose `group_id: null` sur chaque repas qui n'a pas le champ. Une seule
 * opération à lancer après le déploiement, plutôt que deux : les deux phases
 * préparent le même changement de lecture.
 *
 * Réentrant : relancer ne réécrit rien. Borné par le délai, par un nombre de
 * comptes réécrits et de repas marqués par appel, et par trois échecs de
 * suite dans chaque phase.
 */

import { onCall } from "firebase-functions/v2/https";
import { FieldPath, getFirestore } from "firebase-admin/firestore";

import { COLL_GROUPS, COLL_PLANNED_MEALS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { membersOf, type GroupData } from "../triggers/groupMembers";
import { syncReachFor } from "../triggers/groupReach";
import { syncPlanningReachFor } from "../triggers/planningReach";
import { invitedOfOwnedGroups } from "../triggers/plannerRole";
import { requireAdmin, type AuthContext } from "./_auth";
import { getBackfillCursor, setBackfillCursor } from "./_backfillCursor";
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
/** Repas lus par page, et marqués par lot d'écriture (sous la limite de 500). */
const MEAL_PAGE_SIZE = 400;
/** Repas marqués `group_id: null` par appel, au plus. */
const MAX_MEAL_WRITES = 4000;
/** Point de reprise du parcours des repas, dans `app_config`. */
export const GROUP_PLANNING_REACH_CHECKPOINT_DOC_ID = "group_planning_reach_backfill_checkpoint";

/**
 * Le repas lu (projection `group_id`) doit-il recevoir `group_id: null` ?
 * Oui s'il n'a pas le champ ; un `group_id` présent, nul ou non, est gardé.
 * Pure, testée.
 */
export function needsGroupIdField(data: Record<string, unknown> | undefined): boolean {
  return !data || !Object.prototype.hasOwnProperty.call(data, "group_id");
}

/**
 * Les comptes à recalculer : les membres et les invités de tous les groupes
 * (un invité reçoit `masked_invitation_ids`), triés, sans doublon. Pure,
 * testée.
 */
export function groupAccounts(groups: Iterable<GroupData>): string[] {
  const accounts = new Set<string>();
  for (const group of groups) {
    for (const member of membersOf(group)) accounts.add(member);
    for (const invited of invitedOfOwnedGroups([group])) accounts.add(invited);
  }
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
  /** Repas lus dans ce passage. */
  repasExamines: number;
  /** Repas qui ont reçu `group_id: null`. */
  repasMarques: number;
  repasEchoues: number;
  /** Repas après le point de reprise ; `null` si le décompte a échoué. */
  repasRestants: number | null;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  /** Comptes et repas en échec, nommés, avec la raison. */
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
    remaining: r.repasRestants == null ? null : r.restants + r.repasRestants,
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
    repasExamines: 0,
    repasMarques: 0,
    repasEchoues: 0,
    repasRestants: null,
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

  // Phase 2 : les repas, seulement si la première n'a pas été arrêtée.
  if (!response.stoppedByDeadline && !response.stoppedByErrors && !response.stoppedByBudget) {
    await markPersonalMeals(ctx, deadline, response, review);
  }

  response.completed =
    response.restants === 0 &&
    response.echoues === 0 &&
    response.repasRestants === 0 &&
    response.repasEchoues === 0;
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

/**
 * Pose `group_id: null` sur les repas qui n'ont pas le champ, page par page
 * depuis le point de reprise. Un lot en échec est repris repas par repas :
 * un repas supprimé entre la lecture et l'écriture ne fait pas tomber les
 * autres. Chaque échec est journalisé et nommé dans la liste à revoir.
 */
async function markPersonalMeals(
  ctx: AuthContext,
  deadline: number,
  response: BackfillGroupPlanningReachResponse,
  review: BackfillReview,
): Promise<void> {
  const db = getFirestore();
  const meals = db.collection(COLL_PLANNED_MEALS);
  let cursor = await getBackfillCursor({
    db,
    docId: GROUP_PLANNING_REACH_CHECKPOINT_DOC_ID,
    resumeFromCheckpoint: true,
    resetCheckpoint: false,
  });
  let finished = false;
  let consecutiveFailures = 0;

  pages: for (;;) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    if (response.repasMarques >= MAX_MEAL_WRITES) {
      response.stoppedByBudget = true;
      break;
    }
    let query = meals.orderBy(FieldPath.documentId()).select("group_id").limit(MEAL_PAGE_SIZE);
    if (cursor) query = query.startAfter(cursor);
    const page = await query.get();
    if (page.empty) {
      finished = true;
      break;
    }
    response.repasExamines += page.size;
    const toMark = page.docs.filter((d) => needsGroupIdField(d.data()));
    if (toMark.length > 0) {
      try {
        const batch = db.batch();
        for (const doc of toMark) batch.update(doc.ref, { group_id: null });
        await batch.commit();
        response.repasMarques += toMark.length;
        consecutiveFailures = 0;
      } catch (batchError) {
        await logError({
          message: "Portée des groupes et des plannings — lot de repas en échec, reprise un par un",
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          moduleType: "DESIGN",
          feature: FEATURE,
          errorDescription: batchError instanceof Error ? batchError.message : String(batchError),
          extra: { firstMealId: toMark[0]?.id ?? null, size: toMark.length },
        });
        for (const doc of toMark) {
          try {
            await doc.ref.update({ group_id: null });
            response.repasMarques += 1;
            consecutiveFailures = 0;
          } catch (e) {
            response.repasEchoues += 1;
            consecutiveFailures += 1;
            review.add({
              kind: "meal",
              id: doc.id,
              label: `Repas ${doc.id}`,
              reason: `group_id non posé : ${shortErrorMessage(e)}`,
            });
            await logError({
              message: "Portée des groupes et des plannings — échec sur un repas",
              correlationId: ctx.correlationId,
              userId: ctx.userId,
              moduleType: "DESIGN",
              feature: FEATURE,
              errorDescription: e instanceof Error ? e.message : String(e),
              extra: { mealId: doc.id, consecutiveFailures },
            });
            if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
              response.stoppedByErrors = true;
              break pages;
            }
          }
        }
      }
    }
    cursor = page.docs[page.docs.length - 1].id;
    if (page.size < MEAL_PAGE_SIZE) {
      finished = true;
      break;
    }
  }

  // Le curseur revient au début quand la collection est parcourue en entier :
  // une relance repasse tout, et ne réécrit que ce qui manque encore.
  await setBackfillCursor({
    db,
    docId: GROUP_PLANNING_REACH_CHECKPOINT_DOC_ID,
    lastDocId: finished ? null : cursor,
    operation: FEATURE,
    adminUid: ctx.userId,
  });

  if (finished) {
    response.repasRestants = 0;
    return;
  }
  try {
    let rest = meals.orderBy(FieldPath.documentId());
    if (cursor) rest = rest.startAfter(cursor);
    response.repasRestants = (await rest.count().get()).data().count;
  } catch (e) {
    // Le passage a eu lieu ; seul le décompte manque, et il s'affiche « ? ».
    await logError({
      message: "Portée des groupes et des plannings — décompte des repas restants impossible",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      feature: FEATURE,
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { cursor },
    });
  }
}
