/**
 * Portée des plannings : `planning_reach/{uid}`, la liste des comptes dont
 * `uid` peut lire le planning (`planned_meals`), en lecture seule.
 *
 * Un compte partage son planning avec des groupes familiaux qu'il coche dans
 * « Préférences du planning » (`planning_config/{owner}.shared_group_ids`).
 * Les règles Firestore ne peuvent ni parcourir `groups`, ni croiser ces
 * groupes avec le rôle du propriétaire : elles lisent cette liste toute
 * faite.
 *
 * `owner` figure dans `planning_reach/{viewer}.uids` quand :
 *   - `owner` est éditeur ou administrateur, et n'est pas révoqué — un
 *     propriétaire lecteur, en attente ou révoqué ne partage rien ; ses
 *     `shared_group_ids` restent en base, ignorés, et le partage reprend
 *     s'il redevient éditeur ;
 *   - un groupe de `shared_group_ids` existe encore, et `owner` et `viewer` en
 *     sont tous deux MEMBRES (`owner_id` ou `member_ids`, jamais
 *     `invited_ids`, voir `membersOf`).
 * Le partage n'est pas réciproque, et `uids` ne contient jamais `viewer`.
 *
 * Forme : `{ uids: string[], updated_at: Timestamp }`, `uids` trié, sans
 * doublon. Écrit par le serveur seul (les règles l'interdisent au client :
 * un compte qui s'ajouterait la portée d'un autre lirait ses repas).
 *
 * Trois événements recalculent les portées touchées :
 *   - l'écriture d'un groupe dont la composition change — `syncGroupReach`,
 *     qui recalcule déjà `group_reach` pour les mêmes comptes ;
 *   - un changement de `shared_group_ids` — `syncPlanningReachOnConfig`,
 *     ci-dessous ;
 *   - un changement de rôle ou de révocation d'un compte — `syncUserClaims`
 *     appelle `resyncPlanningAudienceOf`.
 *
 * Aucun backfill : sans `shared_group_ids`, rien n'est partagé, et sans
 * `planning_reach`, rien ne se lit.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` est déjà chargé par toutes les
 * fonctions du bundle.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import {
  FieldValue,
  getFirestore,
  type DocumentReference,
  type DocumentSnapshot,
} from "firebase-admin/firestore";

import {
  COLL_GROUPS,
  COLL_PLANNING_CONFIG,
  COLL_PLANNING_REACH,
  COLL_USERS,
  REGION,
} from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { membersOf, sameReach, type GroupData } from "./groupReach";

/** Plafond de `shared_group_ids`, le même que celui des règles Firestore. */
export const MAX_SHARED_GROUPS = 50;

/** Les rôles qui planifient, et donc partagent. */
const PLANNER_ROLES = ["editor", "admin"];

/**
 * Le compte peut-il partager son planning ? Éditeur ou administrateur, non
 * révoqué. Un document absent ou mal formé ne partage rien.
 */
export function canSharePlanning(user: Record<string, unknown> | undefined | null): boolean {
  if (!user) return false;
  const role = typeof user.role === "string" ? user.role.trim() : "";
  return PLANNER_ROLES.includes(role) && user.is_revoked !== true;
}

/**
 * Les groupes cochés dans `planning_config/{uid}` : chaînes non vides,
 * utilisables comme identifiant de document, sans doublon, au plus
 * [MAX_SHARED_GROUPS]. Une valeur mal formée est ignorée, jamais une
 * exception.
 */
export function sharedGroupIdsOf(config: Record<string, unknown> | undefined | null): string[] {
  const raw = config?.shared_group_ids;
  if (!Array.isArray(raw)) return [];
  const ids: string[] = [];
  for (const value of raw) {
    if (typeof value !== "string") continue;
    const id = value.trim();
    if (!id || id.includes("/") || id.length > 128 || ids.includes(id)) continue;
    ids.push(id);
    if (ids.length >= MAX_SHARED_GROUPS) break;
  }
  return ids;
}

/** Un groupe lu, avec son identifiant. */
export interface GroupEntry {
  id: string;
  data: GroupData;
}

/** Ce qu'il faut savoir d'un propriétaire possible. */
export interface OwnerState {
  /** `planning_config/{owner}`, ou rien. */
  config: Record<string, unknown> | undefined | null;
  /** `users/{owner}`, ou rien. */
  user: Record<string, unknown> | undefined | null;
}

/**
 * La portée de [viewer] : les propriétaires dont il peut lire le planning.
 *
 * [groups] : les groupes dont [viewer] est membre (un groupe dont il n'est
 * pas membre est ignoré). [owners] : l'état de chaque autre membre de ces
 * groupes ; un membre sans état ne partage rien. Triée, sans doublon, sans
 * [viewer].
 */
export function planningReachFrom(
  viewer: string,
  groups: Iterable<GroupEntry>,
  owners: ReadonlyMap<string, OwnerState>,
): string[] {
  const reach = new Set<string>();
  for (const group of groups) {
    const members = membersOf(group.data);
    if (!members.includes(viewer)) continue;
    for (const owner of members) {
      if (owner === viewer || reach.has(owner)) continue;
      const state = owners.get(owner);
      if (!state || !canSharePlanning(state.user)) continue;
      if (sharedGroupIdsOf(state.config).includes(group.id)) reach.add(owner);
    }
  }
  return [...reach].sort();
}

/**
 * Les groupes dont `shared_group_ids` a changé : ceux ajoutés ou retirés.
 * Vide si la liste n'a pas changé (autre champ des préférences) : aucune
 * portée ne bouge.
 */
export function changedSharedGroups(
  before: Record<string, unknown> | undefined | null,
  after: Record<string, unknown> | undefined | null,
): string[] {
  const idsBefore = new Set(sharedGroupIdsOf(before));
  const idsAfter = new Set(sharedGroupIdsOf(after));
  const changed = new Set<string>();
  for (const id of idsBefore) if (!idsAfter.has(id)) changed.add(id);
  for (const id of idsAfter) if (!idsBefore.has(id)) changed.add(id);
  return [...changed].sort();
}

/** Ce que `syncPlanningReachFor` a fait pour un compte. */
export type PlanningReachOutcome = "created" | "updated" | "unchanged";

/**
 * Recalcule et écrit `planning_reach/{viewer}`.
 *
 * Dans une transaction : les groupes de [viewer] (deux requêtes), puis les
 * préférences et le document de chaque autre membre. Une écriture
 * concurrente sur l'un d'eux fait rejouer le calcul. N'écrit rien si la
 * liste n'a pas changé. Les erreurs remontent à l'appelant, qui les
 * journalise.
 */
export async function syncPlanningReachFor(viewer: string): Promise<PlanningReachOutcome> {
  const db = getFirestore();
  const groups = db.collection(COLL_GROUPS);
  const reachRef = db.collection(COLL_PLANNING_REACH).doc(viewer);

  return db.runTransaction(async (tx) => {
    const [asMember, asOwner, stored] = await Promise.all([
      tx.get(groups.where("member_ids", "array-contains", viewer)),
      tx.get(groups.where("owner_id", "==", viewer)),
      tx.get(reachRef),
    ]);
    const entries = new Map<string, GroupEntry>();
    for (const doc of [...asMember.docs, ...asOwner.docs]) {
      entries.set(doc.id, { id: doc.id, data: doc.data() });
    }
    const candidates = new Set<string>();
    for (const entry of entries.values()) {
      const members = membersOf(entry.data);
      if (!members.includes(viewer)) continue;
      for (const member of members) if (member !== viewer) candidates.add(member);
    }

    const owners = new Map<string, OwnerState>();
    const ids = [...candidates].sort();
    if (ids.length > 0) {
      const refs: DocumentReference[] = [];
      for (const id of ids) {
        refs.push(db.collection(COLL_PLANNING_CONFIG).doc(id));
        refs.push(db.collection(COLL_USERS).doc(id));
      }
      const snaps: DocumentSnapshot[] = await tx.getAll(...refs);
      ids.forEach((id, i) => {
        owners.set(id, {
          config: snaps[2 * i]?.data(),
          user: snaps[2 * i + 1]?.data(),
        });
      });
    }

    const expected = planningReachFrom(viewer, entries.values(), owners);
    if (stored.exists && sameReach(stored.data(), expected)) return "unchanged";
    tx.set(reachRef, { uids: expected, updated_at: FieldValue.serverTimestamp() });
    return stored.exists ? "updated" : "created";
  });
}

/**
 * Les comptes qui voient — ou voyaient — le planning de [owner] par
 * [groupIds] : les membres de ces groupes, hors [owner]. Un groupe disparu
 * n'apporte personne : ceux qui en étaient membres ont déjà été recalculés
 * à sa suppression.
 */
export async function audienceOf(owner: string, groupIds: string[]): Promise<string[]> {
  if (groupIds.length === 0) return [];
  const db = getFirestore();
  const snaps = await db.getAll(...groupIds.map((id) => db.collection(COLL_GROUPS).doc(id)));
  const audience = new Set<string>();
  for (const snap of snaps) {
    if (!snap.exists) continue;
    for (const member of membersOf(snap.data())) if (member !== owner) audience.add(member);
  }
  return [...audience].sort();
}

/**
 * Recalcule la portée de chaque compte de [viewers], un par un : l'échec de
 * l'un n'empêche pas les autres, et chacun est journalisé. Rend le nombre
 * d'échecs.
 */
export async function resyncPlanningReach(
  viewers: string[],
  context: { correlationId: string; reason: string; owner?: string },
): Promise<number> {
  const changed: string[] = [];
  let failures = 0;
  for (const viewer of viewers) {
    try {
      const outcome = await syncPlanningReachFor(viewer);
      if (outcome !== "unchanged") changed.push(viewer);
    } catch (err) {
      failures += 1;
      await logError({
        message: `planningReach: portée des plannings non recalculée pour ${viewer} (${context.reason})`,
        correlationId: context.correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: viewer,
        extra: { reason: context.reason, owner: context.owner ?? null },
      });
    }
  }
  if (changed.length > 0 || failures > 0) {
    await logInfo({
      message: `planningReach: ${context.reason}, ${changed.length} portée(s) réécrite(s), ${failures} échec(s)`,
      correlationId: context.correlationId,
      extra: { reason: context.reason, owner: context.owner ?? null, viewers, changed, failures },
    });
  }
  return failures;
}

/**
 * Le rôle ou la révocation de [owner] a changé : son planning se partage, ou
 * cesse de l'être. Relit ses groupes cochés et recalcule la portée de leurs
 * membres. Ne lève jamais : appelé par `syncUserClaims`, qui n'est pas
 * rejoué ; chaque échec est journalisé.
 */
export async function resyncPlanningAudienceOf(owner: string): Promise<void> {
  const correlationId = newCorrelationId("portee_plannings");
  try {
    const config = await getFirestore().collection(COLL_PLANNING_CONFIG).doc(owner).get();
    const viewers = await audienceOf(owner, sharedGroupIdsOf(config.data()));
    await resyncPlanningReach(viewers, { correlationId, reason: "rôle du propriétaire", owner });
  } catch (err) {
    await logError({
      message: `planningReach: audience du planning de ${owner} illisible après un changement de rôle`,
      correlationId,
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: owner,
    });
  }
}

export const syncPlanningReachOnConfig = onDocumentWritten(
  // `retry` : une portée non recalculée laisse un membre lire un planning qui
  // ne lui est plus partagé. `syncPlanningReachFor` est idempotent.
  { document: "planning_config/{uid}", region: REGION, retry: true },
  async (event) => {
    const owner = event.params.uid;
    const before = event.data?.before?.exists
      ? (event.data.before.data() as Record<string, unknown> | undefined)
      : undefined;
    const after = event.data?.after?.exists
      ? (event.data.after.data() as Record<string, unknown> | undefined)
      : undefined;

    const groupIds = changedSharedGroups(before, after);
    if (groupIds.length === 0) return;

    const correlationId = newCorrelationId("portee_plannings");
    let viewers: string[];
    try {
      viewers = await audienceOf(owner, groupIds);
    } catch (err) {
      await logError({
        message: `syncPlanningReachOnConfig: groupes illisibles pour ${owner}`,
        correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: owner,
        extra: { groupIds },
      });
      throw err;
    }
    const failures = await resyncPlanningReach(viewers, {
      correlationId,
      reason: "groupes partagés modifiés",
      owner,
    });
    if (failures > 0) {
      throw new Error(
        `syncPlanningReachOnConfig: ${failures} portée(s) non recalculée(s) pour ${owner}`,
      );
    }
  },
);
