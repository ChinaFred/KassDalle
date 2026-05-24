import '../../../../core/services/gemini_service.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/planning_preferences.dart';

/// Service d'IA pour la génération de planning de repas via Gemini.
/// Délègue à la Cloud Function `suggestMealPlanFn` via [GeminiService].
class PlanningAiService {
  final GeminiService _gemini;

  const PlanningAiService(this._gemini);

  /// Suggère un planning de repas pour les [slotDates] données.
  ///
  /// Retourne une liste de la même taille que [slotDates].
  /// Chaque entrée est soit une Recipe suggérée, soit null si aucune suggestion.
  Future<List<Recipe?>> suggestMealPlan({
    required List<Recipe> recipes,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required String globalConstraints,
  }) async {
    if (recipes.isEmpty) return List.filled(slotDates.length, null);

    final gemini = _gemini;
    final suggestions = await gemini.suggestMealPlan(
      recipes: recipes
          .map(
            (r) => {
              'id': r.id,
              'titre': r.titre,
              if (r.tags.prepTime != null) 'prepTime': r.tags.prepTime,
              if (r.tags.cookTime != null) 'cookTime': r.tags.cookTime,
            },
          )
          .toList(),
      slotDates: slotDates.map((d) => d.toIso8601String()).toList(),
      dailyConstraints: {
        for (final e in dailyConstraints.entries)
          e.key: {
            'maxPrepMinutes': e.value.maxPrepMinutes,
            'isBatchCooking': e.value.isBatchCooking,
            'notes': e.value.notes,
          },
      },
      globalConstraints: globalConstraints,
    );

    final recipeById = {for (final r in recipes) r.id: r};
    final result = List<Recipe?>.filled(slotDates.length, null);
    for (final s in suggestions) {
      if (s.slot >= 0 && s.slot < slotDates.length) {
        result[s.slot] = recipeById[s.recipeId];
      }
    }
    return result;
  }
}
