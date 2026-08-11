/**
 * Recalcul des produits d'achat (`shopping_products`) d'une recette.
 *
 * Fonctionnement :
 *  - Ne recalcule que si les ingrédients ont changé OU si `shopping_products` est absent
 *  - Met à jour uniquement le champ `shopping_products`
 *  - Best-effort : une erreur n'impacte pas la sauvegarde principale
 *
 * Ce fichier exposait autrefois son propre déclencheur `onDocumentWritten` sur
 * `recipes/{recipeId}`, en parallèle de celui de la nutrition. Le traitement
 * vit désormais sous le déclencheur unique `onRecipeWritten`.
 */

import type { DocumentSnapshot } from "firebase-admin/firestore";
import { randomUUID } from "node:crypto";
import { GEMINI_API_KEY } from "../config";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";
import { logError, logInfo } from "../logging";
import type { StoredIngredient } from "./recipeIngredients";

/**
 * Consolide les ingrédients d'une recette en produits d'achat.
 *
 * Appelé par le déclencheur unique `onRecipeWritten`, qui a déjà écarté les
 * suppressions et les pages non-recette.
 */
export async function refreshShoppingProducts(args: {
  after: DocumentSnapshot;
  data: Record<string, unknown>;
  ingredientsChanged: boolean;
}): Promise<void> {
  const { after, data, ingredientsChanged } = args;

  const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
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
    message: "refreshShoppingProducts: recalcul produits",
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
      {
        geminiFeature: "shopping_products_refresh",
        usageFeature: "shopping_products_refresh",
        logUsage: true,
      },
    );

    await after.ref.update({
      shopping_products: products.map((p) => ({
        name: p.name,
        qty: p.qty,
        unit: p.unit,
      })),
    });

    logInfo({
      message: "refreshShoppingProducts: produits mis à jour",
      moduleType: "DESIGN",
      correlationId,
      userId,
      extra: { recipeId: after.id, productCount: products.length },
    });
  } catch (err) {
    // Best-effort : ne pas faire échouer l'écriture principale
    logError({
      message: "refreshShoppingProducts: consolidation échouée (best-effort)",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId,
      userId,
      extra: { recipeId: after.id },
    });
  }
}
