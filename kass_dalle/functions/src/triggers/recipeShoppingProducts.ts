/**
 * Trigger Firestore : recalcule automatiquement `shopping_products` quand
 * les ingrédients d'une recette changent.
 *
 * Fonctionnement :
 *  - Écoute tout write sur `recipes/{recipeId}`
 *  - Ne traite que les pages de type "recipe"
 *  - Ne recalcule que si les ingrédients ont changé OU si `shopping_products` est absent
 *  - Met à jour uniquement le champ `shopping_products` (évite la boucle trigger)
 *  - Best-effort : une erreur n'impacte pas la sauvegarde principale
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { randomUUID } from "node:crypto";
import { GEMINI_API_KEY, REGION } from "../config";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";
import { logError, logInfo } from "../logging";

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

export const onRecipeShoppingProductsRefresh = onDocumentWritten(
  {
    document: "recipes/{recipeId}",
    region: REGION,
    secrets: [GEMINI_API_KEY],
    memory: "512MiB" as const,
    timeoutSeconds: 120,
  },
  async (event) => {
    const after = event.data?.after;
    if (!after?.exists) return; // suppression — ignorer

    const data = after.data() as Record<string, unknown>;
    const before = event.data?.before;
    const beforeData = before?.data() as Record<string, unknown> | undefined;

    // Ne traiter que les recettes (pas les pages techniques, notes, etc.)
    const pageType = (data.page_type as string | undefined) ?? "recipe";
    if (pageType !== "recipe") return;

    const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
    const beforeIngredients = (beforeData?.ingredients as StoredIngredient[] | undefined) ?? [];

    const ingredientsChanged =
      ingredientsFingerprint(ingredients) !== ingredientsFingerprint(beforeIngredients);
    const noProductsYet = !Array.isArray(data.shopping_products);

    // Sortie rapide : rien n'a changé et les produits sont déjà calculés
    if (!ingredientsChanged && !noProductsYet) return;

    if (ingredients.length === 0) {
      await after.ref.update({ shopping_products: [] });
      return;
    }

    const userId = (data.created_by as string | undefined) ?? "";
    const correlationId = randomUUID();

    logInfo({
      message: "onRecipeShoppingProductsRefresh: recalcul produits",
      moduleType: "DESIGN",
      correlationId,
      userId,
      extra: { recipeId: after.id, ingredientsCount: ingredients.length },
    });

    const inputs: ShoppingIngredientInput[] = ingredients
      .filter((i) => (i.name ?? "").trim().length > 0)
      .map((i) => ({
        name: i.name!.trim(),
        qty: i.qty ?? "",
        unit: i.unit ?? "",
      }));

    try {
      const products = await consolidateShoppingList(
        GEMINI_API_KEY.value(),
        inputs,
        { correlationId, feature: "shopping_list", moduleType: "DESIGN", userId },
      );

      await after.ref.update({
        shopping_products: products.map((p) => ({
          name: p.name,
          qty: p.qty,
          unit: p.unit,
        })),
      });

      logInfo({
        message: "onRecipeShoppingProductsRefresh: produits mis à jour",
        moduleType: "DESIGN",
        correlationId,
        userId,
        extra: { recipeId: after.id, productCount: products.length },
      });
    } catch (err) {
      // Best-effort : ne pas faire échouer l'écriture principale
      logError({
        message: "onRecipeShoppingProductsRefresh: consolidation échouée (best-effort)",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        correlationId,
        userId,
        extra: { recipeId: after.id },
      });
    }
  },
);
