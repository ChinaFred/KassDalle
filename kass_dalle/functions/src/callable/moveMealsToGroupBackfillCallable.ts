/**
 * Déplacer mes repas vers un groupe — fait passer les repas du planning
 * personnel de l'appelant, sur une période, dans le planning d'un groupe
 * familial dont il est le propriétaire. Sans appel de modèle.
 *
 * Un déplacement, pas une copie : chaque repas choisi reçoit
 * `group_id: <groupe>` et quitte « Mon planning ». Rien d'autre ne change :
 * ni `uid` (le cuisinier reste l'appelant, qui est aussi le propriétaire du
 * groupe, comme pour un repas planifié directement dans le groupe), ni les
 * parts (`base_portions`, `target_portions`), ni la recette, ni la date. Rien
 * n'est écrit dans une recette (règle « Redimensionner ne modifie jamais
 * l'originale »).
 *
 * Les règles Firestore figent `group_id` côté client : un repas ne change pas
 * de planning par l'application. Ce backfill l'écrit par l'Admin SDK, réservé
 * à l'administrateur, et seulement vers un groupe dont il est propriétaire.
 *
 * Entrée : `{ groupId, fromDay, toDay, startAt, endAt }`. `fromDay` et
 * `toDay` sont les jours choisis (`AAAA-MM-JJ`, inclusifs), `startAt` et
 * `endAt` les instants (millisecondes) du début du premier jour et du début
 * du lendemain du dernier, calculés par l'appareil dans son fuseau. Le
 * serveur ne devine pas le fuseau de l'utilisateur : il sélectionne
 * `startAt <= planned_at < endAt`, et vérifie que les instants tombent à
 * moins de quatorze heures des jours annoncés (les fuseaux vont de UTC−12 à
 * UTC+14).
 *
 * Sélection : `uid == appelant` et `planned_at` dans la période (index
 * composite `uid` + `planned_at`), puis, en mémoire, les repas dont
 * `group_id` est nul ou absent — un repas antérieur au backfill « Portée des
 * groupes et des plannings » n'a pas le champ, et une égalité à `null` ne le
 * trouverait pas. Un repas déjà dans un groupe est compté « ignoré ».
 *
 * Réentrant : un repas déplacé porte un `group_id`, il n'est plus
 * sélectionné. Chaque écriture porte la précondition `lastUpdateTime` de la
 * lecture : un repas modifié ou supprimé entre-temps n'est pas déplacé, il
 * part dans la liste à revoir. Borné par le délai, par un nombre de repas
 * déplacés et lus par appel, et par trois échecs de suite.
 *
 * Classé `ponctuel`, mais jamais marqué terminé tout seul : chaque passage
 * vaut pour une période et un groupe, et le reste des autres périodes n'est
 * pas compté (`remaining: null` dans `summarizeMoveMealsToGroup`).
 */

import { HttpsError, onCall } from "firebase-functions/v2/https";
import { Timestamp, getFirestore } from "firebase-admin/firestore";

import { COLL_GROUPS, COLL_PLANNED_MEALS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { ownerOf, type GroupData } from "../triggers/groupMembers";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import { BackfillReview, shortErrorMessage, withoutReviewList } from "./_backfillReview";
import type { BackfillReviewList } from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "move_meals_to_group_backfill";

/** Période la plus longue acceptée, en jours inclusifs. */
export const MAX_PERIOD_DAYS = 62;
/** Repas lus au plus par passage (personnels et de groupe confondus). */
export const MAX_MEAL_READS = 2000;
/** Repas déplacés au plus par passage. */
export const MAX_MEAL_MOVES = 500;
/** Trois échecs de suite : une panne, pas trois repas difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;
/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 45_000;

const DAY_MS = 86_400_000;
/** Écart toléré entre un jour annoncé (minuit UTC) et l'instant envoyé. */
const MAX_ZONE_OFFSET_MS = 14 * 3_600_000;

/** Un identifiant de document Firestore sans caractère piège. */
const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/;
const ISO_DAY = /^(\d{4})-(\d{2})-(\d{2})$/;

export interface MoveMealsRequest {
  groupId: string;
  fromDay: string;
  toDay: string;
  /** Début du premier jour, en millisecondes, inclus. */
  startAt: number;
  /** Début du lendemain du dernier jour, en millisecondes, exclu. */
  endAt: number;
}

/** Minuit UTC du jour `AAAA-MM-JJ`, ou `null` si ce n'est pas une vraie date. */
export function isoDayToUtcMs(day: unknown): number | null {
  if (typeof day !== "string") return null;
  const m = ISO_DAY.exec(day);
  if (!m) return null;
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const ms = Date.UTC(y, mo - 1, d);
  const back = new Date(ms);
  if (back.getUTCFullYear() !== y || back.getUTCMonth() !== mo - 1 || back.getUTCDate() !== d) {
    return null;
  }
  return ms;
}

function isMillis(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

/**
 * Lit et valide l'entrée. Rend la demande, ou le message d'erreur en
 * français. Pure, testée.
 */
export function parseMoveMealsRequest(
  data: unknown,
): { request: MoveMealsRequest } | { error: string } {
  const d = (data && typeof data === "object" ? data : {}) as Record<string, unknown>;
  const groupId = typeof d.groupId === "string" ? d.groupId.trim() : "";
  if (!SAFE_ID.test(groupId)) return { error: "Identifiant de groupe invalide." };
  const from = isoDayToUtcMs(d.fromDay);
  const to = isoDayToUtcMs(d.toDay);
  if (from == null || to == null) {
    return { error: "Les jours de début et de fin doivent être au format AAAA-MM-JJ." };
  }
  if (from > to) return { error: "Le jour de début est après le jour de fin." };
  const days = Math.round((to - from) / DAY_MS) + 1;
  if (days > MAX_PERIOD_DAYS) {
    return { error: `La période compte ${days} jours : ${MAX_PERIOD_DAYS} au plus.` };
  }
  if (!isMillis(d.startAt) || !isMillis(d.endAt) || d.startAt >= d.endAt) {
    return { error: "Les bornes de la période sont invalides." };
  }
  if (
    Math.abs(d.startAt - from) > MAX_ZONE_OFFSET_MS ||
    Math.abs(d.endAt - (to + DAY_MS)) > MAX_ZONE_OFFSET_MS
  ) {
    return { error: "Les bornes de la période ne correspondent pas aux jours choisis." };
  }
  return {
    request: {
      groupId,
      fromDay: d.fromDay as string,
      toDay: d.toDay as string,
      startAt: d.startAt,
      endAt: d.endAt,
    },
  };
}

/**
 * Le repas appartient-il au planning personnel ? `group_id` nul ou absent.
 * Pure, testée.
 */
export function isPersonalMeal(data: Record<string, unknown> | undefined): boolean {
  if (!data) return false;
  return !Object.prototype.hasOwnProperty.call(data, "group_id") || data.group_id === null;
}

/** Un repas lu : son identifiant, ses données, et ce qu'il faut pour l'écrire. */
export interface MealRow {
  id: string;
  data: Record<string, unknown>;
  /** Jeton opaque de la lecture (heure de mise à jour), pour la précondition. */
  version?: unknown;
}

/** Les accès Firestore du passage, remplacés par un faux dans les tests. */
export interface MoveMealsStore {
  readGroup(groupId: string): Promise<GroupData>;
  /** Repas `uid == [uid]` dont `planned_at` est dans `[startAt, endAt[`, triés par date. */
  listMeals(uid: string, startAt: number, endAt: number, limit: number): Promise<MealRow[]>;
  /** Pose `group_id` ; échoue si le repas a changé depuis la lecture. */
  moveMeal(row: MealRow, groupId: string): Promise<void>;
}

export interface BackfillMoveMealsToGroupResponse {
  /** Nom du groupe cible, lu dans son document. */
  groupe: string;
  du: string;
  au: string;
  /** Repas de l'appelant lus dans la période (personnels et de groupe). */
  examines: number;
  deplaces: number;
  /** Repas déjà dans un groupe : laissés tels quels. */
  ignores: number;
  echoues: number;
  /** Repas personnels de la période pas encore déplacés à l'arrêt. */
  restants: number;
  /** Plus de `MAX_MEAL_READS` repas dans la période : la lecture est tronquée. */
  lectureTronquee: boolean;
  stoppedByDeadline: boolean;
  stoppedByBudget: boolean;
  stoppedByErrors: boolean;
  completed: boolean;
  aRevoir: BackfillReviewList;
}

interface BackfillMoveMealsToGroupRequest {
  groupId?: unknown;
  fromDay?: unknown;
  toDay?: unknown;
  startAt?: unknown;
  endAt?: unknown;
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export const backfillMoveMealsToGroupFn = onCall<BackfillMoveMealsToGroupRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    // Administrateur non révoqué : il planifie, et ses groupes sont actifs
    // (un groupe n'est masqué que si son propriétaire ne planifie plus).
    const ctx = await requireAdmin(req, FEATURE);
    const parsed = parseMoveMealsRequest(req.data);
    if ("error" in parsed) throw new HttpsError("invalid-argument", parsed.error);
    const request = parsed.request;
    return runBackfillFromCallable({
      key: "move_meals_to_group",
      ctx,
      appVersion: req.data?.appVersion,
      summarize: summarizeMoveMealsToGroup,
      run: () =>
        runMoveMealsToGroupPass(ctx, request, firestoreStore(), {
          deadlineMs: Date.now() + 540_000 - DEADLINE_MARGIN_MS,
        }),
    });
  },
);

/**
 * Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`).
 * `remaining: null` : le reste des autres périodes n'est pas compté, et le
 * ponctuel n'est donc jamais marqué terminé tout seul (`shouldAutoMarkDone`).
 */
export function summarizeMoveMealsToGroup(r: BackfillMoveMealsToGroupResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: null,
    toReview: r.aRevoir.total,
    spendCapHit: false,
  };
}

function firestoreStore(): MoveMealsStore {
  const db = getFirestore();
  return {
    async readGroup(groupId) {
      const snap = await db.collection(COLL_GROUPS).doc(groupId).get();
      return snap.exists ? (snap.data() as Record<string, unknown>) : null;
    },
    async listMeals(uid, startAt, endAt, limit) {
      const snap = await db
        .collection(COLL_PLANNED_MEALS)
        .where("uid", "==", uid)
        .where("planned_at", ">=", Timestamp.fromMillis(startAt))
        .where("planned_at", "<", Timestamp.fromMillis(endAt))
        .orderBy("planned_at")
        .limit(limit)
        .get();
      return snap.docs.map((doc) => ({ id: doc.id, data: doc.data(), version: doc.updateTime }));
    },
    async moveMeal(row, groupId) {
      const ref = db.collection(COLL_PLANNED_MEALS).doc(row.id);
      if (row.version instanceof Timestamp) {
        await ref.update({ group_id: groupId }, { lastUpdateTime: row.version });
      } else {
        await ref.update({ group_id: groupId });
      }
    },
  };
}

/** « Blanquette — 2026-01-02 », pour la liste à revoir (Firestore seul, jamais les journaux). */
function mealLabel(row: MealRow): string {
  const title = typeof row.data.recipe_titre === "string" ? row.data.recipe_titre.trim() : "";
  const at = row.data.planned_at;
  const day = at instanceof Timestamp ? at.toDate().toISOString().slice(0, 10) : "";
  return [title || `Repas ${row.id}`, day].filter(Boolean).join(" — ");
}

/**
 * Un passage : vérifie que l'appelant possède le groupe, lit ses repas de la
 * période et déplace les personnels, un par un. Exportée pour les tests, avec
 * un faux [store] et un faux `logger`.
 */
export async function runMoveMealsToGroupPass(
  ctx: AuthContext,
  request: MoveMealsRequest,
  store: MoveMealsStore,
  options: {
    deadlineMs: number;
    now?: () => number;
    logger?: { error: typeof logError; info: typeof logInfo };
    maxMoves?: number;
    maxReads?: number;
  },
): Promise<BackfillMoveMealsToGroupResponse> {
  const now = options.now ?? Date.now;
  const logger = options.logger ?? { error: logError, info: logInfo };
  const maxMoves = options.maxMoves ?? MAX_MEAL_MOVES;
  const maxReads = options.maxReads ?? MAX_MEAL_READS;
  const review = new BackfillReview();

  const group = await store.readGroup(request.groupId);
  if (!group) throw new HttpsError("not-found", "Groupe introuvable.");
  if (ownerOf(group) !== ctx.userId) {
    throw new HttpsError(
      "permission-denied",
      "Vous n'êtes pas propriétaire de ce groupe : ses repas ne peuvent pas recevoir les vôtres.",
    );
  }
  const groupName = typeof group.name === "string" ? group.name.trim() : "";

  const rows = await store.listMeals(ctx.userId, request.startAt, request.endAt, maxReads);
  const personal = rows.filter((r) => isPersonalMeal(r.data));

  const response: BackfillMoveMealsToGroupResponse = {
    groupe: groupName,
    du: request.fromDay,
    au: request.toDay,
    examines: rows.length,
    deplaces: 0,
    ignores: rows.length - personal.length,
    echoues: 0,
    restants: 0,
    lectureTronquee: rows.length >= maxReads,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };

  let consecutiveFailures = 0;
  let handled = 0;
  for (const row of personal) {
    if (now() > options.deadlineMs) {
      response.stoppedByDeadline = true;
      break;
    }
    if (response.deplaces >= maxMoves) {
      response.stoppedByBudget = true;
      break;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      break;
    }
    handled += 1;
    try {
      await store.moveMeal(row, request.groupId);
      response.deplaces += 1;
      consecutiveFailures = 0;
    } catch (e) {
      response.echoues += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "meal",
        id: row.id,
        label: mealLabel(row),
        reason: `Repas non déplacé (modifié ou supprimé pendant le passage ?) : ${shortErrorMessage(e)}`,
      });
      await logger.error({
        message: "Déplacer mes repas vers un groupe — échec sur un repas",
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { mealId: row.id, groupId: request.groupId, consecutiveFailures },
      });
    }
  }
  response.restants = personal.length - handled;
  response.completed =
    response.restants === 0 && response.echoues === 0 && !response.lectureTronquee;
  response.aRevoir = review.toJSON();

  // Le nom du groupe reste dans le compte rendu (Firestore) : les journaux
  // reçoivent son identifiant.
  const { groupe: _groupe, ...forLog } = response;
  await logger.info({
    message: "Déplacer mes repas vers un groupe — passage",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(forLog), groupId: request.groupId },
  });
  return response;
}
