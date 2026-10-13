/**
 * Changement de rôle ou de révocation d'un compte : ce qu'il rend lisible, ou
 * ne rend plus lisible, à ses groupes.
 *
 * Un compte qui cesse de planifier (éditeur rétrogradé lecteur, mis en
 * attente, révoqué) :
 *  - ne partage plus son planning personnel (`planning_reach.uids` des
 *    membres de ses `shared_group_ids`) ;
 *  - masque tous les groupes dont il est propriétaire : leurs membres, lui
 *    compris, perdent le planning du groupe (`planning_reach.group_ids`) et
 *    les livres que le groupe leur ouvrait (`group_reach`). Rien n'est
 *    effacé ; tout revient s'il redevient éditeur.
 *
 * Déclencheur `syncPlanningReachOnRole`, sur `users/{uid}`. Il vivait dans
 * `planningReach.ts` ; il recalcule désormais aussi `group_reach`, que
 * `groupReach.ts` tient, et ce fichier les importe tous deux sans qu'ils
 * s'importent l'un l'autre. Le nom de la fonction déployée ne change pas.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` seul.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_GROUPS, COLL_PLANNING_CONFIG, REGION } from "../config";
import { logError, newCorrelationId } from "../logging";
import { resyncGroupReach } from "./groupReach";
import { membersOf } from "./groupMembers";
import {
  audienceOf,
  planningShareChanged,
  resyncPlanningReach,
  sharedGroupIdsOf,
} from "./planningReach";

/**
 * Les membres des groupes dont [owner] est propriétaire, [owner] compris, et
 * leurs invités. Triés, sans doublon ; `members` vaut `[owner]` seul s'il
 * n'en possède aucun.
 */
export async function ownedGroupsAudience(
  owner: string,
): Promise<{ members: string[]; invited: string[] }> {
  const snap = await getFirestore().collection(COLL_GROUPS).where("owner_id", "==", owner).get();
  const groups = snap.docs.map((d) => d.data());
  return {
    members: membersOfOwnedGroups(owner, groups),
    invited: invitedOfOwnedGroups(groups),
  };
}

/** Pure : les invités de [groups]. Triés, sans doublon. */
export function invitedOfOwnedGroups(
  groups: Iterable<Record<string, unknown> | undefined | null>,
): string[] {
  const invited = new Set<string>();
  for (const group of groups) {
    const raw = group?.invited_ids;
    if (!Array.isArray(raw)) continue;
    for (const id of raw) {
      if (typeof id === "string" && id && !id.includes("/")) invited.add(id);
    }
  }
  return [...invited].sort();
}

/** Pure : [owner] et les membres de [groups]. Triés, sans doublon. */
export function membersOfOwnedGroups(
  owner: string,
  groups: Iterable<Record<string, unknown> | undefined | null>,
): string[] {
  const members = new Set<string>([owner]);
  for (const group of groups) for (const member of membersOf(group)) members.add(member);
  return [...members].sort();
}

export const syncPlanningReachOnRole = onDocumentWritten(
  // Déclencheur dédié, `retry: true` : un éditeur rétrogradé ou révoqué dont
  // les portées ne sont pas recalculées resterait lisible par ses groupes, et
  // son groupe resterait ouvert. Il lève à l'échec pour que l'événement soit
  // rejoué ; les recalculs sont idempotents.
  { document: "users/{uid}", region: REGION, retry: true },
  async (event) => {
    const owner = event.params.uid;
    const before = event.data?.before?.exists
      ? (event.data.before.data() as Record<string, unknown> | undefined)
      : undefined;
    const after = event.data?.after?.exists
      ? (event.data.after.data() as Record<string, unknown> | undefined)
      : undefined;
    if (!planningShareChanged(before, after)) return;

    const correlationId = newCorrelationId("portee_plannings");
    let sharedAudience: string[];
    let groupMembers: string[];
    let groupInvited: string[];
    try {
      const config = await getFirestore().collection(COLL_PLANNING_CONFIG).doc(owner).get();
      const [audience, owned] = await Promise.all([
        audienceOf(owner, sharedGroupIdsOf(config.data())),
        ownedGroupsAudience(owner),
      ]);
      sharedAudience = audience;
      groupMembers = owned.members;
      groupInvited = owned.invited;
    } catch (err) {
      await logError({
        message: `syncPlanningReachOnRole: audience du planning et des groupes de ${owner} illisible`,
        correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: owner,
      });
      throw err;
    }
    // Les invités aussi : leur invitation vers un groupe en pause se masque.
    const viewers = [...new Set([...sharedAudience, ...groupMembers, ...groupInvited])].sort();
    const planningFailures = await resyncPlanningReach(viewers, {
      correlationId,
      reason: "rôle du propriétaire",
      owner,
    });
    // Les livres ouverts par les groupes de ce compte : seuls leurs membres
    // voient leur portée changer.
    const groupFailures =
      groupMembers.length > 1
        ? await resyncGroupReach(groupMembers, {
            correlationId,
            reason: "rôle du propriétaire du groupe",
            owner,
          })
        : 0;
    const failures = planningFailures + groupFailures;
    if (failures > 0) {
      throw new Error(
        `syncPlanningReachOnRole: ${failures} portée(s) non recalculée(s) pour ${owner}`,
      );
    }
  },
);
