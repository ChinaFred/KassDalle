/**
 * Repas planifiés d'un groupe familial (`planned_meals` dont `group_id` vaut
 * l'identifiant du groupe).
 *
 * Un groupe supprimé emporte son planning : `syncGroupReach` appelle
 * `deleteGroupMeals` quand le document du groupe disparaît. Les suggestions
 * de repas d'un groupe (`meal_suggestions`, à venir) s'ajouteront ici.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` seul.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_PLANNED_MEALS } from "../config";

/** Repas supprimés par lot : sous la limite de 500 écritures d'un lot Firestore. */
const DELETE_BATCH_SIZE = 400;

/** Lots au plus par appel : un planning de groupe ne compte pas 40 000 repas. */
const MAX_BATCHES = 100;

/**
 * Supprime tous les repas planifiés du groupe [groupId], par lots. Rend le
 * nombre de repas supprimés.
 *
 * Idempotent : rejoué après un échec partiel, il supprime ce qui reste. Les
 * erreurs remontent à l'appelant, qui les journalise et fait rejouer
 * l'événement. Au-delà de [MAX_BATCHES] lots, il lève : un reste inattendu
 * se signale plutôt que de tourner jusqu'au délai de la fonction.
 */
export async function deleteGroupMeals(groupId: string): Promise<number> {
  const db = getFirestore();
  const query = db
    .collection(COLL_PLANNED_MEALS)
    .where("group_id", "==", groupId)
    .select()
    .limit(DELETE_BATCH_SIZE);
  let deleted = 0;
  for (let i = 0; i < MAX_BATCHES; i++) {
    const page = await query.get();
    if (page.empty) return deleted;
    const batch = db.batch();
    for (const doc of page.docs) batch.delete(doc.ref);
    await batch.commit();
    deleted += page.size;
    if (page.size < DELETE_BATCH_SIZE) return deleted;
  }
  throw new Error(
    `deleteGroupMeals: plus de ${MAX_BATCHES * DELETE_BATCH_SIZE} repas pour le groupe ${groupId}, suppression incomplète`,
  );
}
