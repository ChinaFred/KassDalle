import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/detail/shopping_list_sheet.dart';
import '../domain/planning_history.dart';
import '../../recipes/domain/recipe_advice_access.dart';
import '../../recipes/domain/storage_advice.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/calendar_event_description.dart';
import '../domain/meal_candidates.dart';
import '../domain/meal_choice_source.dart';
import '../domain/planning_refusals.dart';
import '../domain/meal_component.dart';
import '../domain/meal_idea.dart';
import '../domain/meal_recipe_location.dart';
import '../domain/side_chooser.dart';
import 'meal_staples_providers.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../domain/planning_week.dart';
import '../services/calendar_service.dart';
import 'planning_period_calendar.dart';
import 'planning_providers.dart';
import 'planning_widgets.dart';
import 'recipe_picker_sheet.dart';
import 'side_picker_sheet.dart';
import 'storage_advice_sheet.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_service.dart'
    show GeminiCallableException;
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';

/// Choix proposé quand « Autre suggestion » n'a plus de recette.
enum _ExhaustedChoice { pick, conceive }

class PlanningScreen extends ConsumerStatefulWidget {
  const PlanningScreen({super.key});

  @override
  ConsumerState<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends ConsumerState<PlanningScreen> {
  List<Recipe> _availableRecipes = [];
  bool _recipesLoaded = false;
  final Set<String> _aiLoadingIds = {};
  final Set<String> _storageLoadingIds = {};

  /// Période lue : une semaine du cycle touchée dans le calendrier, ou une
  /// période libre.
  ///
  /// Null tant qu'on n'a rien choisi : c'est alors la semaine du cycle qui
  /// contient aujourd'hui, recalculée à chaque construction — le jour de
  /// démarrage du cycle vient des préférences, qui peuvent arriver après le
  /// premier affichage.
  ///
  /// Elle vit dans l'état de l'écran et nulle part ailleurs : choisir une
  /// période à regarder n'est pas une donnée du planning, et chaque ouverture
  /// repart de la semaine en cours.
  PlanningPeriod? _chosenPeriod;

  /// Premier jour d'une période libre en cours de choix, ou null.
  DateTime? _rangeStart;

  /// État replié ou déplié du calendrier avant l'appui long, rendu par
  /// « Annuler ».
  bool _expandedBeforeRange = false;

  /// Mois affiché quand le calendrier est déplié.
  DateTime _visibleMonth = PlanningPeriodCalendar.monthOf(DateTime.now());

  /// Calendrier déplié sur un téléphone. Il s'ouvre replié : la liste des
  /// repas est ce qu'on lit, le mois sert à aller ailleurs.
  bool _calendarExpanded = false;

  /// État du bouton « Nouveau planning » sur un téléphone : réduit à son
  /// icône dès qu'on a fait défiler la liste, masqué pendant qu'on descend.
  /// Étendu en permanence, il couvrait les actions des repas.
  bool _fabCompact = false;
  bool _fabHidden = false;

  /// Une clé par jour de la période lue, pour y amener la liste quand on
  /// touche ce jour dans le bandeau.
  final Map<DateTime, GlobalKey> _dayKeys = {};

  /// Mois d'archive déjà lus, et ceux en cours de lecture.
  ///
  /// Le flux temps réel s'arrête à quatre-vingt-dix jours — sans cette borne,
  /// l'écran relit à chaque ouverture la totalité des repas jamais planifiés,
  /// et la facture de lectures ne fait que croître. Les repas plus anciens
  /// existent pourtant toujours : rien ne les efface. Ils se lisent donc **à la
  /// demande**, un mois à la fois, quand on va les chercher — et une seule fois
  /// par mois visité.
  final Map<DateTime, List<PlannedMeal>> _archive = {};
  final Set<DateTime> _archiveLoading = {};

  /// Profondeur d'historique consultable dans le calendrier.
  ///
  /// Deux ans : assez pour retrouver ce qu'on cuisinait l'été dernier, assez
  /// court pour que la navigation vers le passé ait une fin. Sans borne, la
  /// flèche continuerait indéfiniment sur des mois vides.
  static const _archiveDepth = Duration(days: 730);

  Future<void> _loadRecipesIfNeeded() async {
    if (_recipesLoaded) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    try {
      final recipes = await repo.getValidatedRecipes();
      if (mounted) {
        setState(() {
          _availableRecipes = recipes;
          _recipesLoaded = true;
        });
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.loadRecipes',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Impossible de charger les recettes : $e');
      }
    }
  }

  /// La recette que [meal] perd si [newRecipeId] la remplace, ou null si le
  /// repas n'en avait pas ou garde la même. Elle rejoint les recettes écartées
  /// du repas, que l'IA ne repropose plus.
  String? _oustedBy(PlannedMeal meal, String? newRecipeId) {
    final current = meal.recipeId;
    if (current == null || current.isEmpty || current == newRecipeId) {
      return null;
    }
    return current;
  }

  /// La recette remplacée sur [meal] compte comme un refus si elle avait été
  /// proposée (IA, règles, conception) et non choisie à la main. Appelé par
  /// « Autre suggestion », « Changer la recette » et la conception qui
  /// remplace ; pas par « Remettre à blanc ». Jamais bloquant.
  void _recordRefusal(PlannedMeal meal, String? newRecipeId) {
    final ousted = _oustedBy(meal, newRecipeId);
    final uid = ref.read(planningRepositoryProvider)?.uid;
    if (ousted == null || uid == null) return;
    if (!countsAsRefusal(meal.choiceSource)) return;
    unawaited(
      ref.read(planningRefusalsRepositoryProvider).record(uid, [ousted]),
    );
  }

  /// Les accompagnements que le programme pose sur [recipe] — féculent et
  /// légume, quand le plat n'apporte ni l'un ni l'autre —, depuis les
  /// garnitures du compte et les recettes d'accompagnement chargées.
  ///
  /// Rien tant que les garnitures ne sont pas lues : mieux vaut un repas sans
  /// accompagnement qu'un accompagnement au hasard.
  List<MealComponent> _composeComponents(Recipe recipe) {
    final staples = ref.read(myStaplesProvider).value;
    if (staples == null) return const [];
    final choices = chooseSides(
      main: recipe,
      candidates: sideCandidatesFrom(
        staples: staples,
        recipes: _availableRecipes,
      ),
    );
    return [for (final c in choices) c.component];
  }

  /// Recette validée dont l'identifiant est [id], ou rien si elle n'est pas
  /// chargée — un repas peut pointer une recette de la famille, absente des
  /// recettes validées du compte.
  Recipe? _validatedRecipeById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final r in _availableRecipes) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Ajoute un accompagnement de plus à la main, en plus de ceux déjà posés.
  Future<void> _addComponent(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final main = _validatedRecipeById(meal.recipeId);
    if (main == null) {
      context.showSnackBar('Recette introuvable pour ce repas.');
      return;
    }
    final staples = ref.read(myStaplesProvider).value ?? const [];
    final result = await showModalBottomSheet<SidePickerResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SidePickerSheet(
        main: main,
        candidates: sideCandidatesFrom(
          staples: staples,
          recipes: _availableRecipes,
        ),
      ),
    );
    if (result == null || result.isNone || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    await repo?.updateMealComponents(meal.id, [
      ...meal.components,
      result.candidate!.toComponent(justification: 'Choisi à la main.'),
    ]);
  }

  /// Retire un accompagnement déjà posé sur ce repas, auto ou choisi à la
  /// main.
  Future<void> _removeComponent(PlannedMeal meal, MealComponent component) {
    final repo = ref.read(planningRepositoryProvider);
    final updated = meal.components
        .where((c) => !identical(c, component))
        .toList();
    return repo?.updateMealComponents(meal.id, updated) ?? Future.value();
  }

  /// Trois idées de repas sur une consigne, pour « Générer avec l'IA » du
  /// sélecteur. Les préférences générales du planning partent avec la
  /// consigne ; rien n'est conçu ni enregistré.
  Future<List<MealIdea>> _generateMealIdeas({
    required String prompt,
    required List<String> previousTitles,
  }) {
    final prefs =
        ref.read(planningPreferencesProvider).value ??
        const PlanningPreferences();
    return ref
        .read(planningAiServiceProvider)
        .suggestMealIdeas(
          prompt: prompt,
          globalConstraints: prefs.globalConstraints,
          previousTitles: previousTitles,
        );
  }

  /// Rédige la recette d'une idée retenue, comme « Conception IA » de Nouveau
  /// planning, et l'enregistre en brouillon dans « Mes créations Kass'Dalle ».
  ///
  /// En brouillon, comme toute recette créée par l'IA : elle s'ouvre depuis le
  /// repas et entre dans les courses comme une recette validée, et se relit
  /// avant de rejoindre la bibliothèque. [on] est le jour du repas, dont les
  /// contraintes cadrent la rédaction.
  Future<Recipe> _conceiveMealIdea(
    MealIdea idea, {
    required DateTime on,
  }) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) throw StateError('Utilisateur non connecté.');
    final prefs =
        ref.read(planningPreferencesProvider).value ??
        const PlanningPreferences();
    final dayConstraint = prefs.dailyConstraints[on.weekday];
    final suggestion = await ref
        .read(planningAiServiceProvider)
        .generateRecipeConcept(
          slotDate: on,
          globalConstraints: prefs.globalConstraints,
          dayConstraint: dayConstraint == null || dayConstraint.isEmpty
              ? null
              : dayConstraint,
          requestedDish: idea,
        );
    final recipe = suggestion.recipe;
    if (recipe == null) {
      throw StateError(
        suggestion.justification ?? 'L\'IA n\'a pas rendu de recette.',
      );
    }
    final id = await repo.saveAsDraft(recipe);
    // La recette telle qu'enregistrée : l'identifiant, le statut, le livre.
    // `copyWith` ne prend pas d'identifiant ; on la reconstruit avec tout ce
    // que le repas et les courses liront (durées, parts, ingrédients).
    return Recipe(
      id: id,
      titre: recipe.titre,
      langue: recipe.langue,
      rawCooklang: recipe.rawCooklang,
      draftCooklang: recipe.draftCooklang,
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      ingredients: recipe.ingredients,
      portions: recipe.portions,
      origin: RecipeOrigin.ai,
      createdBy: repo.uid,
      createdAt: recipe.createdAt,
      updatedAt: recipe.updatedAt,
    );
  }

  Future<void> _changeRecipe(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final canCreate = ref.read(canEditProvider);
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: _availableRecipes,
        dismissedRecipeIds: meal.dismissedRecipeIds.toSet(),
        hintText: 'Rechercher ou saisir un nom libre\u2026',
        freeNameAlways: true,
        // « Générer avec l'IA » mène à une recette enregistrée : le lecteur,
        // qui ne crée pas de recette, ne la voit pas.
        onGenerateIdeas: canCreate ? _generateMealIdeas : null,
        onConceiveIdea: canCreate
            ? (idea) => _conceiveMealIdea(idea, on: meal.plannedAt)
            : null,
      ),
    );
    if (recipe == null || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    final prepMinutes = recipe.tags.prepTime;
    final cookMinutes = recipe.tags.cookTime;
    final duration = (prepMinutes ?? 0) + (cookMinutes ?? 0);
    await repo?.updateMealRecipe(
      meal.id,
      recipeId: recipe.id.isEmpty ? null : recipe.id,
      recipeTitre: recipe.titre,
      durationMinutes: duration,
      prepMinutes: prepMinutes,
      cookMinutes: cookMinutes,
      basePortions: recipe.portions,
      targetPortions: meal.targetPortions ?? recipe.portions,
      dismissRecipeId: _oustedBy(meal, recipe.id),
      // Un autre plat, un autre accompagnement.
      components: _composeComponents(recipe),
      choiceSource: MealChoiceSource.manual,
    );
    _recordRefusal(meal, recipe.id.isEmpty ? null : recipe.id);
  }

  Future<void> _changeTime(PlannedMeal meal) async {
    final initial = TimeOfDay.fromDateTime(meal.plannedAt);
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null || !mounted) return;
    final newTime = DateTime(
      meal.plannedAt.year,
      meal.plannedAt.month,
      meal.plannedAt.day,
      t.hour,
      t.minute,
    );
    final repo = ref.read(planningRepositoryProvider);
    await repo?.updateMealTime(meal.id, newTime);
  }

  Future<void> _rescheduleMeal(PlannedMeal meal) async {
    final today = DateTime(
      DateTime.now().year,
      DateTime.now().month,
      DateTime.now().day,
    );
    final mealDay = DateTime(
      meal.plannedAt.year,
      meal.plannedAt.month,
      meal.plannedAt.day,
    );
    final picked = await showDatePicker(
      context: context,
      initialDate: mealDay,
      firstDate: mealDay.isBefore(today) ? mealDay : today,
      lastDate: today.add(const Duration(days: 730)),
    );
    if (picked == null || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    await repo?.rescheduleMeal(meal, picked);
  }

  Future<void> _exportAllToCalendar(List<PlannedMeal> meals) async {
    final now = DateTime.now();
    final futureMeals = meals
        .where(
          (m) => !m.plannedAt.isBefore(DateTime(now.year, now.month, now.day)),
        )
        .toList();
    if (futureMeals.isEmpty) {
      if (mounted) {
        context.showSnackBar('Aucun repas futur à exporter.');
      }
      return;
    }
    // Récupérer le token UNE SEULE FOIS pour éviter un popup OAuth par événement.
    final String token;
    try {
      token = await CalendarService.getToken();
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.exportAllToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Autorisation Calendar refusée : $e');
      }
      return;
    }
    final prefs = ref.read(planningPreferencesProvider).value;
    final calendarId = prefs?.calendarId ?? 'primary';
    final defaultDuration = prefs?.defaultCalendarDurationMinutes ?? 60;
    int exported = 0;
    for (final meal in futureMeals) {
      try {
        await CalendarService.createEvent(
          titre: meal.recipeTitre,
          startTime: meal.plannedAt,
          duration: Duration(minutes: defaultDuration),
          description: mealCalendarDescription(meal),
          reminderMinutes: meal.prepMinutes ?? 0,
          calendarId: calendarId,
          token: token,
        );
        exported++;
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'planningScreen.exportAllToCalendar',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (mounted) {
      context.showSnackBar('$exported repas exportés vers le calendrier ✓');
    }
  }

  Future<void> _exportMealToCalendar(PlannedMeal meal) async {
    final prefs = ref.read(planningPreferencesProvider).value;
    final calendarId = prefs?.calendarId ?? 'primary';
    final defaultDuration = prefs?.defaultCalendarDurationMinutes ?? 60;
    try {
      await CalendarService.createEvent(
        titre: meal.recipeTitre,
        startTime: meal.plannedAt,
        duration: Duration(minutes: defaultDuration),
        description: mealCalendarDescription(meal),
        reminderMinutes: meal.prepMinutes ?? 0,
        calendarId: calendarId,
      );
      if (mounted) {
        context.showSnackBar('Repas ajouté au calendrier ✓');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.exportMealToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Erreur : $e');
      }
    }
  }

  /// La période lue : celle choisie, ou la semaine du cycle qui contient
  /// aujourd'hui.
  PlanningPeriod _period(DateTime today) {
    final cycleStartDay =
        ref.read(planningPreferencesProvider).value?.cycleStartDay ??
        DateTime.friday;
    return _chosenPeriod ?? planningWeekOf(today, cycleStartDay: cycleStartDay);
  }

  /// La période que la liste de courses couvre : celle qu'on est en train de
  /// lire.
  PlanningPeriod? _shoppingWeek(DateTime today) => _period(today);

  Future<void> _showIngredientsList(List<PlannedMeal> meals) async {
    final today = DateTime.now();
    final week = _shoppingWeek(today);
    // Les courses ne concernent que ce qui reste à cuisiner, dans la période lue.
    final upcoming = mealsToShop(meals, today: today, week: week);
    if (upcoming.isEmpty) {
      if (mounted) {
        context.showSnackBar(
          week == null
              ? 'Aucun repas à venir dans le planning.'
              : 'Aucun repas à venir sur cette période.',
        );
      }
      return;
    }
    // Résoudre par identifiant : un repas peut pointer sur un brouillon ou une
    // recette de la famille, absente des recettes validées de l'utilisateur.
    final repo = ref.read(planningRepositoryProvider);
    // Les plats, et les recettes d'accompagnement des repas : une garniture
    // avec recette se compte comme le plat qu'elle accompagne.
    final ids = <String>[
      for (final m in upcoming) ...[
        if (m.recipeId != null) m.recipeId!,
        for (final c in m.components)
          if (c.isRecipe) c.recipeId!,
      ],
    ];
    final List<Recipe> resolved;
    try {
      resolved = await repo?.getRecipesByIds(ids) ?? const [];
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.showIngredientsList',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Impossible de charger les recettes : $e');
      }
      return;
    }
    if (!mounted) return;
    final recipesById = {for (final r in resolved) r.id: r};
    final missing = <String>[];
    final planningRecipes = <Recipe>[];
    // Les garnitures, multipliées par les parts du repas ; elles se fondent
    // dans les lignes des recettes — le riz d'une garniture et le riz d'une
    // recette font une seule ligne de courses.
    final extras = <PlanningExtraProduct>[];
    for (final meal in upcoming) {
      // Les composants d'abord : ils comptent même quand le plat est un repas
      // libre, sans recette.
      for (final c in meal.components) {
        if (c.isStaple) {
          final total = c.totalQuantityFor(meal.portionsForComponents);
          if (total == null) continue;
          extras.add((
            product: RecipeShoppingProduct(
              name: c.effectiveShoppingProduct,
              qty: total == total.truncateToDouble()
                  ? total.toInt().toString()
                  : total.toStringAsFixed(1),
              unit: c.unit ?? 'g',
            ),
            source: '${meal.recipeTitre} · ${c.role.label.toLowerCase()}',
          ));
        } else if (c.isRecipe) {
          final side = recipesById[c.recipeId!];
          if (side == null) {
            missing.add(c.label);
            continue;
          }
          planningRecipes.add(
            planningScaleRecipeForMeal(
              recipe: side,
              basePortions: side.portions,
              targetPortions: meal.portionsForComponents,
            ),
          );
        }
      }
      final recipeId = meal.recipeId;
      if (recipeId == null) continue;
      final recipe = recipesById[recipeId];
      if (recipe == null) {
        missing.add(meal.recipeTitre);
        continue;
      }
      planningRecipes.add(
        planningScaleRecipeForMeal(
          recipe: recipe,
          basePortions: meal.basePortions,
          targetPortions: meal.targetPortions,
        ),
      );
    }
    if (planningRecipes.isEmpty && extras.isEmpty) {
      if (mounted) {
        context.showSnackBar(
          'Aucune recette avec ingrédients dans le planning.',
        );
      }
      return;
    }
    // Une recette introuvable ne doit pas disparaître sans un mot : sinon la
    // liste paraît complète alors qu'il y manque un repas entier.
    if (missing.isNotEmpty) {
      context.showSnackBar(
        'Recette introuvable, ingrédients non comptés : ${missing.join(', ')}',
      );
    }
    final aggregated = planningAggregateProducts(
      planningRecipes,
      extras: extras,
    );
    final uid = ref.read(planningRepositoryProvider)?.uid ?? '';
    if (!mounted) return;
    await showShoppingListSheet(
      context,
      aggregated.products,
      const [],
      'Planning',
      uid,
      ingredientSources: aggregated.sources,
    );
  }

  Future<void> _clearRecipe(PlannedMeal meal) async {
    final repo = ref.read(planningRepositoryProvider);
    await repo?.updateMealRecipe(
      meal.id,
      recipeId: null,
      recipeTitre: 'Repas libre',
      durationMinutes: 0,
      clearPortions: true,
      dismissRecipeId: _oustedBy(meal, null),
      // Sans plat, pas d'accompagnement, ni d'origine ni de faits : un repas
      // libre n'affiche pas « Choisie par vous ».
      components: const [],
      clearChoice: true,
    );
  }

  /// « Autre suggestion » : la recette suivante pour ce jour, tirée par la
  /// présélection du serveur, sans appel de modèle ni coût.
  ///
  /// La recette en place et celles déjà écartées de ce repas ne reviennent
  /// pas. Liste épuisée : l'écran le dit et propose de choisir une recette ou
  /// de la concevoir avec l'IA.
  Future<void> _otherSuggestion(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final candidates = candidatesForMeal(
      _availableRecipes,
      currentRecipeId: meal.recipeId,
      dismissedRecipeIds: meal.dismissedRecipeIds,
    );
    if (candidates.isEmpty) {
      await _offerWhenExhausted(meal);
      return;
    }
    setState(() => _aiLoadingIds.add(meal.id));
    try {
      final prefs =
          ref.read(planningPreferencesProvider).value ??
          const PlanningPreferences();
      // La fenêtre de variété regarde les repas servis avant ce jour-là, lus
      // dans ce que l'écran affiche déjà : aucune lecture de plus.
      final recentlyServed = recentlyServedBefore(
        ref.read(plannedMealsProvider).value ?? const [],
        cycleStart: meal.plannedAt,
        windowWeeks: prefs.varietyWindowWeeks,
      );
      final result = await ref
          .read(planningAiServiceProvider)
          .suggestMealPlan(
            recipes: candidates,
            slotDates: [meal.plannedAt],
            dailyConstraints: prefs.dailyConstraints,
            globalConstraints: prefs.globalConstraints,
            batchCookingDay: prefs.batchCookingDay,
            recentlyServed: recentlyServed,
            withoutModel: true,
            slotDismissed: [
              {...meal.dismissedRecipeIds, ?meal.recipeId},
            ],
          );
      if (!mounted) return;
      final suggestion = result.slots.isEmpty ? null : result.slots.first;
      final recipe = suggestion?.recipe;
      if (suggestion == null || recipe == null) {
        await _offerWhenExhausted(meal);
        return;
      }
      final repo = ref.read(planningRepositoryProvider);
      final duration =
          (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
      await repo?.updateMealRecipe(
        meal.id,
        recipeId: recipe.id.isEmpty ? null : recipe.id,
        recipeTitre: recipe.titre,
        durationMinutes: duration,
        prepMinutes: recipe.tags.prepTime,
        cookMinutes: recipe.tags.cookTime,
        basePortions: recipe.portions,
        targetPortions: meal.targetPortions ?? recipe.portions,
        dismissRecipeId: _oustedBy(meal, recipe.id),
        components: _composeComponents(recipe),
        choiceSource: suggestion.source,
        justification: suggestion.justification,
      );
      _recordRefusal(meal, recipe.id.isEmpty ? null : recipe.id);
      if (mounted) {
        context.showSuccessSnackBar('« ${recipe.titre} » proposée');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.otherSuggestion',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar(
          'La suggestion n\'a pas abouti.',
          action: SnackBarAction(
            label: 'Réessayer',
            onPressed: () => _otherSuggestion(meal),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _aiLoadingIds.remove(meal.id));
    }
  }

  /// Liste épuisée pour ce repas : choisir une recette, ou la concevoir avec
  /// l'IA — un appel facturé, que la personne demande elle-même.
  Future<void> _offerWhenExhausted(PlannedMeal meal) async {
    final canCreate = ref.read(canEditProvider);
    final choice = await showDialog<_ExhaustedChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text(
          'Plus d\'autre recette à proposer pour ce créneau.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fermer'),
          ),
          // Concevoir enregistre une recette : pas pour un lecteur.
          if (canCreate)
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ExhaustedChoice.conceive),
              child: const Text('Concevoir avec l\'IA'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, _ExhaustedChoice.pick),
            child: const Text('Choisir une recette'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _ExhaustedChoice.pick:
        await _changeRecipe(meal);
      case _ExhaustedChoice.conceive:
        await _conceiveForMeal(meal);
    }
  }

  /// Conçoit une recette pour ce repas, l'enregistre dans les brouillons et
  /// la pose sur le repas. Un geste unitaire : il ne se rattache à aucune
  /// génération, le plafond du jour le borne.
  Future<void> _conceiveForMeal(PlannedMeal meal) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    setState(() => _aiLoadingIds.add(meal.id));
    try {
      final prefs =
          ref.read(planningPreferencesProvider).value ??
          const PlanningPreferences();
      final dayConstraint = prefs.dailyConstraints[meal.plannedAt.weekday];
      final suggestion = await ref
          .read(planningAiServiceProvider)
          .generateRecipeConcept(
            slotDate: meal.plannedAt,
            globalConstraints: prefs.globalConstraints,
            dayConstraint: dayConstraint == null || dayConstraint.isEmpty
                ? null
                : dayConstraint,
          );
      final recipe = suggestion.recipe;
      if (recipe == null) {
        if (mounted) _conceptFailed(meal);
        return;
      }
      final id = await repo.saveAsDraft(recipe);
      await repo.updateMealRecipe(
        meal.id,
        recipeId: id,
        recipeTitre: recipe.titre,
        durationMinutes:
            (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0),
        prepMinutes: recipe.tags.prepTime,
        cookMinutes: recipe.tags.cookTime,
        basePortions: recipe.portions,
        targetPortions: meal.targetPortions ?? recipe.portions,
        dismissRecipeId: _oustedBy(meal, id),
        components: _composeComponents(recipe),
        choiceSource: MealChoiceSource.concept,
        justification: suggestion.justification,
      );
      _recordRefusal(meal, id);
      if (mounted) {
        context.showSuccessSnackBar(
          'Recette conçue et enregistrée dans vos brouillons',
        );
      }
    } on GeminiCallableException catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.conceiveForMeal',
        error: e,
        stackTrace: stackTrace,
        context: {'code': e.code},
      );
      if (!mounted) return;
      if (e.code == 'resource-exhausted' && e.message.isNotEmpty) {
        // Plafond du jour : le message du serveur est écrit pour l'écran, et
        // réessayer ne servirait à rien avant demain.
        context.showErrorSnackBar(e.message);
      } else {
        _conceptFailed(meal);
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.conceiveForMeal',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) _conceptFailed(meal);
    } finally {
      if (mounted) setState(() => _aiLoadingIds.remove(meal.id));
    }
  }

  void _conceptFailed(PlannedMeal meal) {
    context.showErrorSnackBar(
      'La conception n\'a pas abouti.',
      action: SnackBarAction(
        label: 'Réessayer',
        onPressed: () => _conceiveForMeal(meal),
      ),
    );
  }

  /// Affiche le conseil de conservation d'un repas, en le produisant s'il
  /// manque et que l'utilisateur en a le droit.
  ///
  /// Un conseil déjà produit ne se repaie pas : il appartient au plat, pas au
  /// repas, et sert donc à toutes ses planifications.
  Future<void> _showStorageAdvice(PlannedMeal meal) async {
    final recipeId = meal.recipeId;
    if (recipeId == null || recipeId.isEmpty) return;
    setState(() => _storageLoadingIds.add(meal.id));
    try {
      final canGenerate = await ref.read(canWriteRecipeAdviceProvider.future);
      final lookup = await ref
          .read(storageRepositoryProvider)
          .ensure(recipeId: recipeId, canGenerate: canGenerate);
      if (!mounted) return;
      final StorageAdvice advice;
      switch (lookup) {
        case StorageAdviceAvailable(advice: final found):
          advice = found;
        case StorageAdviceReserved():
          // Aucun conseil enregistré, et seuls le créateur de la recette et
          // un administrateur peuvent en demander un : on le dit plutôt que
          // d'essuyer le refus du serveur.
          context.showSnackBar(kStorageAdviceReservedMessage);
          return;
        case StorageAdviceRecipeMissing():
          context.showErrorSnackBar(kRecipeNotFoundMessage);
          return;
      }
      final daysAhead = meal.prepDate == null
          ? 0
          : mealStorageDaysAhead(
              prepDate: meal.prepDate!,
              mealDate: meal.plannedAt,
            );
      await showStorageAdviceSheet(
        context,
        titre: meal.recipeTitre,
        advice: advice,
        daysAhead: daysAhead,
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.showStorageAdvice',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur conservation : $e');
      }
    } finally {
      if (mounted) setState(() => _storageLoadingIds.remove(meal.id));
    }
  }

  Future<void> _deleteMeal(PlannedMeal meal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce repas ?'),
        content: Text(
          '« ${meal.recipeTitre} » du ${DateFormat('d MMMM à HH:mm', 'fr').format(meal.plannedAt)} sera supprimé du planning.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(planningRepositoryProvider);
    await repo?.deleteMeal(meal.id);
  }

  @override
  Widget build(BuildContext context) {
    final mealsAsync = ref.watch(plannedMealsProvider);
    // Garder le provider de préférences vivant pour que ref.read() dans les
    // callbacks d'export ait toujours la valeur Firestore à jour.
    ref.watch(planningPreferencesProvider);
    // Les garnitures aussi : « Changer la recette » compose l'accompagnement
    // depuis ce que le compte a sous la main, lu ici pour être prêt.
    ref.watch(myStaplesProvider);
    final theme = Theme.of(context);
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Planning des repas'),
        centerTitle: false,
        actions: [
          if (isWide) ...[
            // Sur grand écran, le bouton rejoint la barre : il ne flotte plus
            // au-dessus des repas.
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.icon(
                onPressed: () => context.push('/planning/batch'),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Nouveau planning'),
              ),
            ),
            // Le « tirer pour rafraîchir » du corps n'existe pas à la souris.
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Actualiser le planning',
              onPressed: _refreshMeals,
            ),
            if (mealsAsync.value?.isNotEmpty == true) ...[
              IconButton(
                icon: const Icon(Icons.shopping_cart_outlined),
                tooltip: 'Liste des ingrédients',
                onPressed: () => _showIngredientsList(mealsAsync.value!),
              ),
              // La même icône que sur chaque repas et chaque créneau : un
              // geste, une icône. Elle reste distincte de celle du calendrier
              // de l'écran, qui sert à voir, pas à envoyer.
              IconButton(
                icon: const Icon(AppIcons.calendarExport),
                tooltip: 'Exporter le planning vers le calendrier',
                onPressed: () => _exportAllToCalendar(mealsAsync.value!),
              ),
            ],
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Paramètres du planning',
              onPressed: () => context.push('/planning/config'),
            ),
          ] else ...[
            PopupMenuButton<int>(
              tooltip: 'Actions',
              onSelected: (value) {
                if (value == 0) context.push('/planning/config');
                if (value == 3) _chooseDates();
                if (value == 1 && mealsAsync.value?.isNotEmpty == true) {
                  _showIngredientsList(mealsAsync.value!);
                }
                if (value == 2 && mealsAsync.value?.isNotEmpty == true) {
                  _exportAllToCalendar(mealsAsync.value!);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 3,
                  child: ListTile(
                    leading: Icon(Icons.date_range_outlined),
                    title: Text('Choisir des dates…'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 0,
                  child: ListTile(
                    leading: Icon(Icons.settings_outlined),
                    title: Text('Paramètres'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (mealsAsync.value?.isNotEmpty == true) ...[
                  const PopupMenuItem(
                    value: 1,
                    child: ListTile(
                      leading: Icon(Icons.shopping_cart_outlined),
                      title: Text('Liste des ingrédients'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 2,
                    child: ListTile(
                      leading: Icon(AppIcons.calendarExport),
                      title: Text('Exporter vers le calendrier'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: isWide
          ? null
          : AnimatedSlide(
              offset: _fabHidden ? const Offset(0, 2) : Offset.zero,
              duration: const Duration(milliseconds: 200),
              child: FloatingActionButton.extended(
                onPressed: () => context.push('/planning/batch'),
                // Étendu, le libellé se lit déjà : l'infobulle le doublerait.
                tooltip: _fabCompact ? 'Nouveau planning' : null,
                isExtended: !_fabCompact,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Nouveau planning'),
              ),
            ),
      body: RefreshIndicator(
        onRefresh: _refreshMeals,
        child: mealsAsync.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(error: e, onRetry: _refreshMeals),
          data: (meals) => _buildPeriod(context, theme, meals, isWide),
        ),
      ),
    );
  }

  /// L'écran : le calendrier, puis les jours de la période choisie.
  ///
  /// Aucun document n'est créé pour cette vue : elle range par jour les repas
  /// du flux temps réel et ceux de l'archive déjà lue. Une semaine est une
  /// lecture, pas un porteur.
  Widget _buildPeriod(
    BuildContext context,
    ThemeData theme,
    List<PlannedMeal> live,
    bool isWide,
  ) {
    // Le flux temps réel ne remonte que quatre-vingt-dix jours ; les mois plus
    // anciens sont lus à la demande. On les réunit ici, en écartant les
    // doublons : un mois d'archive peut chevaucher le flux.
    final meals = <String, PlannedMeal>{
      for (final m in live) m.id: m,
      for (final month in _archive.values)
        for (final m in month) m.id: m,
    }.values.toList();

    if (meals.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_today_outlined,
                size: AppIconSize.hero,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Aucun repas planifié',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              // Bouton principal
              FilledButton.icon(
                onPressed: () => context.push('/planning/batch'),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Générer un nouveau planning'),
              ),
              const SizedBox(height: 12),
              // Accès direct aux préférences
              OutlinedButton.icon(
                onPressed: () => context.push('/planning/config'),
                icon: const Icon(Icons.tune_outlined),
                label: const Text('Configurer mes préférences'),
              ),
              const SizedBox(height: 24),
              Text(
                'Vous pouvez aussi planifier un repas isolé\ndepuis la page d\'une recette (icône 📅).',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cycleStartDay =
        ref.watch(planningPreferencesProvider).value?.cycleStartDay ??
        DateTime.friday;
    final period = _period(today);
    final earliestDay = today.subtract(_archiveDepth);

    final calendar = PlanningPeriodCalendar(
      period: period,
      cycleStartDay: cycleStartDay,
      meals: meals,
      expanded: isWide || _calendarExpanded,
      month: _visibleMonth,
      earliestDay: earliestDay,
      onSelectPeriod: (p) => _selectPeriod(p, collapse: !isWide),
      onMonthChanged: (month) {
        setState(() => _visibleMonth = month);
        _loadArchiveAround(month);
      },
      onTapDay: _revealDay,
      rangeStart: _rangeStart,
      onRangeStart: (day) {
        setState(() {
          if (_rangeStart == null) _expandedBeforeRange = _calendarExpanded;
          _rangeStart = day;
          // La fin peut tomber un autre mois : le choix se fait calendrier
          // déplié, sur le mois du premier jour.
          if (!isWide) _calendarExpanded = true;
          _visibleMonth = PlanningPeriodCalendar.monthOf(day);
        });
        _loadArchiveAround(_visibleMonth);
      },
      // Annuler rend le calendrier tel qu'il était avant l'appui long.
      onRangeCancel: () => setState(() {
        _rangeStart = null;
        if (!isWide) _calendarExpanded = _expandedBeforeRange;
      }),
      onRangeTooLong: () => context.showErrorSnackBar(
        '${PlanningPeriod.maxLength} jours au plus — touchez un jour plus '
        'proche.',
      ),
      onChooseDates: isWide ? _chooseDates : null,
      onToggleExpanded: isWide
          ? null
          : () => setState(() {
              _calendarExpanded = !_calendarExpanded;
              // Déplié, le mois montré est celui de la période lue.
              if (_calendarExpanded) {
                _visibleMonth = PlanningPeriodCalendar.monthOf(period.start);
                _loadArchiveAround(_visibleMonth);
              }
            }),
    );

    final days = _buildPeriodDays(theme, meals, period, today, isWide);

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: calendar,
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: days),
        ],
      );
    }
    // Déplié, le mois peut dépasser la hauteur d'un téléphone tenu à
    // l'horizontale ou d'un texte agrandi : il défile dans une hauteur bornée
    // au lieu de déborder, et la liste garde le reste.
    return LayoutBuilder(
      builder: (context, constraints) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.7),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 4),
              child: calendar,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onListScroll,
              child: days,
            ),
          ),
        ],
      ),
    );
  }

  /// Change de période : le calendrier déplié se replie sur un téléphone, et
  /// l'archive de chaque mois traversé se charge si besoin.
  void _selectPeriod(PlanningPeriod period, {required bool collapse}) {
    setState(() {
      _chosenPeriod = period;
      _rangeStart = null;
      if (collapse) _calendarExpanded = false;
      _fabCompact = false;
      _fabHidden = false;
    });
    for (
      var m = PlanningPeriodCalendar.monthOf(period.start);
      !m.isAfter(period.end);
      m = DateTime(m.year, m.month + 1)
    ) {
      _loadArchiveMonth(m);
    }
  }

  /// « Choisir des dates… » : le sélecteur de plage du système, l'autre
  /// chemin vers une période libre que l'appui long, qui ne se devine pas.
  Future<void> _chooseDates() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final period = _period(today);
    final picked = await showDateRangePicker(
      context: context,
      firstDate: PlanningPeriodCalendar.monthOf(today.subtract(_archiveDepth)),
      lastDate: DateTime(today.year + 2, today.month, today.day),
      initialDateRange: DateTimeRange(start: period.start, end: period.end),
      helpText: 'Choisir la période',
      saveText: 'Afficher',
    );
    if (picked == null || !mounted) return;
    final chosen = PlanningPeriod(picked.start, picked.end);
    if (chosen.length > PlanningPeriod.maxLength) {
      context.showErrorSnackBar(
        '${PlanningPeriod.maxLength} jours au plus — choisissez une période '
        'plus courte.',
      );
      return;
    }
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    _selectPeriod(chosen, collapse: !isWide);
    if (isWide) {
      setState(
        () => _visibleMonth = PlanningPeriodCalendar.monthOf(chosen.start),
      );
    }
  }

  /// Amène la liste sur [day], touché dans le bandeau replié.
  void _revealDay(DateTime day) {
    final ctx = _dayKeys[day]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Réduit le bouton « Nouveau planning » dès que la liste a défilé, le
  /// masque pendant qu'on descend, le rend quand on remonte.
  bool _onListScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final compact = n.metrics.pixels > 0;
    var hidden = _fabHidden;
    if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.reverse) hidden = true;
      if (n.direction == ScrollDirection.forward) hidden = false;
    }
    if (n.metrics.pixels <= 0) hidden = false;
    if (compact != _fabCompact || hidden != _fabHidden) {
      setState(() {
        _fabCompact = compact;
        _fabHidden = hidden;
      });
    }
    return false;
  }

  /// Les jours de la période lue, vides compris : un jour libre est une
  /// information, et l'endroit où poser une recette.
  Widget _buildPeriodDays(
    ThemeData theme,
    List<PlannedMeal> meals,
    PlanningPeriod period,
    DateTime today,
    bool isWide,
  ) {
    final grouped = <DateTime, List<PlannedMeal>>{};
    final prepared = <DateTime, List<PlannedMeal>>{};
    for (final meal in meals) {
      (grouped[PlanningPeriodCalendar.dayOf(meal.plannedAt)] ??= []).add(meal);
      final prep = meal.prepDate;
      if (prep != null) {
        (prepared[PlanningPeriodCalendar.dayOf(prep)] ??= []).add(meal);
      }
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.plannedAt.compareTo(b.plannedAt));
    }

    _dayKeys.removeWhere((day, _) => !period.contains(day));

    // Une colonne construite d'un bloc, pas une liste paresseuse : un appui
    // sur un jour lointain du bandeau doit trouver ce jour pour y descendre,
    // et une période ne dépasse pas trente et un jours.
    return SingleChildScrollView(
      // Une clé par période : une nouvelle période s'ouvre sur son premier
      // jour, pas à la hauteur où l'on avait laissé la précédente.
      key: ValueKey(period),
      physics: const AlwaysScrollableScrollPhysics(),
      // La marge du bas laisse passer la dernière ligne sous le bouton
      // « Nouveau planning » : sans elle, il couvrait l'icône d'export du
      // dernier repas, et rien ne permettait de descendre plus bas.
      padding: EdgeInsets.fromLTRB(0, 0, 0, isWide ? 24 : 96),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final day in period.days)
            Column(
              key: _dayKeys.putIfAbsent(day, GlobalKey.new),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PlanningDayHeader(
                  day: day,
                  isToday: day == today,
                  isPast: day.isBefore(today),
                ),
                if ((grouped[day] ?? const []).isEmpty)
                  PlanningEmptyDayRow(
                    isPast: day.isBefore(today),
                    onPick: day.isBefore(today)
                        ? null
                        : () => _addMealOnDay(day),
                  ),
                for (final meal in grouped[day] ?? const <PlannedMeal>[])
                  PlanningMealTile(
                    meal: meal,
                    isPast: day.isBefore(today),
                    aiLoading:
                        _aiLoadingIds.contains(meal.id) ||
                        _storageLoadingIds.contains(meal.id),
                    isWide: isWide,
                    onDelete: () => _deleteMeal(meal),
                    onChangeRecipe: () => _changeRecipe(meal),
                    onReschedule: () => _rescheduleMeal(meal),
                    onAddComponent: () => _addComponent(meal),
                    onRemoveComponent: (c) => _removeComponent(meal, c),
                    onClearRecipe: () => _clearRecipe(meal),
                    onOtherSuggestion: () => _otherSuggestion(meal),
                    onStorageAdvice: () => _showStorageAdvice(meal),
                    onTimeChanged: () => _changeTime(meal),
                    onExportToCalendar: () => _exportMealToCalendar(meal),
                    onTap: _openRecipeFor(meal),
                    onComponentTap: (c) => _openComponentRecipe(meal, c),
                  ),
                // Ce qui se prépare ce jour-là pour être mangé plus tard : le
                // calendrier le signale par une pastille creuse, la liste dit
                // quoi et pour quand.
                if (prepared[day] != null) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Row(
                      children: [
                        Icon(
                          Icons.soup_kitchen_outlined,
                          size: AppIconSize.inline,
                          color: theme.colorScheme.tertiary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'À préparer ce jour-là',
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: theme.colorScheme.tertiary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final meal in prepared[day]!)
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.schedule_outlined,
                        size: AppIconSize.small,
                      ),
                      title: Text(meal.recipeTitre),
                      subtitle: Text(
                        'pour le ${DateFormat('EEEE d MMMM', 'fr').format(meal.plannedAt)}',
                      ),
                      onTap: _openRecipeFor(meal),
                    ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  /// Pose une recette sur un jour libre de la période lue.
  ///
  /// Le repas prend l'heure et les parts de son jour de semaine, comme dans
  /// « Nouveau planning » ; l'heure se change ensuite d'un appui sur le repas.
  Future<void> _addMealOnDay(DateTime day) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final canCreate = ref.read(canEditProvider);
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: _availableRecipes,
        hintText: 'Rechercher ou saisir un nom libre\u2026',
        freeNameAlways: true,
        onGenerateIdeas: canCreate ? _generateMealIdeas : null,
        onConceiveIdea: canCreate
            ? (idea) => _conceiveMealIdea(idea, on: day)
            : null,
      ),
    );
    if (recipe == null || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    final prefs =
        ref.read(planningPreferencesProvider).value ??
        const PlanningPreferences();
    final time = prefs.mealTimeFor(day.weekday);
    final constraint = prefs.dailyConstraints[day.weekday];
    final targetPortions = (constraint?.targetPortions ?? 0) > 0
        ? constraint!.targetPortions
        : recipe.portions;
    final prepMinutes = recipe.tags.prepTime;
    final cookMinutes = recipe.tags.cookTime;
    try {
      await repo.addMeal(
        PlannedMeal(
          id: '',
          uid: repo.uid,
          recipeId: recipe.id.isEmpty ? null : recipe.id,
          recipeTitre: recipe.titre,
          plannedAt: DateTime(
            day.year,
            day.month,
            day.day,
            time.hour,
            time.minute,
          ),
          durationMinutes: (prepMinutes ?? 0) + (cookMinutes ?? 0),
          prepMinutes: prepMinutes,
          cookMinutes: cookMinutes,
          basePortions: recipe.portions,
          targetPortions: targetPortions,
          components: _composeComponents(recipe),
          choiceSource: MealChoiceSource.manual,
          createdAt: DateTime.now(),
        ),
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.addMealOnDay',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Repas non enregistré : $e');
    }
  }

  /// Charge, si besoin, les mois d'archive que le calendrier déplié va
  /// montrer.
  ///
  /// La grille montre aussi les jours des mois voisins, sur ses première et
  /// dernière lignes : charger les trois mois évite qu'un de ces jours
  /// s'affiche vide alors qu'il porte des repas.
  void _loadArchiveAround(DateTime month) {
    for (final m in [
      DateTime(month.year, month.month - 1),
      month,
      DateTime(month.year, month.month + 1),
    ]) {
      _loadArchiveMonth(m);
    }
  }

  /// Lit un mois d'archive, une seule fois.
  ///
  /// Les mois couverts par le flux temps réel ne sont pas relus : ils arrivent
  /// déjà, et les relire les paierait deux fois.
  Future<void> _loadArchiveMonth(DateTime month) async {
    final key = PlanningPeriodCalendar.monthOf(month);
    if (_archive.containsKey(key) || _archiveLoading.contains(key)) return;

    final today = PlanningPeriodCalendar.dayOf(DateTime.now());
    final liveFrom = today.subtract(PlanningRepository.historyWindow);
    final lastDay = DateTime(key.year, key.month + 1, 0);
    if (!lastDay.isBefore(liveFrom)) return;
    if (key.isBefore(
      PlanningPeriodCalendar.monthOf(today.subtract(_archiveDepth)),
    )) {
      return;
    }

    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;

    _archiveLoading.add(key);
    try {
      final meals = await repo.getMealsBetween(from: key, to: lastDay);
      if (!mounted) return;
      setState(() => _archive[key] = meals);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.loadArchiveMonth',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Historique du mois illisible : $e');
      }
    } finally {
      _archiveLoading.remove(key);
    }
  }

  /// Recharge le planning : geste de rafraîchissement et bouton Réessayer.
  Future<void> _refreshMeals() async {
    ref.invalidate(plannedMealsProvider);
    await ref.read(plannedMealsProvider.future);
  }

  /// Ouvre la fiche recette du repas, ou rien s'il n'en a pas.
  ///
  /// Le contexte du repas voyage dans l'adresse — voir [mealRecipeLocation] :
  /// la même route sert au lien collé dans l'événement Google Calendar.
  VoidCallback? _openRecipeFor(PlannedMeal meal) {
    final location = mealRecipeLocation(meal);
    return location == null ? null : () => context.push(location);
  }

  /// Ouvre la fiche d'un composant du repas qui est une recette, pour les
  /// parts du repas. Le jour de préparation n'est pas transmis : il est celui
  /// du plat, pas de son accompagnement.
  void _openComponentRecipe(PlannedMeal meal, MealComponent component) {
    final recipeId = component.recipeId;
    if (recipeId == null || recipeId.isEmpty) return;
    context.push(
      recipeLocationFor(
        recipeId: recipeId,
        targetPortions: meal.portionsForComponents,
      ),
    );
  }
}
