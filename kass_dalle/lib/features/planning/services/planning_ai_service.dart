import '../../../../core/services/gemini_service.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_idea.dart';
import '../domain/planning_history.dart';
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

/// Ce que rend une suggestion de cycle : une entrée par créneau, et le nombre
/// de plats récents que la fenêtre de variété a retirés du corpus.
///
/// Ce nombre remonte à l'écran : un plat qu'on ne voit pas proposé doit
/// pouvoir s'expliquer, sinon l'absence passe pour un oubli du modèle.
class MealPlanSuggestion {
  final List<SlotSuggestion> slots;
  final int excludedRecentCount;

  const MealPlanSuggestion({
    required this.slots,
    required this.excludedRecentCount,
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
  ///
  /// [recentlyServed] : les repas servis avant le cycle, dans la fenêtre de
  /// variété. Le serveur les retire du corpus tant qu'il en reste assez, et
  /// rend combien il en a retiré.
  Future<MealPlanSuggestion> suggestMealPlan({
    required List<Recipe> recipes,
    required List<DateTime> slotDates,
    required Map<int, DayConstraint> dailyConstraints,
    required String globalConstraints,
    int? batchCookingDay,
    List<({int slot, String recipeId})> alreadyAssigned = const [],
    List<DayConstraint?>? slotConstraints,
    List<RecentlyServedMeal> recentlyServed = const [],
  }) async {
    if (recipes.isEmpty) {
      return MealPlanSuggestion(
        slots: List.generate(slotDates.length, (_) => const SlotSuggestion()),
        excludedRecentCount: 0,
      );
    }

    final gemini = _gemini;
    final response = await gemini.suggestMealPlan(
      recipes: recipes
          .map(
            (r) => {
              'id': r.id,
              'titre': r.titre,
              if (r.tags.prepTime != null) 'prepTime': r.tags.prepTime,
              if (r.tags.cookTime != null) 'cookTime': r.tags.cookTime,
              if (r.tags.restTime != null) 'restTime': r.tags.restTime,
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
      // La date seule suffit au serveur : il trie du plus récent au plus
      // ancien et cite le jour dans le prompt.
      recentlyServed: recentlyServed
          .map(
            (m) => {
              'recipeId': m.recipeId,
              'titre': m.titre,
              'date': m.servedAt.toIso8601String().substring(0, 10),
            },
          )
          .toList(),
    );
    final suggestions = response.suggestions;

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

    return MealPlanSuggestion(
      slots: result,
      excludedRecentCount: response.excludedRecentIds.length,
    );
  }

  /// Génère une recette de toutes pièces (conception IA) pour un slot.
  ///
  /// Appelé en fallback quand aucune recette existante ne convient.
  /// La recette retournée a [SlotSuggestion.isGenerated] = true.
  /// Le [Recipe.id] est vide — le caller doit la sauvegarder en brouillon.
  /// [alreadyPlanned] : les plats déjà prévus dans le cycle.
  ///
  /// Sans eux, chaque conception est aveugle aux autres : sept appels
  /// indépendants à qui l'on demande « un plat familial » rendent sept fois le
  /// même réflexe, et une consigne de variété que chacun respecte isolément se
  /// solde par six poulets dans la semaine.
  ///
  /// [requestedDish] : le plat déjà choisi — une idée retenue dans « Générer
  /// avec l'IA ». Le modèle rédige cette recette au lieu d'en inventer une.
  Future<SlotSuggestion> generateRecipeConcept({
    required DateTime slotDate,
    required String globalConstraints,
    DayConstraint? dayConstraint,
    List<String> alreadyPlanned = const [],
    MealIdea? requestedDish,
  }) async {
    final result = await _gemini.generateRecipeConcept(
      slotDate: slotDate.toIso8601String(),
      globalConstraints: globalConstraints,
      alreadyPlanned: alreadyPlanned,
      requestedDish: requestedDish == null
          ? null
          : {
              'titre': requestedDish.titre,
              if (requestedDish.description.isNotEmpty)
                'description': requestedDish.description,
            },
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
    // Le modèle rend un CookLang, pas une liste : les ingrédients, les temps
    // et les parts s'en extraient ici. Sans cette lecture, le brouillon
    // s'enregistrait avec un onglet Ingrédients vide et des durées absentes,
    // alors que le texte les portait.
    final cooklang = result.cooklang;
    final ingredients = extractIngredientsStructured(cooklang);
    final now = DateTime.now();
    final recipe = Recipe(
      id: '',
      titre: result.titre,
      langue: 'fr',
      rawCooklang: cooklang,
      draftCooklang: cooklang,
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: extractRecipeTags(cooklang),
      ingredientsIndex: buildIngredientsIndex(ingredients),
      ingredients: ingredients,
      portions: extractPortions(cooklang),
      origin: RecipeOrigin.ai,
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

  /// Trois idées de repas sur une consigne libre.
  ///
  /// Rien n'est conçu ni enregistré : l'idée retenue devient un repas libre.
  /// [previousTitles] transporte les idées déjà rendues, pour que « trois
  /// autres » en rende trois autres. Le serveur peut en rendre moins de trois
  /// quand sa réponse en contenait moins de valides ; l'écran le dit.
  Future<List<MealIdea>> suggestMealIdeas({
    required String prompt,
    String globalConstraints = '',
    List<String> previousTitles = const [],
  }) async {
    final ideas = await _gemini.suggestMealIdeas(
      prompt: prompt,
      globalConstraints: globalConstraints,
      previousTitles: previousTitles,
    );
    return [
      for (final i in ideas)
        MealIdea(
          titre: i.titre,
          description: i.description,
          prepMinutes: i.prepMinutes,
          cookMinutes: i.cookMinutes,
        ),
    ];
  }
}
