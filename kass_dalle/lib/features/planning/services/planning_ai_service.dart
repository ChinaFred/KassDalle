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

  /// True si la recette a été générée de toutes pièces par l'IA (pas issue du pool existant).
  final bool isGenerated;

  const SlotSuggestion({this.recipe, this.justification, this.prepDate, this.isGenerated = false});
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

  /// Génère une recette de toutes pièces (conception IA) pour un slot.
  ///
  /// Appelé en fallback quand aucune recette existante ne convient.
  /// La recette retournée a [SlotSuggestion.isGenerated] = true.
  /// Le [Recipe.id] est vide — le caller doit la sauvegarder en brouillon.
  Future<SlotSuggestion> generateRecipeConcept({
    required DateTime slotDate,
    required String globalConstraints,
    DayConstraint? dayConstraint,
  }) async {
    final result = await _gemini.generateRecipeConcept(
      slotDate: slotDate.toIso8601String(),
      globalConstraints: globalConstraints,
      dayConstraint: dayConstraint == null
          ? null
          : {
              'maxPrepMinutes': dayConstraint.maxPrepMinutes,
              'isBatchCooking': dayConstraint.isBatchCooking,
              'notes': dayConstraint.notes,
            },
    );
    final now = DateTime.now();
    final recipe = Recipe(
      id: '',
      titre: result.titre,
      langue: 'fr',
      rawCooklang: result.cooklang,
      draftCooklang: result.cooklang,
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: const RecipeTags(),
      ingredientsIndex: const [],
      createdBy: '',
      createdAt: now,
      updatedAt: now,
    );
    return SlotSuggestion(
      recipe: recipe,
      justification: '🤖 Conçu par l\'IA : ${result.justification}',
      isGenerated: true,
    );
  }
}
