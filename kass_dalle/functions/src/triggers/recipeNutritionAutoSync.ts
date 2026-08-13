/**
 * Synchronisation nutrition d'une recette.
 *
 * Ce fichier exposait autrefois son propre déclencheur `onDocumentWritten` sur
 * `recipes/{recipeId}`, en parallèle de celui des produits d'achat. Deux
 * déclencheurs sur le même document, chacun réécrivant ce document, donc
 * chacun réveillant l'autre : quatre invocations de fonction 512 MiB pour une
 * seule sauvegarde de recette. Le traitement vit désormais sous le déclencheur
 * unique `onRecipeWritten`.
 */

import type { DocumentSnapshot } from "firebase-admin/firestore";
import { FieldValue, getFirestore, type Firestore } from "firebase-admin/firestore";

import { GEMINI_API_KEY } from "../config";
import { logError, logInfo } from "../logging";
import { normalizeIngredientCanonicalId } from "../nutrition/ingredientName";
import { getKnownUnitMetadata, parseQuantityToNumber } from "../nutrition/quantityConversion";
import {
  resolveIngredientUnitFields,
  type UnitResolvedIngredient,
} from "../nutrition/ingredientUnitResolution";
import { hasPer100gValues } from "../nutrition/per100gEnrichment";
import {
  enrichUnknownIngredientsWithAI,
  enrichUnknownUnitsWithAI,
} from "../nutrition/aiEnrichment";
import { upsertNutritionUnitReference } from "../nutrition/unitReference";
import { computeAndPersistRecipeNutrition } from "../nutrition/recipeNutrition";

import type { StoredIngredient } from "./recipeIngredients";

type NormalizedIngredientInput = UnitResolvedIngredient;

function toPositiveNumber(value: unknown): number | undefined {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value.replace(",", "."));
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return undefined;
}

function toConvertibleQuantity(value: unknown): number | undefined {
  return parseQuantityToNumber(value) ?? undefined;
}

/** Nombre de passages d'enrichissement accordés à une même liste d'ingrédients. */
const MAX_ENRICHMENT_ATTEMPTS = 3;

function toAttemptCount(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : 0;
}

/**
 * Combien d'ingrédients de la recette n'ont toujours aucune valeur
 * nutritionnelle. Lecture seule, sans appel Gemini : c'est ce qui décide si un
 * rattrapage vaut la peine d'être tenté.
 */
async function countIngredientsWithoutValues(
  db: Firestore,
  inputs: NormalizedIngredientInput[],
): Promise<number> {
  const ids = [
    ...new Set(
      inputs
        .map((i) => normalizeIngredientCanonicalId(i.name))
        .filter((id) => id.length > 0),
    ),
  ];
  if (ids.length === 0) return 0;

  const snaps = await db.getAll(
    ...ids.map((id) => db.collection("nutrition_ingredients").doc(id)),
  );
  let pending = 0;
  for (const snap of snaps) {
    if (!snap.exists) {
      pending++;
      continue;
    }
    if (!hasPer100gValues((snap.data() as Record<string, unknown>).per100g)) {
      pending++;
    }
  }
  return pending;
}

/**
 * Recalcule la nutrition d'une recette et entretient les référentiels
 * (ingrédients, unités) à partir de ce que la recette déclare.
 *
 * Appelé par le déclencheur unique `onRecipeWritten`, qui a déjà écarté les
 * suppressions et les pages non-recette.
 */
export async function syncRecipeNutrition(args: {
  after: DocumentSnapshot;
  data: Record<string, unknown>;
  ingredientsChanged: boolean;
  /** Traitement auquel ce recalcul appartient — fourni par `onRecipeWritten`. */
  correlationId: string;
}): Promise<void> {
  const { after, data, ingredientsChanged, correlationId } = args;

  const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];

  const inputs: NormalizedIngredientInput[] = ingredients
    .filter((i) => (i.name ?? "").trim().length > 0)
    .map((i) => resolveIngredientUnitFields(i));

  const db = getFirestore();

  const hasNutrition = data.nutrition && typeof data.nutrition === "object";
  const previousAttempts = toAttemptCount(data.nutrition_enrichment_attempts);

  // Drapeau posé par la normalisation quand elle vient d'enrichir des `per100g`
  // sans que les ingrédients de la recette aient bougé. C'est le seul cas que
  // la garde ci-dessous ne peut pas voir seule : tous les ingrédients ont
  // désormais leurs valeurs — `countIngredientsWithoutValues` rendrait zéro —
  // mais la nutrition en place a été calculée sur un référentiel plus pauvre.
  const nutritionStale = data.nutrition_stale === true;

  // Rattrapage borné. Un enrichissement raté — quota Gemini atteint, réponse
  // illisible, container coupé — laissait jusqu'ici l'ingrédient définitivement
  // muet : cette garde ne rendait la main qu'au prochain changement
  // d'ingrédients, que rien ne garantit. On accorde donc quelques passages
  // supplémentaires, mais un nombre FIXE : ce déclencheur réécrit la recette et
  // se réveille lui-même, une relance conditionnée au seul échec tournerait en
  // boucle sur un ingrédient qui échoue toujours.
  if (!ingredientsChanged && hasNutrition && !nutritionStale) {
    if (previousAttempts >= MAX_ENRICHMENT_ATTEMPTS) return;
    const pending = await countIngredientsWithoutValues(db, inputs);
    if (pending === 0) return;
    await logInfo({
      message: `onRecipeNutritionAutoSync: rattrapage ${previousAttempts + 1}/${MAX_ENRICHMENT_ATTEMPTS}`,
      moduleType: "DESIGN",
      extra: { recipeId: after.id, ingredientsSansValeur: pending },
    });
  }

  const userId = (data.created_by as string | undefined) ?? undefined;

  let createdRefs = 0;
  let updatedRefs = 0;
  let enriched = 0;
  let failedEnrichment = 0;
  let createdUnitRefs = 0;
  let updatedUnitRefs = 0;
  let unknownUnitRefs = 0;
  let convertibleInputs = 0;
  const invalidQuantities = new Set<string>();
  const unknownUnits = new Set<string>();

  try {
    if (inputs.length === 0) {
      await computeAndPersistRecipeNutrition({
        recipeId: after.id,
        selectedPortions: toPositiveNumber(data.portions),
        geminiApiKey: GEMINI_API_KEY.value(),
      });

      // Éteindre le drapeau ici aussi, et pas seulement sur le chemin nominal.
      // Ce traitement réécrit la recette, donc se réveille lui-même : un
      // `nutrition_stale` resté allumé sur une recette vidée de ses ingrédients
      // court-circuiterait la garde à chaque réveil, et tournerait sans fin.
      if (nutritionStale) {
        await after.ref.set({ nutrition_stale: false }, { merge: true });
      }

      await logInfo({
        message: "onRecipeNutritionAutoSync: recette sans ingrédients, nutrition recalculée",
        moduleType: "DESIGN",
        correlationId,
        userId,
        extra: { recipeId: after.id },
      });
      return;
    }

    for (const input of inputs) {
      const qtyValue = toConvertibleQuantity(input.qty);
      const unit = input.unit;
      const unitMetadata = input.unit_canonical
        ? getKnownUnitMetadata(input.unit_canonical, input.name)
        : null;

      if (qtyValue == null) {
        invalidQuantities.add(`${input.name}|${input.qty}`);
      }

      if (!unitMetadata) {
        unknownUnits.add(`${input.name}|${unit || "(vide)"}`);
      }

      if (qtyValue != null && unitMetadata != null) {
        convertibleInputs++;
      }

      const unitForReference = input.unit_raw.length > 0
        ? input.unit_raw
        : input.unit_canonical;
      if (!unitForReference) continue;
      try {
        const result = await upsertNutritionUnitReference({
          db,
          unitRaw: unitForReference,
          ingredientName: input.name,
          recipeId: after.id,
        });
        if (result.normalizedUnit == null) continue;
        if (result.created) {
          createdUnitRefs++;
        } else {
          updatedUnitRefs++;
        }
        if (!result.known) {
          unknownUnitRefs++;
        }
      } catch (err) {
        await logError({
          message: "onRecipeNutritionAutoSync: synchronisation référentiel unités échouée",
          moduleType: "DESIGN",
          correlationId,
          userId,
          errorDescription: err instanceof Error ? err.message : String(err),
          extra: { recipeId: after.id, unit: unitForReference },
        });
      }
    }

    // Enrichissement des unités sans poids — la symétrie qui manquait.
    //
    // Ce déclencheur créait les documents d'unité puis les laissait tels quels,
    // alors qu'il enrichissait les per100g des ingrédients juste en dessous.
    // Une unité rencontrée par ce chemin restait donc sans poids jusqu'à ce
    // qu'une normalisation passe par là — et sans poids, l'ingrédient qui la
    // porte sort du calcul. Le référentiel doit s'enrichir quel que soit le
    // chemin par lequel la recette arrive.
    const unitCanonicalsSeen = [...new Set(
      inputs.map((i) => i.unit_canonical).filter((u) => u.length > 0),
    )];
    if (unitCanonicalsSeen.length > 0) {
      const unitIngredientNames = new Map<string, string[]>();
      for (const input of inputs) {
        const canonical = input.unit_canonical;
        const name = input.name.trim();
        if (!canonical || !name) continue;
        const list = unitIngredientNames.get(canonical) ?? [];
        if (!list.includes(name)) list.push(name);
        unitIngredientNames.set(canonical, list);
      }
      await enrichUnknownUnitsWithAI({
        unitCanonicals: unitCanonicalsSeen,
        geminiApiKey: GEMINI_API_KEY.value(),
        userId,
        recipeId: after.id,
        unitIngredientNames,
      });
    }

    const ingredientValidationState =
      invalidQuantities.size === 0 && unknownUnits.size === 0
        ? "ok"
        : (convertibleInputs > 0 ? "partial" : "unknown");

    // Ce déclencheur n'écrit PAS `ingredients` : ce champ appartient à la
    // normalisation, et lui seul. La résolution d'unité qu'on vient de faire
    // est un intermédiaire de calcul — la reposer sur la recette revenait à
    // disputer un champ dont personne ne relit le contenu, et à effacer au
    // passage la catégorie que la sauvegarde venait d'y écrire.
    await after.ref.set(
      {
        // Compteur de passages, remis à zéro dès que les ingrédients changent :
        // une liste modifiée mérite ses propres tentatives.
        nutrition_enrichment_attempts: ingredientsChanged ? 1 : previousAttempts + 1,
        // Le drapeau a été honoré : on l'éteint. Le laisser allumé relancerait
        // ce traitement à chaque écriture suivante, sans jamais rien trouver
        // de nouveau à faire.
        nutrition_stale: false,
        nutrition_validation: {
          checked_at: FieldValue.serverTimestamp(),
          state: ingredientValidationState,
          checked_ingredients: inputs.length,
          convertible_ingredients: convertibleInputs,
          invalid_quantities: [...invalidQuantities].slice(0, 50),
          unknown_units: [...unknownUnits].slice(0, 50),
          unit_reference_sync: {
            created: createdUnitRefs,
            updated: updatedUnitRefs,
            unknown_observed: unknownUnitRefs,
          },
        },
      },
      { merge: true },
    );

    const aliasesByCanonical = new Map<string, Set<string>>();
    for (const input of inputs) {
      const canonicalId = normalizeIngredientCanonicalId(input.name);
      if (!canonicalId) continue;
      if (!aliasesByCanonical.has(canonicalId)) {
        aliasesByCanonical.set(canonicalId, new Set<string>());
      }
      aliasesByCanonical.get(canonicalId)!.add(input.name);
    }

    for (const [canonicalId, aliasSet] of aliasesByCanonical.entries()) {
      const aliases = [...aliasSet];
      const docRef = db.collection("nutrition_ingredients").doc(canonicalId);
      try {
        await docRef.create({
          canonical_name: canonicalId.replace(/_/g, " "),
          aliases,
          per100g: {},
          source: "recipe_auto_sync",
          source_priority: ["recipe_auto_sync"],
          quality_status: "pending",
          seen_count: 1,
          first_seen_at: FieldValue.serverTimestamp(),
          last_seen_at: FieldValue.serverTimestamp(),
          last_seen_recipe_id: after.id,
          created_at: FieldValue.serverTimestamp(),
          updated_at: FieldValue.serverTimestamp(),
        });
        createdRefs++;
      } catch (err) {
        const codeRaw = (err as { code?: unknown })?.code;
        const code = typeof codeRaw === "string" || typeof codeRaw === "number"
          ? String(codeRaw)
          : "";
        const alreadyExists = code.includes("already-exists") || code === "6";
        if (!alreadyExists) throw err;

        await docRef.set({
          aliases: FieldValue.arrayUnion(...aliases),
          seen_count: FieldValue.increment(1),
          last_seen_at: FieldValue.serverTimestamp(),
          last_seen_recipe_id: after.id,
          updated_at: FieldValue.serverTimestamp(),
        }, { merge: true });
        updatedRefs++;
      }
    }

    // Enrichissement per100g de TOUS les ingrédients de la recette qui n'en ont
    // pas. Ce traitement plafonnait à douze parce qu'il dépensait un appel
    // Gemini par ingrédient, séquentiellement : au treizième, la recette perdait
    // le reste de ses ingrédients sans un mot. Le lot rend le plafond inutile,
    // et l'échéance protège ce qui protégeait vraiment — le timeout de 300 s du
    // déclencheur, partagé avec le rafraîchissement des produits d'achat.
    const enrichmentDeadlineMs = Date.now() + 200_000;
    const candidateIds = [...aliasesByCanonical.keys()];
    enriched = await enrichUnknownIngredientsWithAI({
      ingredientRefIds: candidateIds,
      geminiApiKey: GEMINI_API_KEY.value(),
      userId,
      recipeId: after.id,
      deadlineMs: enrichmentDeadlineMs,
    });

    // Ce qui reste sans valeur après enrichissement : comptabilisé ici pour le
    // journal de fin, le détail par ingrédient étant déjà tracé en erreur.
    {
      const refs = candidateIds.map((id) => db.collection("nutrition_ingredients").doc(id));
      const snaps = refs.length > 0 ? await db.getAll(...refs) : [];
      for (const snap of snaps) {
        if (!snap.exists) continue;
        if (!hasPer100gValues((snap.data() as Record<string, unknown>).per100g)) {
          failedEnrichment++;
        }
      }
    }

    await computeAndPersistRecipeNutrition({
      recipeId: after.id,
      selectedPortions: toPositiveNumber(data.portions),
      geminiApiKey: GEMINI_API_KEY.value(),
    });

    await logInfo({
      message: "onRecipeNutritionAutoSync: synchronisation nutrition terminée",
      moduleType: "DESIGN",
      correlationId,
      userId,
      extra: {
        recipeId: after.id,
        ingredientsCount: inputs.length,
        createdRefs,
        updatedRefs,
        createdUnitRefs,
        updatedUnitRefs,
        unknownUnitRefs,
        convertibleInputs,
        invalidQuantitiesCount: invalidQuantities.size,
        unknownUnitsCount: unknownUnits.size,
        enriched,
        failedEnrichment,
      },
    });
  } catch (err) {
    await logError({
      message: "onRecipeNutritionAutoSync: échec global (best-effort)",
      moduleType: "DESIGN",
      correlationId,
      userId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: {
        recipeId: after.id,
        ingredientsCount: inputs.length,
        createdRefs,
        updatedRefs,
        createdUnitRefs,
        updatedUnitRefs,
        unknownUnitRefs,
        convertibleInputs,
        invalidQuantitiesCount: invalidQuantities.size,
        unknownUnitsCount: unknownUnits.size,
        enriched,
        failedEnrichment,
      },
    });
  }
}
