/// Le résumé d'une recette tel que l'atelier repas l'envoie au modèle.
///
/// Dérivé de `buildRecipeSummary` (`features/search/presentation/search_providers.dart`),
/// avec ce qui diffère, mesuré au palier 0 (5 novembre 2026, 664 recettes :
/// 390 caractères par résumé, dont la moitié pour les ingrédients, 127 000
/// jetons par tour avec 20 ingrédients) :
///
/// - `ingredients` : 6 au lieu de 20 ;
/// - sans `livre` ni `statut` : ni l'un ni l'autre n'aide à composer un repas ;
/// - avec `duree` : le temps total, préparation et cuisson. Sans elle, le
///   modèle jugeait « rapide » sur le titre.
///
/// Les clés sont celles de `SUMMARY_KEYS` (`functions/src/gemini/mealWorkshop.ts`),
/// qui filtre en liste blanche : une clé absente de l'une n'atteint pas le
/// prompt. `test-fixtures/meal_workshop_rules.json` les verrouille des deux
/// côtés.
library;

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';

/// Ingrédients au plus par résumé.
const int kWorkshopSummaryMaxIngredients = 6;

/// Les clés d'un résumé, dans l'ordre du serveur.
const List<String> kWorkshopSummaryKeys = [
  'id',
  'titre',
  'ingredients',
  'themes',
  'cuisines',
  'difficulte',
  'role',
  'proteine',
  'feculent',
  'note',
  'duree',
];

/// « 35 min » pour une durée lue dans la recette ; « ≈ 40 min » dès qu'une
/// des deux composantes vient de l'estimation de l'IA (`estimated_times`),
/// comme la tuile Explorer ; « inconnue » sans aucune durée.
String workshopRecipeDuration(Recipe recipe) {
  final times = recipeTimes(recipe);
  final total = times.total;
  if (total == null) return 'inconnue';
  return times.isEstimated ? '≈ $total min' : '$total min';
}

/// Le résumé compact d'une recette pour le prompt de l'atelier.
Map<String, String> buildMealWorkshopSummary(Recipe recipe, {int? myRating}) {
  return {
    'id': recipe.id,
    'titre': recipe.titre,
    'ingredients': recipe.ingredientsIndex
        .take(kWorkshopSummaryMaxIngredients)
        .join(', '),
    'themes': recipe.tags.themes.join(', '),
    'cuisines': recipe.tags.cuisines.join(', '),
    'difficulte': recipe.tags.difficulty ?? '',
    // Ce que la recette est dans un repas : le modèle écarte un plat dont le
    // féculent intégré contredit la demande. Vide tant qu'elle n'est pas
    // classée.
    'role': recipe.tags.mealRole ?? '',
    'proteine': recipe.tags.mainProtein ?? '',
    'feculent': recipe.tags.mainStarch ?? '',
    // Même écriture que `buildRecipeSummary` : le prompt lit « non notee ».
    'note': myRating != null ? '$myRating/10' : 'non notee',
    'duree': workshopRecipeDuration(recipe),
  };
}
