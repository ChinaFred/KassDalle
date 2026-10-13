/**
 * Ce qui appartient au planning d'un groupe familial : ses repas planifiés
 * (`planned_meals` dont `group_id` vaut l'identifiant du groupe) et les
 * suggestions de repas de ses membres (`meal_suggestions`).
 *
 * Un groupe supprimé emporte son planning et ses suggestions :
 * `syncGroupReach` appelle `deleteGroupMeals` et `deleteGroupSuggestions`
 * quand le document du groupe disparaît. Un membre qui quitte le groupe, ou
 * que le propriétaire en retire, emporte ses suggestions :
 * `deleteMemberSuggestions`.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` seul.
 */

import { getFirestore, type DocumentReference, type Query } from "firebase-admin/firestore";

import { COLL_MEAL_SUGGESTIONS, COLL_PLANNED_MEALS } from "../config";
import { membersOf, type GroupData } from "./groupMembers";

/** Documents supprimés par lot : sous la limite de 500 écritures d'un lot Firestore. */
export const DELETE_BATCH_SIZE = 400;

/** Lots au plus par appel : un planning de groupe ne compte pas 40 000 documents. */
export const MAX_BATCHES = 100;

/**
 * Supprime, page par page, ce que rend [fetchPage] : chaque page est passée
 * à [deletePage], jusqu'à une page vide ou incomplète. Rend le nombre de
 * documents supprimés.
 *
 * Séparée de Firestore pour être testée. Au-delà de [MAX_BATCHES] pages, elle
 * lève : un reste inattendu se signale plutôt que de tourner jusqu'au délai
 * de la fonction. Les erreurs remontent à l'appelant.
 */
export async function deleteInPages<T>(
  fetchPage: () => Promise<T[]>,
  deletePage: (page: T[]) => Promise<void>,
  label: string,
): Promise<number> {
  let deleted = 0;
  for (let i = 0; i < MAX_BATCHES; i++) {
    const page = await fetchPage();
    if (page.length === 0) return deleted;
    await deletePage(page);
    deleted += page.length;
    if (page.length < DELETE_BATCH_SIZE) return deleted;
  }
  throw new Error(
    `${label}: plus de ${MAX_BATCHES * DELETE_BATCH_SIZE} documents, suppression incomplète`,
  );
}

/** Supprime tous les documents de [query], par lots. Idempotent. */
async function deleteQuery(query: Query, label: string): Promise<number> {
  const db = getFirestore();
  const page = query.select().limit(DELETE_BATCH_SIZE);
  return deleteInPages<DocumentReference>(
    async () => (await page.get()).docs.map((d) => d.ref),
    async (refs) => {
      const batch = db.batch();
      for (const ref of refs) batch.delete(ref);
      await batch.commit();
    },
    label,
  );
}

/**
 * Supprime tous les repas planifiés du groupe [groupId], par lots. Rend le
 * nombre de repas supprimés.
 *
 * Idempotent : rejoué après un échec partiel, il supprime ce qui reste. Les
 * erreurs remontent à l'appelant, qui les journalise et fait rejouer
 * l'événement.
 */
export async function deleteGroupMeals(groupId: string): Promise<number> {
  return deleteQuery(
    getFirestore().collection(COLL_PLANNED_MEALS).where("group_id", "==", groupId),
    `deleteGroupMeals(${groupId})`,
  );
}

/**
 * Supprime toutes les suggestions de repas du groupe [groupId]. Rend leur
 * nombre. Idempotent ; les erreurs remontent à l'appelant.
 */
export async function deleteGroupSuggestions(groupId: string): Promise<number> {
  return deleteQuery(
    getFirestore().collection(COLL_MEAL_SUGGESTIONS).where("group_id", "==", groupId),
    `deleteGroupSuggestions(${groupId})`,
  );
}

/**
 * Supprime les suggestions de repas que [authorUid] a faites au groupe
 * [groupId]. Rend leur nombre. Idempotent ; les erreurs remontent à
 * l'appelant.
 *
 * Deux égalités : Firestore les sert sans index composite.
 */
export async function deleteMemberSuggestions(groupId: string, authorUid: string): Promise<number> {
  return deleteQuery(
    getFirestore()
      .collection(COLL_MEAL_SUGGESTIONS)
      .where("group_id", "==", groupId)
      .where("author_uid", "==", authorUid),
    `deleteMemberSuggestions(${groupId}, ${authorUid})`,
  );
}

/**
 * Les membres sortis du groupe entre [before] et [after] : présents avant,
 * absents après. Triés. Vide à la création et à la suppression du groupe —
 * la suppression emporte toutes les suggestions d'un coup
 * ([deleteGroupSuggestions]). Un invité qui refuse n'était pas membre : il
 * n'y figure pas.
 */
export function departedMembers(before: GroupData, after: GroupData): string[] {
  if (!before || !after) return [];
  const remaining = new Set(membersOf(after));
  return membersOf(before).filter((uid) => !remaining.has(uid));
}
