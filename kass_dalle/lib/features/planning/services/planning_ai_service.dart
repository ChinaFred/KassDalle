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

  String _slotKindFor({
    required int slot,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required int? batchCookingDay,
  }) {
    final date = slotDates[slot];
    final constraint = dailyConstraints[date.weekday];
    final isBatchCookingDay =
        batchCookingDay != null && date.weekday == batchCookingDay;
    if (isBatchCookingDay) return 'batch';
    if (constraint?.isBatchCooking ?? false) return 'reheat';
    return 'regular';
  }

  DateTime _computePrepDate(DateTime slotDate, int batchCookingWeekday) {
    var daysBack = (slotDate.weekday - batchCookingWeekday + 7) % 7;
    if (daysBack == 0) daysBack = 7;
    return DateTime.utc(
      slotDate.year,
      slotDate.month,
      slotDate.day,
    ).subtract(Duration(days: daysBack));
  }

  bool _fitsSlot({
    required Recipe recipe,
    required String slotKind,
    required DayConstraint? constraint,
  }) {
    if (slotKind == 'reheat') return true;
    if (slotKind == 'batch') return true;
    final maxPrepMinutes = constraint?.maxPrepMinutes ?? 0;
    if (maxPrepMinutes <= 0) return true;
    final prepTime = recipe.tags.prepTime;
    if (prepTime == null) return true;
    return prepTime <= maxPrepMinutes;
  }

  Recipe? _pickFallbackRecipe({
    required int slot,
    required List<Recipe> recipes,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required int? batchCookingDay,
    required Set<String> blockedRecipeIds,
  }) {
    final slotKind = _slotKindFor(
      slot: slot,
      slotDates: slotDates,
      dailyConstraints: dailyConstraints,
      batchCookingDay: batchCookingDay,
    );
    final constraint = dailyConstraints[slotDates[slot].weekday];

    final freshCandidates = recipes.where((recipe) {
      if (!_fitsSlot(recipe: recipe, slotKind: slotKind, constraint: constraint)) {
        return false;
      }
      return !blockedRecipeIds.contains(recipe.id);
    }).toList();

    final fallbackCandidates = recipes.where((recipe) {
      return _fitsSlot(recipe: recipe, slotKind: slotKind, constraint: constraint);
    }).toList();

    int compareRecipes(Recipe a, Recipe b) {
      final aPrep = a.tags.prepTime ?? 9999;
      final bPrep = b.tags.prepTime ?? 9999;
      return aPrep.compareTo(bPrep);
    }

    freshCandidates.sort(compareRecipes);
    fallbackCandidates.sort(compareRecipes);

    if (freshCandidates.isNotEmpty) return freshCandidates.first;
    return fallbackCandidates.isEmpty ? null : fallbackCandidates.first;
  }

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
              if (r.tags.dishTypes.isNotEmpty) 'dishTypes': r.tags.dishTypes,
              if (r.tags.themes.isNotEmpty) 'themes': r.tags.themes,
              if (r.tags.cuisines.isNotEmpty) 'cuisines': r.tags.cuisines,
              if (r.ingredientsIndex.isNotEmpty)
                'mainIngredients': r.ingredientsIndex.take(8).toList(),
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
    // Le backend applique deja la logique principale de variete. Ici on garde
    // surtout un filet de securite pour completer les slots oublies.
    final result = List<SlotSuggestion>.generate(
      slotDates.length,
      (_) => const SlotSuggestion(),
    );
    final blockedRecipeIds = <String>{
      ...alreadyAssigned.map((a) => a.recipeId),
    };
    final assignedRecipeIdsBySlot = <int, String>{};
    for (final s in suggestions) {
      if (s.slot >= 0 && s.slot < slotDates.length) {
        final recipe = recipeById[s.recipeId];
        if (recipe == null) {
          continue;
        }
        final prepDate = s.prepDate != null
            ? DateTime.tryParse(s.prepDate!)
            : null;
        result[s.slot] = SlotSuggestion(
          recipe: recipe,
          justification: s.justification,
          wasResized: s.resized,
          resizeReason: s.resizeReason,
          prepDate: prepDate,
        );

        final slotKind = _slotKindFor(
          slot: s.slot,
          slotDates: slotDates,
          dailyConstraints: dailyConstraints,
          batchCookingDay: batchCookingDay,
        );
        assignedRecipeIdsBySlot[s.slot] = recipe.id;
        if (slotKind != 'reheat') {
          blockedRecipeIds.add(recipe.id);
        }
      }
    }

    for (int slot = 0; slot < slotDates.length; slot++) {
      if (result[slot].recipe != null) continue;

      final slotKind = _slotKindFor(
        slot: slot,
        slotDates: slotDates,
        dailyConstraints: dailyConstraints,
        batchCookingDay: batchCookingDay,
      );
      final recipe = _pickFallbackRecipe(
        slot: slot,
        recipes: recipes,
        slotDates: slotDates,
        dailyConstraints: dailyConstraints,
        batchCookingDay: batchCookingDay,
        blockedRecipeIds: blockedRecipeIds,
      );
      if (recipe == null) {
        continue;
      }

      DateTime? prepDate;
      if (slotKind == 'reheat' && batchCookingDay != null) {
        prepDate = _computePrepDate(slotDates[slot], batchCookingDay);
      }

      result[slot] = SlotSuggestion(
        recipe: recipe,
        justification:
            'Complément automatique : Gemini n\'a pas rempli ce créneau, une recette compatible restante a été sélectionnée.',
        wasResized: false,
        prepDate: prepDate,
      );

      assignedRecipeIdsBySlot[slot] = recipe.id;
      if (slotKind != 'reheat') {
        blockedRecipeIds.add(recipe.id);
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
      wasResized: false,
      isGenerated: true,
    );
  }
}
