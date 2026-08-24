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
  return ingredients.map((i) => `${i.name ?? ""}|${i.qty ?? ""}|${i.unit ?? ""}`).join(";");
}

/**
 * Champs de la recette que le déclencheur d'écriture CONSOMME.
 *
 * Il en produit d'autres — `nutrition`, `shopping_products`,
 * `nutrition_validation` — mais il n'en lit aucun pour décider de son
 * résultat. La distinction est toute la garde : une écriture qui laisse ces
 * quatre champs intacts ne peut pas changer ce que le déclencheur produirait.
 */
const TRIGGER_INPUT_FIELDS = ["portions", "page_type", "raw_cooklang"] as const;

/**
 * Empreinte des ENTRÉES du déclencheur d'écriture de recette.
 *
 * La garde du déclencheur interrogeait la présence de sa SORTIE : « la
 * nutrition existe-t-elle déjà ? ». Cette question est fausse deux fois. Elle
 * répond non pendant toute la durée du calcul — plusieurs minutes, le temps des
 * appels d'IA — et chaque écriture qui tombe dans cette fenêtre relançait une
 * chaîne complète. Elle répond non pour toujours quand le calcul a échoué, et
 * la recette devenait alors un générateur d'appels : chacune de ses écritures
 * suivantes repartait de zéro, sans borne.
 *
 * Le déclencheur écrit dans la collection qu'il écoute. Il se réveille donc
 * lui-même, et le seul garde-fou solide est de comparer ce dont il DÉPEND. Le
 * compteur de tentatives, lui, ne bornait rien : il n'était lu que dans la
 * branche où la sortie existait déjà, c'est-à-dire jamais pendant la salve.
 */
export function recipeTriggerInputsFingerprint(data: Record<string, unknown> | undefined): string {
  if (!data) return "";
  const ingredients = (data.ingredients as StoredIngredient[] | undefined) ?? [];
  const scalars = TRIGGER_INPUT_FIELDS.map((field) => {
    const value = data[field];
    return value == null ? "" : String(value);
  });
  // Sérialisé plutôt que concaténé : aucun séparateur ne peut alors se
  // confondre avec le contenu d'un champ.
  return JSON.stringify([ingredientsFingerprint(ingredients), ...scalars]);
}
