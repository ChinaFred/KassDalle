/**
 * Écriture de la mémoire des échecs (`failureMemory.ts`) sur les documents
 * d'un passage : un compteur et une date par élément en échec, un compteur
 * remis à zéro par élément réussi.
 *
 * Best-effort : la mémoire sert à ne pas redemander indéfiniment, elle ne
 * conditionne pas le résultat du passage. Une écriture qui échoue est
 * journalisée (`logError`) et le passage continue ; l'élément sera simplement
 * redemandé au passage suivant, comme avant la mémoire.
 */

import { FieldValue } from "firebase-admin/firestore";

import { logError } from "../logging";
import { writeDocsMerged } from "../nutrition/firestoreBatch";

/** Noms des deux champs d'un traitement. */
export interface FailureFields {
  /** Compteur d'échecs (`ai_weight_failure_count`, …). */
  count: string;
  /** Date du dernier essai sans succès (`ai_weight_attempt_at`, …). */
  at: string;
}

/** Échecs et réussites à écrire, par identifiant de document. */
export interface FailureMemoryBatch {
  /** Identifiant → compteur à écrire (déjà incrémenté). */
  failures: ReadonlyMap<string, number>;
  /** Identifiants dont le compteur repart de zéro. */
  successes: Iterable<string>;
}

/** Écrit la mémoire d'un lot. Ne lève jamais. */
export async function writeFailureMemory(args: {
  collection: string;
  fields: FailureFields;
  batch: FailureMemoryBatch;
  correlationId: string;
  operation: string;
  userId?: string | null;
}): Promise<void> {
  const updates = new Map<string, Record<string, unknown>>();
  for (const [id, count] of args.batch.failures) {
    updates.set(id, {
      [args.fields.count]: count,
      [args.fields.at]: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });
  }
  for (const id of args.batch.successes) {
    if (updates.has(id)) continue;
    updates.set(id, { [args.fields.count]: 0 });
  }
  if (updates.size === 0) return;
  try {
    await writeDocsMerged(args.collection, updates);
  } catch (err) {
    await logError({
      message: `${args.operation}: mémoire des échecs non écrite`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.correlationId,
      userId: args.userId ?? undefined,
      moduleType: "DESIGN",
      extra: { collection: args.collection, ids: [...updates.keys()].slice(0, 50) },
    });
  }
}
