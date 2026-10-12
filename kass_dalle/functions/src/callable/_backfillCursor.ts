/**
 * Point de reprise d'un backfill, et lecture de ses arguments.
 *
 * Un backfill ne tient pas dans le délai d'une fonction : il travaille par
 * tranches, et doit savoir où il s'est arrêté. Ces trois fonctions vivaient
 * dans `billingCallable.ts`, seul endroit qui en avait besoin. Le rattrapage
 * de nutrition a le même besoin, à l'identique — et un point de reprise
 * recopié, c'est deux conventions de stockage qui finiront par diverger sur
 * la forme du curseur.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_APP_CONFIG } from "../config";

/** Chaîne utilisable, ou `null`. Une chaîne vide n'est pas un identifiant. */
export function asNonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const out = value.trim();
  return out.length > 0 ? out : null;
}

/**
 * Booléen d'un argument d'appel, tolérant aux formes que le client envoie.
 *
 * Une case cochée traverse parfois la couche HTTPS en `"true"` : la lire comme
 * un booléen strict rendrait `false`, et le backfill repartirait de zéro sans
 * qu'aucune erreur ne le dise.
 */
export function parseBoolean(value: unknown, defaultValue: boolean): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") {
    const normalized = value.trim().toLowerCase();
    if (["true", "1", "yes", "y"].includes(normalized)) return true;
    if (["false", "0", "no", "n"].includes(normalized)) return false;
  }
  return defaultValue;
}

/** Où reprendre, ou `null` pour repartir du début. */
export async function getBackfillCursor(args: {
  db: FirebaseFirestore.Firestore;
  docId: string;
  resumeFromCheckpoint: boolean;
  resetCheckpoint: boolean;
}): Promise<string | null> {
  if (!args.resumeFromCheckpoint || args.resetCheckpoint) {
    return null;
  }

  const snap = await args.db.collection(COLL_APP_CONFIG).doc(args.docId).get();
  if (!snap.exists) return null;
  const data = snap.data() as Record<string, unknown>;
  return asNonEmptyString(data.last_doc_id);
}

/**
 * Retient où l'on s'est arrêté. `null` remet le curseur au début.
 *
 * Le compte rendu du passage ne s'écrit plus ici : il part dans l'état du
 * backfill, `app_config/backfill_run_<clé>` (`backfills/runner.ts`), que
 * l'écran lit en continu.
 */
export async function setBackfillCursor(args: {
  db?: FirebaseFirestore.Firestore;
  docId: string;
  lastDocId: string | null;
  operation: string;
  adminUid?: string;
}): Promise<void> {
  const db = args.db ?? getFirestore();
  await db
    .collection(COLL_APP_CONFIG)
    .doc(args.docId)
    .set(
      {
        operation: args.operation,
        last_doc_id: args.lastDocId,
        updated_at: FieldValue.serverTimestamp(),
        updated_by: args.adminUid ?? null,
      },
      { merge: true },
    );
}
