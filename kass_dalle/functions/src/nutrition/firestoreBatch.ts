import { getFirestore } from "firebase-admin/firestore";
import type { DocumentData, DocumentSnapshot } from "firebase-admin/firestore";

/**
 * Lectures groupées et écritures en lot pour les passes d'enrichissement.
 *
 * L'enrichissement lisait et écrivait document par document dans des boucles
 * `for`, en séquentiel : pour une recette de vingt ingrédients, vingt
 * aller-retours par étape, et il y a plusieurs étapes. La latence s'additionne
 * dans une Cloud Function facturée à la seconde.
 */

/** Firestore limite `getAll` à 300 documents par appel. */
const GET_ALL_CHUNK = 300;

/**
 * Lit d'un coup tous les documents demandés d'une collection.
 *
 * Rend une Map indexée par identifiant, ne contenant que les documents
 * existants — l'appelant n'a pas à filtrer sur `exists`.
 */
export async function readDocsByIds(
  collection: string,
  ids: readonly string[],
): Promise<Map<string, DocumentData>> {
  const out = new Map<string, DocumentData>();
  const unique = [...new Set(ids.filter((id) => id.trim().length > 0))];
  if (unique.length === 0) return out;

  const db = getFirestore();
  const col = db.collection(collection);

  for (let i = 0; i < unique.length; i += GET_ALL_CHUNK) {
    const chunk = unique.slice(i, i + GET_ALL_CHUNK);
    const refs = chunk.map((id) => col.doc(id));
    const snaps: DocumentSnapshot[] = await db.getAll(...refs);
    for (const snap of snaps) {
      const data = snap.data();
      if (snap.exists && data) out.set(snap.id, data);
    }
  }
  return out;
}

/**
 * Écrit un lot de documents en fusion.
 *
 * `BulkWriter` parallélise et régule lui-même le débit ; il remplace une boucle
 * de `await ...set()` sans imposer la limite de 500 opérations d'un `WriteBatch`.
 */
export async function writeDocsMerged(
  collection: string,
  updates: ReadonlyMap<string, DocumentData>,
): Promise<number> {
  if (updates.size === 0) return 0;

  const db = getFirestore();
  const col = db.collection(collection);
  const writer = db.bulkWriter();

  for (const [id, data] of updates) {
    void writer.set(col.doc(id), data, { merge: true });
  }
  await writer.close();
  return updates.size;
}
