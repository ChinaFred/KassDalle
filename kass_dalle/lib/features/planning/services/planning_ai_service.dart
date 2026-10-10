import '../../../../core/services/gemini_service.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_choice_source.dart';
import '../domain/meal_idea.dart';
import '../domain/planning_history.dart';
import '../domain/planning_preferences.dart';
import '../domain/ranked_candidates.dart';

/// Résultat d'une suggestion de repas pour un slot donné.
class SlotSuggestion {
  final Recipe? recipe;

  /// Faits produits par le serveur (protéine, durée, note, dernier service),
  /// ou la justification d'une conception. Jamais une phrase générique.
  final String? justification;

  /// Vrai quand les parts servies diffèrent de celles de la recette :
  /// calculé par le serveur, recalculé à l'affichage, jamais écrit dans la
  /// recette.
  final bool wasResized;

  /// « Écrite pour 4 parts, servie pour 6. »
  final String? resizeReason;

  /// Jour de préparation à l'avance (non-null si réchauffage).
  final DateTime? prepDate;

  /// True si la recette a été générée de toutes pièces par l'IA (pas issue du pool existant).
  final bool isGenerated;

  /// L'entrée et le dessert rendus par le même appel, quand le format du
  /// créneau en demande. Le serveur ne les rend que parmi les recettes de ce
  /// rôle, une fois chacune dans le cycle.
  final Recipe? starter;
  final Recipe? dessert;

  /// Qui a choisi : l'IA, les règles de Kass'Dalle, ou une conception IA.
  final MealChoiceSource source;

  /// Vrai si la recette n'est proposée que faute d'autre choix.
  final bool repeat;

  const SlotSuggestion({
    this.recipe,
    this.justification,
    this.wasResized = false,
    this.resizeReason,
    this.prepDate,
    this.isGenerated = false,
    this.starter,
    this.dessert,
    this.source = MealChoiceSource.ai,
    this.repeat = false,
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

  /// Génération à laquelle rattacher les conceptions automatiques.
  final String? runId;

  /// `ok`, `partial`, `failed`, `budget` ou `skipped`.
  final String modelStatus;

  /// Phrase du serveur à afficher quand le modèle n'a pas choisi.
  final String? notice;

  /// Listes classées, par index de créneau de la demande.
  final Map<int, SlotRanking> rankings;

  /// Conceptions encore permises pour cette génération.
  final int conceptsRemaining;

  const MealPlanSuggestion({
    required this.slots,
    required this.excludedRecentCount,
    this.runId,
    this.modelStatus = 'skipped',
    this.notice,
    this.rankings = const {},
    this.conceptsRemaining = 0,
  });

  /// Le modèle n'a pas choisi : panne ou plafond. L'écran affiche [notice].
  bool get modelUnavailable =>
      modelStatus == 'failed' || modelStatus == 'budget';
}

/// Résumé d'une recette envoyé au serveur pour la présélection.
Map<String, dynamic> planningRecipeSummary(Recipe r) => {
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
  // Le rôle range la recette dans la bonne liste : plats, entrées,
  // desserts. Absent, elle est un plat.
  if (r.tags.hasMealRole) 'mealRole': r.tags.mealRole,
  // Les parts de la recette : le serveur dit si le repas sera redimensionné.
  if (r.portions != null && r.portions! > 0) 'portions': r.portions,
};

/// Service d'IA pour la génération de planning de repas via Gemini.
/// Délègue à la Cloud Function `suggestMealPlanFn` via [GeminiService].
class PlanningAiService {
  final GeminiService _gemini;

  const PlanningAiService(this._gemini);

  /// Plafond serveur des écarts envoyés par créneau (`_aiInputReaders.ts`).
  static const int _maxDismissedPerSlot = 30;

  static List<String> _lastDismissed(Iterable<String> ids) {
    final list = ids.toList();
    return list.length <= _maxDismissedPerSlot
        ? list
        : list.sublist(list.length - _maxDismissedPerSlot);
  }

  Map<String, dynamic> _constraintPayload(DayConstraint c) => {
    'maxPrepMinutes': c.maxPrepMinutes,
    'targetPortions': c.targetPortions,
    'isBatchCooking': c.isBatchCooking,
    'notes': c.notes,
    // Le format décide si le serveur demande une entrée ou un dessert ;
    // absent, c'est le plat seul.
    if (c.mealFormat != null) 'mealFormat': c.mealFormat!.key,
  };

  /// Suggère un planning de repas pour les [slotDates] données.
  ///
  /// Retourne une liste de la même taille que [slotDates]. Le serveur
  /// présélectionne les candidats de chaque créneau, puis le modèle tranche
  /// entre les têtes de liste. [withoutModel] : présélection seule, sans
  /// appel de modèle ni coût. [slotDismissed] : les recettes écartées de
  /// chaque créneau, même index que [slotDates].
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
    bool withoutModel = false,
    List<Set<String>?>? slotDismissed,
  }) async {
    // Un corpus vide part quand même : le serveur ouvre la génération à
    // laquelle se rattachent les conceptions, et leur plafond.
    final response = await _gemini.suggestMealPlan(
      recipes: recipes.map(planningRecipeSummary).toList(),
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
      // « Autre suggestion » sans liste en main : la présélection seule, sans
      // appel de modèle.
      mode: withoutModel ? 'code' : null,
      // Le serveur refuse plus de 30 écarts par créneau : on envoie les 30
      // derniers. Sur un créneau isolé, `recipes` exclut déjà tous les écarts
      // (`candidatesForMeal`) ; sur un cycle entier, un écart plus ancien que
      // les 30 derniers peut revenir sur ce créneau.
      slotDismissed: slotDismissed
          ?.map((d) => d == null || d.isEmpty ? null : _lastDismissed(d))
          .toList(),
    );

    // Traduction pure de ce que le serveur a décidé : identifiant → recette.
    // Un créneau que le serveur laisse vide reste vide : l'écran le dit et
    // propose de le compléter.
    final recipeById = {for (final r in recipes) r.id: r};
    final result = List<SlotSuggestion>.generate(
      slotDates.length,
      (_) => const SlotSuggestion(),
    );

    for (final s in response.suggestions) {
      if (s.slot < 0 || s.slot >= slotDates.length) continue;
      final recipe = recipeById[s.recipeId];
      if (recipe == null) continue;
      result[s.slot] = SlotSuggestion(
        recipe: recipe,
        justification: s.justification,
        wasResized: s.resized,
        resizeReason: s.resizeReason,
        prepDate: s.prepDate != null ? DateTime.tryParse(s.prepDate!) : null,
        // Une entrée ou un dessert que le corpus ne connaît pas est ignoré :
        // le serveur ne les rend qu'en identifiants, jamais en titres.
        starter: s.starterId == null ? null : recipeById[s.starterId!],
        dessert: s.dessertId == null ? null : recipeById[s.dessertId!],
        source: MealChoiceSource.fromServer(s.source),
        repeat: s.repeat,
      );
    }

    final rankings = <int, SlotRanking>{};
    for (final raw in response.rankedCandidates) {
      final slot = raw['slot'];
      if (slot is! num) continue;
      final index = slot.toInt();
      if (index < 0 || index >= slotDates.length) continue;
      rankings[index] = SlotRanking.fromMap(raw);
    }

    return MealPlanSuggestion(
      slots: result,
      excludedRecentCount: response.excludedRecentIds.length,
      runId: response.runId,
      modelStatus: response.modelStatus,
      notice: response.notice,
      rankings: rankings,
      conceptsRemaining: response.conceptsRemaining,
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
    String? runId,
  }) async {
    final result = await _gemini.generateRecipeConcept(
      runId: runId,
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
        source: MealChoiceSource.concept,
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
    // L'origine (« Conçue par l'IA ») s'affiche sur sa propre ligne : la
    // justification ne la répète pas.
    return SlotSuggestion(
      recipe: recipe,
      justification: result.justification,
      wasResized: false,
      isGenerated: true,
      source: MealChoiceSource.concept,
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
