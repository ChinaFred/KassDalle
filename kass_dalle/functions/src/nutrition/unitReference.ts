import { FieldValue, Firestore } from "firebase-admin/firestore";

import { COLL_NUTRITION_UNITS } from "../config";
import { getKnownUnitMetadata, normalizeObservedUnit } from "./quantityConversion";

export async function upsertNutritionUnitReference(args: {
  db: Firestore;
  unitRaw: string;
  ingredientName?: string;
  recipeId?: string;
  /** Poids estimé par l'IA pour 1 unité, utilisé uniquement si l'unité est inconnue. */
  gramsPerUnitEstimate?: number;
}): Promise<{ created: boolean; known: boolean; normalizedUnit: string | null }> {
  const unitRaw = args.unitRaw.trim();
  if (!unitRaw) {
    return { created: false, known: false, normalizedUnit: null };
  }

  const normalizedUnit = normalizeObservedUnit(unitRaw);
  if (!normalizedUnit) {
    return { created: false, known: false, normalizedUnit: null };
  }

  const metadata = getKnownUnitMetadata(unitRaw, args.ingredientName);
  const docRef = args.db.collection(COLL_NUTRITION_UNITS).doc(normalizedUnit);

  const baseFields = {
    normalized_unit: normalizedUnit,
    label: unitRaw,
    aliases: [unitRaw],
    ...(args.ingredientName ? { sample_ingredient_names: [args.ingredientName] } : {}),
    status: metadata ? "known" : (args.gramsPerUnitEstimate != null ? "ai_estimated" : "unknown"),
    measurement_type: metadata?.measurementType ?? (args.gramsPerUnitEstimate != null ? "weight" : "unknown"),
    ...(metadata
      ? {
          grams_per_unit: metadata.gramsPerUnit,
          ...(metadata.mlPerUnit != null ? { volume_ml_per_unit: metadata.mlPerUnit } : {}),
          conversion_source: metadata.source,
        }
      : args.gramsPerUnitEstimate != null
        ? { grams_per_unit: args.gramsPerUnitEstimate, conversion_source: "ai_estimation" }
        : {}),
    seen_count: 1,
    first_seen_at: FieldValue.serverTimestamp(),
    last_seen_at: FieldValue.serverTimestamp(),
    ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  };

  try {
    await docRef.create(baseFields);
    return { created: true, known: metadata != null, normalizedUnit };
  } catch (err) {
    const codeRaw = (err as { code?: unknown })?.code;
    const code = typeof codeRaw === "string" || typeof codeRaw === "number"
      ? String(codeRaw)
      : "";
    const alreadyExists = code.includes("already-exists") || code === "6";
    if (!alreadyExists) throw err;

    await docRef.set({
      aliases: FieldValue.arrayUnion(unitRaw),
      ...(args.ingredientName
        ? { sample_ingredient_names: FieldValue.arrayUnion(args.ingredientName) }
        : {}),
      seen_count: FieldValue.increment(1),
      last_seen_at: FieldValue.serverTimestamp(),
      ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
      updated_at: FieldValue.serverTimestamp(),
      ...(metadata
        ? {
            status: "known",
            measurement_type: metadata.measurementType,
            grams_per_unit: metadata.gramsPerUnit,
            ...(metadata.mlPerUnit != null ? { volume_ml_per_unit: metadata.mlPerUnit } : {}),
            conversion_source: metadata.source,
          }
        : {}),
    }, { merge: true });

    return { created: false, known: metadata != null, normalizedUnit };
  }
}
