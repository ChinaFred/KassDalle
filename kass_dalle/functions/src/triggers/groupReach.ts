/**
 * Portée des groupes : `group_reach/{uid}`, la liste des autres comptes avec
 * qui `uid` partage au moins un groupe familial actif.
 *
 * Les règles Firestore cloisonnent la lecture des livres et des recettes par
 * groupe : un document non privé d'un autre compte ne se lit que si ce compte
 * partage un groupe avec le lecteur. Une règle ne peut pas parcourir `groups`
 * pour le vérifier ; elle lit cette liste toute faite.
 *
 * Forme du document : `{ uids: string[], updated_at: Timestamp }`. `uids` ne
 * contient jamais `uid` lui-même, est trié et sans doublon. Un compte sorti
 * de tous ses groupes garde son document, avec `uids: []`.
 *
 * Membre d'un groupe = présent dans `member_ids` ou égal à `owner_id`.
 *
 * Groupe actif = son propriétaire planifie (éditeur ou administrateur, non
 * révoqué, voir `isPlannerAccount`). Un groupe dont le propriétaire est
 * rétrogradé lecteur ne relie plus personne : ses membres cessent de lire les
 * livres que le groupe leur ouvrait, sans que rien ne soit effacé, et les
 * relisent s'il redevient éditeur. La portée est retirée ici plutôt que
 * vérifiée par les règles : `group_reach` ne dit pas quel groupe relie deux
 * comptes, et vérifier le propriétaire à la lecture coûterait une lecture de
 * plus par livre et par recette, à chaque requête.
 *
 * Écrit par le déclencheur `syncGroupReach` (toute écriture sur
 * `groups/{groupId}`) et par `syncPlanningReachOnRole` (changement de rôle
 * du propriétaire, `plannerRole.ts`). `syncGroupReach` recalcule aussi, pour
 * les mêmes comptes, la portée des plannings (`planning_reach`, voir
 * `planningReach.ts`), supprime les repas planifiés et les suggestions de
 * repas d'un groupe supprimé, et les suggestions d'un membre qui en sort.
 * Les règles en interdisent l'écriture au client : un compte qui pourrait
 * s'ajouter la portée d'un autre lirait ses livres.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` est déjà chargé par toutes les
 * fonctions du bundle.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { FieldValue, getFirestore, type DocumentSnapshot } from "firebase-admin/firestore";

import { COLL_GROUP_REACH, COLL_GROUPS, COLL_USERS, REGION } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import {
  deleteGroupMeals,
  deleteGroupSuggestions,
  deleteMemberSuggestions,
  departedMembers,
} from "./groupMeals";
import { isPlannerAccount, membersOf, ownerOf, sameReach, type GroupData } from "./groupMembers";
import { invitationsToResync, syncPlanningReachFor } from "./planningReach";

// `membersOf`, `sameReach` et `GroupData` vivent dans `groupMembers.ts`, sans
// dépendance : `planningReach.ts` les importe sans repasser par ce fichier.
// Réexportés ici pour les appelants existants.
export { membersOf, sameReach, type GroupData } from "./groupMembers";

/**
 * La portée de [uid] : les autres membres des groupes actifs dont il est
 * membre. Un groupe dont il n'est pas membre est ignoré, ce qui permet de
 * passer tous les groupes de la base ; un groupe dont le propriétaire n'est
 * pas dans [plannerOwners] est masqué. Triée, sans doublon, sans [uid].
 */
export function reachFromGroups(
  uid: string,
  groups: Iterable<GroupData>,
  plannerOwners: ReadonlySet<string>,
): string[] {
  const reach = new Set<string>();
  for (const group of groups) {
    const owner = ownerOf(group);
    if (!owner || !plannerOwners.has(owner)) continue;
    const members = membersOf(group);
    if (!members.includes(uid)) continue;
    for (const member of members) {
      if (member !== uid) reach.add(member);
    }
  }
  return [...reach].sort();
}

/**
 * Les comptes dont la portée peut changer après l'écriture d'un groupe :
 * l'union des membres avant et après. Vide si la composition n'a pas changé
 * (renommage, autre champ) : aucune portée ne bouge.
 */
export function accountsToResync(before: GroupData, after: GroupData): string[] {
  const membersBefore = membersOf(before);
  const membersAfter = membersOf(after);
  if (
    membersBefore.length === membersAfter.length &&
    membersBefore.every((id, i) => id === membersAfter[i])
  ) {
    return [];
  }
  return [...new Set([...membersBefore, ...membersAfter])].sort();
}

/** Ce que `syncGroupReach` a fait pour un compte. */
export type ReachSyncOutcome = "created" | "updated" | "unchanged";

/**
 * Recalcule et écrit `group_reach/{uid}` en relisant les groupes de [uid] et
 * le compte de leurs propriétaires.
 *
 * Deux requêtes (`member_ids array-contains uid`, `owner_id == uid`), la
 * lecture du document de portée, puis celle des propriétaires, dans une
 * transaction : une écriture concurrente sur un des documents lus fait
 * rejouer le calcul, au lieu de laisser une portée périmée. N'écrit rien si
 * la liste n'a pas changé.
 *
 * Les erreurs remontent à l'appelant, qui les journalise.
 */
export async function syncReachFor(uid: string): Promise<ReachSyncOutcome> {
  const db = getFirestore();
  const groups = db.collection(COLL_GROUPS);
  const reachRef = db.collection(COLL_GROUP_REACH).doc(uid);

  return db.runTransaction(async (tx) => {
    const [asMember, asOwner, stored] = await Promise.all([
      tx.get(groups.where("member_ids", "array-contains", uid)),
      tx.get(groups.where("owner_id", "==", uid)),
      tx.get(reachRef),
    ]);
    const data = [...asMember.docs.map((d) => d.data()), ...asOwner.docs.map((d) => d.data())];
    const ownerIds = [...new Set(data.map(ownerOf).filter((o): o is string => o != null))].sort();
    const plannerOwners = new Set<string>();
    if (ownerIds.length > 0) {
      const snaps: DocumentSnapshot[] = await tx.getAll(
        ...ownerIds.map((id) => db.collection(COLL_USERS).doc(id)),
      );
      ownerIds.forEach((id, i) => {
        if (isPlannerAccount(snaps[i]?.data())) plannerOwners.add(id);
      });
    }
    const expected = reachFromGroups(uid, data, plannerOwners);
    if (stored.exists && sameReach(stored.data(), expected)) return "unchanged";
    tx.set(reachRef, { uids: expected, updated_at: FieldValue.serverTimestamp() });
    return stored.exists ? "updated" : "created";
  });
}

export const syncGroupReach = onDocumentWritten(
  // `retry` : une portée non recalculée laisse un membre sorti lire encore
  // les livres du groupe, et un repas ou une suggestion d'un groupe supprimé
  // resterait en base. L'événement est rejoué tant qu'un compte ou une
  // suppression échoue ; `syncReachFor` et les suppressions sont idempotents.
  { document: "groups/{groupId}", region: REGION, retry: true },
  async (event) => {
    const groupId = event.params.groupId;
    const before = event.data?.before?.exists
      ? (event.data.before.data() as Record<string, unknown> | undefined)
      : undefined;
    const after = event.data?.after?.exists
      ? (event.data.after.data() as Record<string, unknown> | undefined)
      : undefined;

    const correlationId = newCorrelationId("portee_groupes");
    let failures = 0;

    // Groupe supprimé : son planning part avec lui. Les repas planifiés du
    // groupe n'appartiennent à aucun autre planning, et plus personne ne
    // pourrait les lire ni les supprimer.
    if (before && !after) {
      try {
        const deleted = await deleteGroupMeals(groupId);
        if (deleted > 0) {
          await logInfo({
            message: `syncGroupReach: groupe ${groupId} supprimé, ${deleted} repas planifié(s) supprimé(s)`,
            correlationId,
            extra: { groupId, deleted },
          });
        }
      } catch (err) {
        failures += 1;
        await logError({
          message: `syncGroupReach: repas planifiés du groupe supprimé ${groupId} non supprimés`,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { groupId },
        });
      }
    }

    // Groupe supprimé : les suggestions de ses membres partent aussi. Plus
    // personne ne les lirait comme suggestions d'un groupe existant.
    if (before && !after) {
      try {
        const deleted = await deleteGroupSuggestions(groupId);
        if (deleted > 0) {
          await logInfo({
            message: `syncGroupReach: groupe ${groupId} supprimé, ${deleted} suggestion(s) supprimée(s)`,
            correlationId,
            extra: { groupId, deleted },
          });
        }
      } catch (err) {
        failures += 1;
        await logError({
          message: `syncGroupReach: suggestions du groupe supprimé ${groupId} non supprimées`,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { groupId },
        });
      }
    }

    // Membre sorti (départ ou retrait par le propriétaire) : ses suggestions
    // au groupe partent avec lui. Compte par compte : l'échec de l'un
    // n'empêche pas les autres.
    for (const uid of departedMembers(before, after)) {
      try {
        const deleted = await deleteMemberSuggestions(groupId, uid);
        if (deleted > 0) {
          await logInfo({
            message: `syncGroupReach: ${uid} a quitté le groupe ${groupId}, ${deleted} suggestion(s) supprimée(s)`,
            correlationId,
            userId: uid,
            extra: { groupId, deleted },
          });
        }
      } catch (err) {
        failures += 1;
        await logError({
          message: `syncGroupReach: suggestions de ${uid} au groupe ${groupId} non supprimées`,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: uid,
          extra: { groupId },
        });
      }
    }

    const accounts = accountsToResync(before, after);
    const changed: string[] = [];

    // Compte par compte : l'échec de l'un n'empêche pas les autres.
    for (const uid of accounts) {
      try {
        const outcome = await syncReachFor(uid);
        if (outcome !== "unchanged") changed.push(uid);
      } catch (err) {
        failures += 1;
        await logError({
          message: `syncGroupReach: portée non recalculée pour ${uid}`,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: uid,
          extra: { groupId },
        });
      }
      // Séparée de la portée des groupes : l'une peut échouer sans l'autre.
      try {
        const outcome = await syncPlanningReachFor(uid);
        if (outcome !== "unchanged") changed.push(`planning:${uid}`);
      } catch (err) {
        failures += 1;
        await logError({
          message: `syncGroupReach: portée des plannings non recalculée pour ${uid}`,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: uid,
          extra: { groupId },
        });
      }
    }

    // Les invités dont l'invitation change : seule leur portée des plannings
    // bouge (`masked_invitation_ids`, invitations vers un groupe en pause).
    const accountSet = new Set(accounts);
    for (const uid of invitationsToResync(before, after)) {
      if (accountSet.has(uid)) continue;
      try {
        const outcome = await syncPlanningReachFor(uid);
        if (outcome !== "unchanged") changed.push(`planning:${uid}`);
      } catch (err) {
        failures += 1;
        await logError({
          message: `syncGroupReach: portée des plannings non recalculée pour l'invité ${uid}`,
          correlationId,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: uid,
          extra: { groupId },
        });
      }
    }

    if (changed.length > 0 || failures > 0) {
      await logInfo({
        message: `syncGroupReach: groupe ${groupId}, ${changed.length} portée(s) réécrite(s), ${failures} échec(s)`,
        correlationId,
        extra: { groupId, accounts, changed, failures },
      });
    }
    if (failures > 0) {
      throw new Error(`syncGroupReach: ${failures} échec(s) pour le groupe ${groupId}`);
    }
  },
);

/**
 * Recalcule la portée des groupes de chaque compte de [accounts], un par un :
 * l'échec de l'un n'empêche pas les autres, et chacun est journalisé. Rend le
 * nombre d'échecs.
 */
export async function resyncGroupReach(
  accounts: string[],
  context: { correlationId: string; reason: string; owner?: string },
): Promise<number> {
  const changed: string[] = [];
  let failures = 0;
  for (const uid of accounts) {
    try {
      const outcome = await syncReachFor(uid);
      if (outcome !== "unchanged") changed.push(uid);
    } catch (err) {
      failures += 1;
      await logError({
        message: `groupReach: portée des groupes non recalculée pour ${uid} (${context.reason})`,
        correlationId: context.correlationId,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
        extra: { reason: context.reason, owner: context.owner ?? null },
      });
    }
  }
  if (changed.length > 0 || failures > 0) {
    await logInfo({
      message: `groupReach: ${context.reason}, ${changed.length} portée(s) réécrite(s), ${failures} échec(s)`,
      correlationId: context.correlationId,
      extra: { reason: context.reason, owner: context.owner ?? null, accounts, changed, failures },
    });
  }
  return failures;
}
