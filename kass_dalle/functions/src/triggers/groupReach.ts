/**
 * Portée des groupes : `group_reach/{uid}`, la liste des autres comptes avec
 * qui `uid` partage au moins un groupe familial.
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
 * Écrit par le déclencheur `syncGroupReach` (toute écriture sur
 * `groups/{groupId}`). Le même déclencheur recalcule, pour les mêmes
 * comptes, la portée des plannings (`planning_reach`, voir
 * `planningReach.ts`) : être membre d'un groupe ouvre aussi la lecture des
 * plannings que ses membres partagent avec lui. Le backfill « Portée des groupes », qui l'a écrit pour
 * les groupes antérieurs à la v0.23.19, est retiré depuis la v0.23.23. Les règles en interdisent l'écriture
 * au client : un compte qui pourrait s'ajouter la portée d'un autre lirait
 * ses livres.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` est déjà chargé par toutes les
 * fonctions du bundle.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { COLL_GROUP_REACH, COLL_GROUPS, REGION } from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { membersOf, sameReach, type GroupData } from "./groupMembers";
import { syncPlanningReachFor } from "./planningReach";

// `membersOf`, `sameReach` et `GroupData` vivent dans `groupMembers.ts`, sans
// dépendance : `planningReach.ts` les importe sans repasser par ce fichier.
// Réexportés ici pour les appelants existants.
export { membersOf, sameReach, type GroupData } from "./groupMembers";

/**
 * La portée de [uid] : les autres membres des groupes dont il est membre.
 * Un groupe dont il n'est pas membre est ignoré, ce qui permet de passer
 * tous les groupes de la base. Triée, sans doublon, sans [uid].
 */
export function reachFromGroups(uid: string, groups: Iterable<GroupData>): string[] {
  const reach = new Set<string>();
  for (const group of groups) {
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
 * Recalcule et écrit `group_reach/{uid}` en relisant les groupes de [uid].
 *
 * Deux requêtes (`member_ids array-contains uid`, `owner_id == uid`) et la
 * lecture du document de portée, dans une transaction : une écriture
 * concurrente sur un des groupes lus fait rejouer le calcul, au lieu de
 * laisser une portée périmée. N'écrit rien si la liste n'a pas changé.
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
    const expected = reachFromGroups(uid, [
      ...asMember.docs.map((d) => d.data()),
      ...asOwner.docs.map((d) => d.data()),
    ]);
    if (stored.exists && sameReach(stored.data(), expected)) return "unchanged";
    tx.set(reachRef, { uids: expected, updated_at: FieldValue.serverTimestamp() });
    return stored.exists ? "updated" : "created";
  });
}

export const syncGroupReach = onDocumentWritten(
  // `retry` : une portée non recalculée laisse un membre sorti lire encore
  // les livres du groupe. L'événement est rejoué tant qu'un compte échoue ;
  // `syncReachFor` est idempotent, un compte déjà juste n'est pas réécrit.
  { document: "groups/{groupId}", region: REGION, retry: true },
  async (event) => {
    const groupId = event.params.groupId;
    const before = event.data?.before?.exists
      ? (event.data.before.data() as Record<string, unknown> | undefined)
      : undefined;
    const after = event.data?.after?.exists
      ? (event.data.after.data() as Record<string, unknown> | undefined)
      : undefined;

    const accounts = accountsToResync(before, after);
    if (accounts.length === 0) return;

    const correlationId = newCorrelationId("portee_groupes");
    const changed: string[] = [];
    let failures = 0;

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

    if (changed.length > 0 || failures > 0) {
      await logInfo({
        message: `syncGroupReach: groupe ${groupId}, ${changed.length} portée(s) réécrite(s), ${failures} échec(s)`,
        correlationId,
        extra: { groupId, accounts, changed, failures },
      });
    }
    if (failures > 0) {
      throw new Error(`syncGroupReach: ${failures} portée(s) non recalculée(s) pour ${groupId}`);
    }
  },
);
