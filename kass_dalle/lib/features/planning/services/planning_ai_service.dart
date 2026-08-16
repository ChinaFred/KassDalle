import '../../../../core/services/gemini_service.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/planning_preferences.dart';

/// Résultat d'une suggestion de repas pour un slot donné.
class SlotSuggestion {
  final Recipe? recipe;

  /// Justification de l'IA : critères respectés ou enfreints.
  final String? justification;

  /// True si l'IA indique avoir redimensionné/ajusté la proposition.
  final bool wasResized;

  /// Détail du redimensionnement/ajustement quand [wasResized] est true.
  final String? resizeReason;

  /// Jour de préparation à l'avance (non-null si réchauffage).
  final DateTime? prepDate;

  /// True si la recette a été générée de toutes pièces par l'IA (pas issue du pool existant).
  final bool isGenerated;

  const SlotSuggestion({
    this.recipe,
    this.justification,
    this.wasResized = false,
    this.resizeReason,
    this.prepDate,
    this.isGenerated = false,
  });
}

/// Service d'IA pour la génération de planning de repas via Gemini.
/// Délègue à la Cloud Function `suggestMealPlanFn` via [GeminiService].
class PlanningAiService {
  final GeminiService _gemini;

  const PlanningAiService(this._gemini);

  Map<String, dynamic> _constraintPayload(DayConstraint c) => {
    'maxPrepMinutes': c.maxPrepMinutes,
    'targetPortions': c.targetPortions,
    'isBatchCooking': c.isBatchCooking,
    'notes': c.notes,
  };

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
    List<DayConstraint?>? slotConstraints,
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
              if (r.tags.dishTypes.isNotEmpty) 'dishTypes': r.tags.dishTypes,
              if (r.tags.themes.isNotEmpty) 'themes': r.tags.themes,
              if (r.tags.occasions.isNotEmpty) 'occasions': r.tags.occasions,
              if (r.tags.cuisines.isNotEmpty) 'cuisines': r.tags.cuisines,
              if (r.ingredientsIndex.isNotEmpty)
                'mainIngredients': r.ingredientsIndex.take(8).toList(),
            },
          )
          .toList(),
      slotDates: slotDates.map((d) => d.toIso8601String()).toList(),
      dailyConstraints: {
        for (final e in dailyConstraints.entries)
          e.key: _constraintPayload(e.value),
      },
      slotConstraints: slotConstraints
          ?.map((c) => c == null ? null : _constraintPayload(c))
          .toList(),
      globalConstraints: globalConstraints,
      batchCookingDay: batchCookingDay,
      alreadyAssigned: alreadyAssigned
          .map((a) => {'slot': a.slot, 'recipeId': a.recipeId})
          .toList(),
    );

    // Traduction pure de ce que le serveur a décidé : identifiant → recette.
    //
    // Le client comblait autrefois les créneaux laissés vides, en rejouant les
    // règles de variété, de dessert et de jour de préparation. Ce filet coûtait
    // une duplication entière de ces règles pour un service discutable : il
    // masquait qu'aucune suggestion n'avait été rendue, et une recette choisie
    // par lui s'affichait comme une décision de l'IA. Un créneau vide est plus
    // honnête, et l'écran sait le compléter à la demande.
    final recipeById = {for (final r in recipes) r.id: r};
    final result = List<SlotSuggestion>.generate(
      slotDates.length,
      (_) => const SlotSuggestion(),
    );

    for (final s in suggestions) {
      if (s.slot < 0 || s.slot >= slotDates.length) continue;
      final recipe = recipeById[s.recipeId];
      if (recipe == null) continue;
      result[s.slot] = SlotSuggestion(
        recipe: recipe,
        justification: s.justification,
        wasResized: s.resized,
        resizeReason: s.resizeReason,
        prepDate: s.prepDate != null ? DateTime.tryParse(s.prepDate!) : null,
      );
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
              'targetPortions': dayConstraint.targetPortions,
              'isBatchCooking': dayConstraint.isBatchCooking,
              'notes': dayConstraint.notes,
            },
    );
    // Un CookLang vide donnerait un brouillon sans un seul ingrédient : mieux
    // vaut un créneau resté vide qu'une recette fantôme enregistrée en base.
    if (result.cooklang.trim().isEmpty) {
      return SlotSuggestion(
        justification: result.justification,
        isGenerated: true,
      );
    }
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
      wasResized: false,
      isGenerated: true,
    );
  }
}
