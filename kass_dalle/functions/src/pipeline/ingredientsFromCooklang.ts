import { extractIngredientsStructured } from "../cooklang/parser";
import type { StoredRecipeIngredient } from "../nutrition/referentialNormalization";

/**
 * La liste d'ingrédients dérivée du texte balisé, quand le livre n'en donne pas.
 *
 * La liste stockée vient normalement du balisage, qui part des lignes recopiées
 * par la transcription. Une recette écrite en prose — « faites revenir un
 * oignon avec deux gousses d'ail » — n'a aucune ligne à recopier : le balisage
 * rend une liste vide alors que le CookLang porte bien ses `@aliment{…}`. La
 * recette s'affichait alors sans ingrédients, sans liste de courses, sans
 * planification possible et sans nutrition, pendant que le texte, lui, les
 * nommait tous.
 *
 * Ce que cette dérivation ne rend pas, et qu'aucune ligne ne permet de rendre :
 * la note (« dégermées ») et le `source`, qui est la ligne du livre. Les
 * catégories viennent des sections d'étapes (`== Titre ==`), faute de sections
 * d'ingrédients. Les noms sont ceux écrits dans les phrases ; la normalisation
 * référentiel passe ensuite dessus comme sur n'importe quelle liste.
 */
export function ingredientsFromCooklang(cooklang: string): StoredRecipeIngredient[] {
  return extractIngredientsStructured(cooklang).map((i) => ({
    name: i.name,
    qty: i.qty,
    unit: i.unit,
    ...(i.category ? { category: i.category } : {}),
  }));
}
