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
    status: metadata ? "known" : args.gramsPerUnitEstimate != null ? "ai_estimated" : "unknown",
    measurement_type:
      metadata?.measurementType ?? (args.gramsPerUnitEstimate != null ? "weight" : "unknown"),
    // Sur une unité de VOLUME on n'enregistre que le volume : le poids dépend de
    // la densité de l'ingrédient, et figer ici les grammes du premier ingrédient
    // rencontré les imposerait ensuite à tous les autres.
    //
    // Sur une unité de COMPTAGE on n'enregistre RIEN : « pièce » n'a pas de
    // poids, c'est l'ingrédient qui en a un. Cette exception manquait, et le
    // premier ingrédient croisé en pièces — souvent inconnu, donc 100 g par
    // défaut — figeait `grams_per_unit: 100` sur `piece`. Ce chiffre écrasait
    // ensuite le poids propre de chaque ingrédient : un blanc d'œuf pesait
    // 100 g au lieu de 30, trois échalotes 300 g au lieu de 90.
    ...(metadata
      ? metadata.measurementType === "volume"
        ? {
            ...(metadata.mlPerUnit != null ? { volume_ml_per_unit: metadata.mlPerUnit } : {}),
            conversion_source: metadata.source,
          }
        : metadata.measurementType === "count"
          ? { conversion_source: metadata.source }
          : {
              grams_per_unit: metadata.gramsPerUnit,
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
    const code = typeof codeRaw === "string" || typeof codeRaw === "number" ? String(codeRaw) : "";
    const alreadyExists = code.includes("already-exists") || code === "6";
    if (!alreadyExists) throw err;

    await docRef.set(
      {
        aliases: FieldValue.arrayUnion(unitRaw),
        ...(args.ingredientName
          ? { sample_ingredient_names: FieldValue.arrayUnion(args.ingredientName) }
          : {}),
        seen_count: FieldValue.increment(1),
        last_seen_at: FieldValue.serverTimestamp(),
        ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
        updated_at: FieldValue.serverTimestamp(),
        // Même règle qu'à la création : pas de grammes figés sur une unité de
        // volume ni de comptage. Sur un comptage, le champ est en plus SUPPRIMÉ —
        // les documents déjà pollués par un `grams_per_unit: 100` se réparent
        // ainsi d'eux-mêmes au premier ingrédient revu, sans backfill.
        ...(metadata
          ? metadata.measurementType === "volume"
            ? {
                status: "known",
                measurement_type: metadata.measurementType,
                ...(metadata.mlPerUnit != null ? { volume_ml_per_unit: metadata.mlPerUnit } : {}),
                conversion_source: metadata.source,
              }
            : metadata.measurementType === "count"
              ? {
                  status: "known",
                  measurement_type: metadata.measurementType,
                  grams_per_unit: FieldValue.delete(),
                  conversion_source: metadata.source,
                }
              : {
                  status: "known",
                  measurement_type: metadata.measurementType,
                  grams_per_unit: metadata.gramsPerUnit,
                  conversion_source: metadata.source,
                }
          : {}),
      },
      { merge: true },
    );

    return { created: false, known: metadata != null, normalizedUnit };
  }
}
