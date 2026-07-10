import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { randomUUID } from "node:crypto";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { GEMINI_API_KEY, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { normalizeIngredientCanonicalId } from "../nutrition/ingredientName";
import { estimatePer100gWithGemini, hasPer100gValues } from "../nutrition/per100gEnrichment";
import { computeAndPersistRecipeNutrition } from "../callable/nutritionCallable";

interface StoredIngredient {
  name?: string;
  qty?: string;
  unit?: string;
}

function ingredientsFingerprint(ingredients: StoredIngredient[]): string {
  return ingredients
    .map((i) => `${i.name ?? ""}|${i.qty ?? ""}|${i.unit ?? ""}`)
    .join(";");
}

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

export const onRecipeNutritionAutoSync = onDocumentWritten(
  {
    document: "recipes/{recipeId}",
    region: REGION,
    secrets: [GEMINI_API_KEY],
    memory: "512MiB" as const,
    timeoutSeconds: 180,
  },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) return;

    const data = after.data() as Record<string, unknown>;
    const beforeData = event.data?.before?.data() as Record<string, unknown> | undefined;

    const pageType = (data.page_type as string | undefined) ?? "recipe";
    if (pageType !== "recipe") return;

    const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
    const beforeIngredients = (beforeData?.ingredients as StoredIngredient[] | undefined) ?? [];

    const ingredientsChanged =
      ingredientsFingerprint(ingredients) !== ingredientsFingerprint(beforeIngredients);

    const hasNutrition = data.nutrition && typeof data.nutrition === "object";
    if (!ingredientsChanged && hasNutrition) {
      return;
    }

    const inputs = ingredients
      .filter((i) => (i.name ?? "").trim().length > 0)
      .map((i) => ({
        name: i.name!.trim(),
        qty: i.qty ?? "",
        unit: i.unit ?? "",
      }));

    if (inputs.length === 0) {
      return;
    }

    const db = getFirestore();
    const correlationId = randomUUID();
    const userId = (data.created_by as string | undefined) ?? undefined;

    let createdRefs = 0;
    let updatedRefs = 0;
    let enriched = 0;
    let failedEnrichment = 0;

    try {
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

      const maxEnrichmentPerRecipe = 12;
      for (const canonicalId of aliasesByCanonical.keys()) {
        if (enriched + failedEnrichment >= maxEnrichmentPerRecipe) break;

        const docRef = db.collection("nutrition_ingredients").doc(canonicalId);
        const snap = await docRef.get();
        if (!snap.exists) continue;

        const refData = snap.data() as Record<string, unknown>;
        if (hasPer100gValues(refData.per100g)) continue;

        const canonicalName = (typeof refData.canonical_name === "string" && refData.canonical_name.trim().length > 0)
          ? refData.canonical_name.trim()
          : canonicalId.replace(/_/g, " ");
        const aliases = Array.isArray(refData.aliases)
          ? refData.aliases.filter((v): v is string => typeof v === "string")
          : [];

        try {
          const per100g = await estimatePer100gWithGemini({
            apiKey: GEMINI_API_KEY.value(),
            ingredientId: canonicalId,
            canonicalName,
            aliases,
            correlationId,
            userId,
            feature: "nutrition_ingredients_enrichment_auto",
          });

          if (Object.keys(per100g).length === 0) {
            failedEnrichment++;
            continue;
          }

          await docRef.set({
            per100g,
            source: "gemini_estimated",
            quality_status: "estimated_ai",
            last_enriched_at: FieldValue.serverTimestamp(),
            updated_at: FieldValue.serverTimestamp(),
          }, { merge: true });
          enriched++;
        } catch (err) {
          failedEnrichment++;
          await logError({
            message: "onRecipeNutritionAutoSync: enrichissement ingrédient échoué",
            moduleType: "DESIGN",
            correlationId,
            userId,
            errorDescription: err instanceof Error ? err.message : String(err),
            extra: { recipeId: after.id, ingredientId: canonicalId },
          });
        }
      }

      await computeAndPersistRecipeNutrition({
        recipeId: after.id,
        selectedPortions: toPositiveNumber(data.portions),
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
          enriched,
          failedEnrichment,
        },
      });
    }
  },
);
