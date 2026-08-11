/**
 * Vocabulaire commun aux traitements déclenchés par l'écriture d'une recette.
 *
 * L'empreinte des ingrédients existait en deux exemplaires identiques, un dans
 * chaque déclencheur. Deux copies d'une même règle de décision, c'est deux
 * occasions de diverger sur ce que « les ingrédients ont changé » veut dire.
 */

/** Ingrédient tel qu'il est stocké sur la recette : ce que la recette dit. */
export interface StoredIngredient {
  name?: string;
  qty?: string;
  unit?: string;
  category?: string;
}

/**
 * Signature des ingrédients d'une recette, insensible à tout le reste du
 * document. Elle sert de garde : les recalculs coûteux (Gemini, référentiels)
 * ne repartent que si les ingrédients eux-mêmes ont bougé — pas quand un
 * traitement vient d'écrire son propre résultat sur la recette.
 */
export function ingredientsFingerprint(ingredients: StoredIngredient[]): string {
  return ingredients
    .map((i) => `${i.name ?? ""}|${i.qty ?? ""}|${i.unit ?? ""}`)
    .join(";");
}
