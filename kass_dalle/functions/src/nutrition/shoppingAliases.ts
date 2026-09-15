/**
 * Le produit qu'on achète pour un ingrédient — lu dans le référentiel.
 *
 * « 150 g de beurre fondu » n'est pas un produit : on achète du beurre. « 2
 * jaunes d'œuf » non plus : on achète des œufs. Ce jugement était rendu par le
 * modèle quand il composait la liste de courses ; l'addition qui l'a remplacé
 * ne le rend pas. Il vit maintenant dans `nutrition_ingredients.shopping_product`,
 * rempli une fois par le backfill « Produit acheté des ingrédients » et corrigé
 * à la main depuis Admin › Référentiels › Ingrédients.
 *
 * Trois états du champ :
 *  - absent : jamais examiné — le backfill le demandera au modèle ;
 *  - vide : examiné, le nom est déjà le produit ;
 *  - renseigné : le produit acheté, qui remplace le nom sur la liste.
 */

import { COLL_NUTRITION_INGREDIENTS } from "../config";
import { buildIngredientLookupIds } from "./ingredientName";
import { readDocsByIds } from "./firestoreBatch";

/**
 * Alias de courses des ingrédients nommés, indexés par nom tel que fourni.
 *
 * Un nom sans alias n'a pas d'entrée. Les identifiants sont essayés du plus
 * précis au plus général (`buildIngredientLookupIds`) ; le premier document
 * qui porte le champ décide, même vide — un « déjà le produit » sur le
 * document strict n'est pas contredit par un alias posé sur une forme plus
 * générale.
 */
export async function loadShoppingProductAliases(
  names: Iterable<string>,
): Promise<Map<string, string>> {
  const wanted = new Map<string, string[]>();
  for (const raw of names) {
    const name = (raw ?? "").trim();
    if (!name || wanted.has(name)) continue;
    wanted.set(name, buildIngredientLookupIds(name));
  }
  const out = new Map<string, string>();
  if (wanted.size === 0) return out;

  const ids = [...new Set([...wanted.values()].flat())];
  const docs = await readDocsByIds(COLL_NUTRITION_INGREDIENTS, ids);

  for (const [name, lookupIds] of wanted) {
    for (const id of lookupIds) {
      const doc = docs.get(id);
      if (!doc) continue;
      const alias = doc.shopping_product;
      if (typeof alias !== "string") continue;
      const trimmed = alias.trim();
      if (trimmed) out.set(name, trimmed);
      break;
    }
  }
  return out;
}
