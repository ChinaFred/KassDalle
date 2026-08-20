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
import { deriveShoppingProducts, type ShoppingInput } from "../nutrition/shoppingDerivation";
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
  /** Traitement auquel ce recalcul appartient — fourni par `onRecipeWritten`. */
  correlationId: string;
}): Promise<void> {
  const { after, data, ingredientsChanged, correlationId } = args;

  const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
  const noProductsYet = !Array.isArray(data.shopping_products);

  // Sortie rapide : rien n'a changé et les produits sont déjà calculés
  if (!ingredientsChanged && !noProductsYet) return;

  if (ingredients.length === 0) {
    await after.ref.update({ shopping_products: [] });
    return;
  }

  const userId = (data.created_by as string | undefined) ?? "";

  logInfo({
    message: "refreshShoppingProducts: recalcul produits",
    moduleType: "DESIGN",
    correlationId,
    userId,
    extra: { recipeId: after.id, ingredientsCount: ingredients.length },
  });

  const inputs: ShoppingInput[] = ingredients
    .filter((i) => (i.name ?? "").trim().length > 0)
    .map((i) => ({
      name: i.name!.trim(),
      qty: i.qty ?? "",
      unit: i.unit ?? "",
    }));

  try {
    // Plus d'appel de modèle ici.
    //
    // Le regroupement demandait un jugement tant que la liste d'ingrédients
    // était reconstituée depuis les balises des étapes, où le même aliment
    // apparaissait sous plusieurs orthographes. Elle vient maintenant de la
    // liste du livre, une entrée par ligne : regrouper est devenu une addition.
    const products = deriveShoppingProducts(inputs);

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
