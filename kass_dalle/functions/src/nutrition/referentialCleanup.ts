/**
 * Nettoyage du référentiel d'ingrédients.
 *
 * Les identifiants de `nutrition_ingredients` sont dérivés du nom par
 * `normalizeIngredientStrictId`. Quand cette règle a changé — la correction des
 * ligatures, où « œuf » produisait « uf » —, les documents créés sous l'ancienne
 * règle sont devenus inatteignables : plus personne ne calcule leur identifiant,
 * et leurs valeurs nutritionnelles sont perdues pour l'application.
 *
 * Cet audit recalcule l'identifiant attendu de chaque document et propose de
 * fusionner les orphelins vers leur cible.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { logError, logInfo } from "../logging";
import { normalizeIngredientStrictId } from "./ingredientName";

const COLL = "nutrition_ingredients";

export interface MisnormalizedIngredient {
  /** Identifiant actuel du document, devenu inatteignable. */
  currentId: string;
  /** Identifiant que la règle en vigueur produirait. */
  expectedId: string;
  /** Nom d'où l'identifiant attendu est dérivé. */
  sourceName: string;
  /** Le document cible existe-t-il déjà ? */
  targetExists: boolean;
  /** Le document orphelin porte-t-il des valeurs nutritionnelles ? */
  hasPer100g: boolean;
}

export interface IngredientCleanupResult {
  scanned: number;
  misnormalized: MisnormalizedIngredient[];
  merged: number;
  renamed: number;
  deleted: number;
  applied: boolean;
}

/** Nom de référence d'un document, du plus fiable au plus approximatif. */
function sourceNameOf(id: string, data: Record<string, unknown>): string {
  const canonical = typeof data.canonical_name === "string" ? data.canonical_name.trim() : "";
  if (canonical) return canonical;
  const aliases = Array.isArray(data.aliases)
    ? data.aliases.filter((v): v is string => typeof v === "string" && v.trim().length > 0)
    : [];
  if (aliases.length > 0) return aliases[0].trim();
  return id.replace(/_/g, " ");
}

function hasValues(data: Record<string, unknown>): boolean {
  const per100g = data.per100g;
  return !!per100g && typeof per100g === "object" && Object.keys(per100g).length > 0;
}

/**
 * Audite — et si [apply] est vrai, répare — les identifiants du référentiel.
 *
 * Réparation :
 *  - la cible n'existe pas → le document est recréé sous le bon identifiant
 *    (aucune donnée perdue), l'ancien est supprimé ;
 *  - la cible existe → les alias sont fusionnés, et les valeurs nutritionnelles
 *    de l'orphelin ne sont reprises que si la cible n'en a pas. On ne remplace
 *    jamais des valeurs existantes : la cible est la référence vivante.
 */
export async function cleanupIngredientReferential(args: {
  apply: boolean;
}): Promise<IngredientCleanupResult> {
  const db = getFirestore();
  const snap = await db.collection(COLL).get();

  const misnormalized: MisnormalizedIngredient[] = [];
  for (const doc of snap.docs) {
    const data = doc.data() as Record<string, unknown>;
    const sourceName = sourceNameOf(doc.id, data);
    const expectedId = normalizeIngredientStrictId(sourceName);
    if (!expectedId || expectedId === doc.id) continue;

    const targetSnap = await db.collection(COLL).doc(expectedId).get();
    misnormalized.push({
      currentId: doc.id,
      expectedId,
      sourceName,
      targetExists: targetSnap.exists,
      hasPer100g: hasValues(data),
    });
  }

  const result: IngredientCleanupResult = {
    scanned: snap.size,
    misnormalized,
    merged: 0,
    renamed: 0,
    deleted: 0,
    applied: args.apply,
  };

  if (!args.apply) {
    await logInfo({
      message: `cleanupIngredientReferential: audit — ${misnormalized.length} identifiant(s) à corriger sur ${snap.size}`,
      extra: { ids: misnormalized.map((m) => `${m.currentId} → ${m.expectedId}`) },
    });
    return result;
  }

  for (const item of misnormalized) {
    try {
      const sourceRef = db.collection(COLL).doc(item.currentId);
      const targetRef = db.collection(COLL).doc(item.expectedId);
      const sourceSnap = await sourceRef.get();
      if (!sourceSnap.exists) continue;
      const data = sourceSnap.data() as Record<string, unknown>;

      const targetSnap = await targetRef.get();
      if (!targetSnap.exists) {
        await targetRef.set({
          ...data,
          canonical_name: item.expectedId.replace(/_/g, " "),
          migrated_from_id: item.currentId,
          updated_at: FieldValue.serverTimestamp(),
        });
        result.renamed++;
      } else {
        const targetData = targetSnap.data() as Record<string, unknown>;
        const aliases = Array.isArray(data.aliases)
          ? data.aliases.filter((v): v is string => typeof v === "string")
          : [];
        const patch: Record<string, unknown> = {
          aliases: FieldValue.arrayUnion(...aliases, item.currentId.replace(/_/g, " ")),
          seen_count: FieldValue.increment(
            typeof data.seen_count === "number" ? data.seen_count : 0,
          ),
          updated_at: FieldValue.serverTimestamp(),
        };
        // Les valeurs de la cible font foi : on ne comble qu'un vide.
        if (!hasValues(targetData) && hasValues(data)) {
          patch.per100g = data.per100g;
          patch.source = data.source ?? "merged_from_misnormalized_id";
        }
        await targetRef.set(patch, { merge: true });
        result.merged++;
      }

      await sourceRef.delete();
      result.deleted++;
    } catch (err) {
      await logError({
        message: `cleanupIngredientReferential: échec sur ${item.currentId}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { currentId: item.currentId, expectedId: item.expectedId },
      });
    }
  }

  await logInfo({
    message: `cleanupIngredientReferential: ${result.deleted} document(s) corrigé(s)`,
    extra: { renamed: result.renamed, merged: result.merged, scanned: result.scanned },
  });

  return result;
}
