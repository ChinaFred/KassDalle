import '../../../../core/services/gemini_service.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/planning_preferences.dart';

/// Résultat d'une suggestion de repas pour un slot donné.
class SlotSuggestion {
  final Recipe? recipe;
  /// Justification de l'IA : critères respectés ou enfreints.
  final String? justification;
  /// Jour de préparation à l'avance (non-null si réchauffage).
  final DateTime? prepDate;

  const SlotSuggestion({this.recipe, this.justification, this.prepDate});
}

/// Service d'IA pour la génération de planning de repas via Gemini.
/// Délègue à la Cloud Function `suggestMealPlanFn` via [GeminiService].
class PlanningAiService {
  final GeminiService _gemini;

  const PlanningAiService(this._gemini);

  /// Suggère un planning de repas pour les [slotDates] données.
  ///
  /// Retourne une liste de la même taille que [slotDates].
  /// Chaque entrée contient la recette suggérée, une justification et
  /// éventuellement un jour de préparation à l'avance.
  Future<List<SlotSuggestion>> suggestMealPlan({
    required List<Recipe> recipes,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required String globalConstraints,
    int? batchCookingDay,
    List<({int slot, String recipeId})> alreadyAssigned = const [],
  }) async {
    if (recipes.isEmpty) {
      return List.generate(slotDates.length, (_) => const SlotSuggestion());
    }

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
      batchCookingDay: batchCookingDay,
      alreadyAssigned: alreadyAssigned
          .map((a) => {'slot': a.slot, 'recipeId': a.recipeId})
          .toList(),
    );

    final recipeById = {for (final r in recipes) r.id: r};
    final result = List<SlotSuggestion>.generate(
      slotDates.length,
      (_) => const SlotSuggestion(),
    );
    for (final s in suggestions) {
      if (s.slot >= 0 && s.slot < slotDates.length) {
        final recipe = recipeById[s.recipeId];
        final prepDate = s.prepDate != null
            ? DateTime.tryParse(s.prepDate!)
            : null;
        result[s.slot] = SlotSuggestion(
          recipe: recipe,
          justification: s.justification,
          prepDate: prepDate,
        );
      }
    }
    return result;
  }
}
