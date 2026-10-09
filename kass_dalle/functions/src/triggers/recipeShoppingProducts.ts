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
import { recipeBudgetUserId } from "../ai/budget";
import { deriveShoppingProducts, type ShoppingInput } from "../nutrition/shoppingDerivation";
import { loadShoppingProductAliases } from "../nutrition/shoppingAliases";
import { logError, logInfo } from "../logging";
import type { StoredIngredient } from "./recipeIngredients";

/**
 * Alias de courses des ingrédients, ou aucun si le référentiel ne répond pas.
 *
 * Une lecture qui échoue ne bloque pas les courses : la liste se calcule avec
 * les noms bruts, comme avant l'alias, et l'échec est journalisé.
 */
export async function shoppingAliasesOrNone(
  names: Iterable<string>,
  log: { correlationId: string; scanId?: string; userId?: string; recipeId: string },
): Promise<Map<string, string>> {
  try {
    return await loadShoppingProductAliases(names);
  } catch (err) {
    logError({
      message: "refreshShoppingProducts: alias de courses illisibles, noms bruts conservés",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId: log.correlationId,
      scanId: log.scanId,
      userId: log.userId,
      extra: { recipeId: log.recipeId },
    });
    return new Map();
  }
}

/** Entrées du regroupement : nom brut, quantité, unité, et l'alias s'il existe. */
export function shoppingInputsOf(
  ingredients: StoredIngredient[],
  aliases: ReadonlyMap<string, string>,
): ShoppingInput[] {
  return ingredients
    .filter((i) => (i.name ?? "").trim().length > 0)
    .map((i) => {
      const name = i.name!.trim();
      return {
        name,
        qty: i.qty ?? "",
        unit: i.unit ?? "",
        shoppingProduct: aliases.get(name) ?? null,
      };
    });
}

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
  /** Scan de l'utilisateur d'où vient ce travail, quand il en vient un. */
  scanId?: string;
}): Promise<void> {
  const { after, data, ingredientsChanged, correlationId, scanId } = args;

  const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
  const noProductsYet = !Array.isArray(data.shopping_products);

  // Sortie rapide : rien n'a changé et les produits sont déjà calculés
  if (!ingredientsChanged && !noProductsYet) return;

  if (ingredients.length === 0) {
    await after.ref.update({ shopping_products: [] });
    return;
  }

  // Même imputation que les autres déclencheurs de la recette (`ai/budget.ts`).
  const userId = recipeBudgetUserId(data.created_by);

  logInfo({
    message: "refreshShoppingProducts: recalcul produits",
    moduleType: "DESIGN",
    correlationId,
    scanId,
    userId,
    extra: { recipeId: after.id, ingredientsCount: ingredients.length },
  });

  const aliases = await shoppingAliasesOrNone(
    ingredients.map((i) => i.name ?? ""),
    { correlationId, scanId, userId, recipeId: after.id },
  );
  const inputs: ShoppingInput[] = shoppingInputsOf(ingredients, aliases);

  try {
    // Plus d'appel de modèle ici.
    //
    // Le regroupement demandait un jugement tant que la liste d'ingrédients
    // était reconstituée depuis les balises des étapes, où le même aliment
    // apparaissait sous plusieurs orthographes. Elle vient maintenant de la
    // liste du livre, une entrée par ligne : regrouper est devenu une addition.
    // Ce que l'addition ne sait pas — beurre fondu s'achète en beurre — vient
    // du référentiel, par `shopping_product`.
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
      scanId,
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
      scanId,
      userId,
      extra: { recipeId: after.id },
    });
  }
}
