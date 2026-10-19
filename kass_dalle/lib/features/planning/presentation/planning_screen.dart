import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../../groups/presentation/group_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/shopping_cart.dart';
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
import '../domain/meal_suggestion.dart';
import '../domain/meal_staple.dart';
import '../domain/side_chooser.dart';
import 'meal_composer.dart';
import 'meal_staples_providers.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../domain/planning_reach.dart';
import '../domain/planning_target.dart';
import '../domain/planning_week.dart';
import '../services/calendar_service.dart';
import 'meal_suggestion_providers.dart';
import 'meal_suggestions_window.dart';
import 'planning_owner_selector.dart';
import 'planning_period_calendar.dart';
import 'planning_providers.dart';
import 'planning_target_sheet.dart';
import 'planning_widgets.dart';
import 'recipe_picker_sheet.dart';
import '../../search/presentation/search_screen.dart'
    show ExploreChoice, ExplorePick, SearchScreen;
import 'side_picker_sheet.dart';
import 'storage_advice_sheet.dart';
import 'suggest_meal_screen.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_service.dart'
    show GeminiCallableException;
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';

/// Choix proposé quand « Autre suggestion » n'a plus de recette.
enum _ExhaustedChoice { pick, conceive }

/// L'écran du planning : les repas de l'utilisateur, ceux des plannings de
/// ses groupes, et ceux des plannings que d'autres membres de ses groupes
/// partagent avec lui, en lecture seule.
///
/// Un éditeur ou un administrateur planifie, dans son planning et dans celui
/// des groupes dont il est le propriétaire. Un lecteur ne planifie plus
/// (v0.23.47) : il lit les plannings partagés avec lui et ceux de ses
/// groupes, et relit ses repas antérieurs sans les modifier ni les supprimer.
/// Tous les rôles ajoutent un repas, ou les repas à venir de la période, à
/// leur propre liste de courses.
class PlanningScreen extends ConsumerStatefulWidget {
  /// Vrai quand un lecteur arrive ici renvoyé d'un écran de planification
  /// (`/planning/batch`, `/planning/config`, `/planning/staples`) : l'écran
  /// lui dit pourquoi.
  final bool showReservedNotice;

  const PlanningScreen({super.key, this.showReservedNotice = false});

  @override
  ConsumerState<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends ConsumerState<PlanningScreen> {
  List<Recipe> _availableRecipes = [];
  bool _recipesLoaded = false;

  /// Recettes de la famille pour « Composer le repas » et « Compléter »,
  /// lues au premier usage ; `null` tant qu'elles ne l'ont pas été.
  List<Recipe>? _familySideRecipes;

  /// Recettes de mes repas de la période lue — plats et accompagnements qui
  /// sont des recettes —, lues par lots : la tuile en tire ce qui manque au
  /// plat. Rien n'est figé sur le repas : la recette corrigée se relit au
  /// rafraîchissement.
  final Map<String, Recipe> _mealRecipes = {};
  final Set<String> _mealRecipesPending = {};
  final Set<String> _mealRecipesFailed = {};

  /// Famille de chaque garniture du compte, masquées comprises, lue au
  /// dernier affichage.
  Map<String, StapleCategory> _stapleCategories = const {};
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

  /// Lisibilité, pour l'utilisateur, des recettes des repas d'autrui : vrai
  /// si la recette s'ouvre, faux si elle n'est pas partagée avec lui. Une
  /// recette absente n'est pas encore résolue.
  final Map<String, bool> _readableRecipes = {};
  final Set<String> _readablePending = {};

  /// Recettes dont la résolution a échoué : pas de nouvel essai avant un
  /// rafraîchissement, l'écran les montre sans lien ni cadenas.
  final Set<String> _readableFailed = {};

  /// Vrai quand « Mon planning » est affiché : l'archive n'est lue que dans
  /// ce cas.
  bool _mineShown = true;

  /// Prénoms des plannings partagés au dernier affichage, pour dire lequel
  /// cesse de l'être.
  Map<String, String> _ownerNames = const {};

  /// Noms des groupes dont le planning est proposé au dernier affichage, pour
  /// dire lequel cesse d'être accessible.
  Map<String, String> _groupNames = const {};

  /// Les groupes affichés dont l'utilisateur est le propriétaire : leurs repas
  /// comptent dans la fenêtre de variété d'« Autre suggestion ».
  List<String> _ownedGroupIdsShown = const [];

  @override
  void initState() {
    super.initState();
    if (widget.showReservedNotice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.showSnackBar(
          'Planification réservée aux éditeurs. Demandez à un '
          'administrateur de vous nommer éditeur.',
        );
        // L'adresse perd son paramètre : un rafraîchissement de la page ne
        // répète pas le message.
        GoRouter.maybeOf(context)?.go('/planning');
      });
    }
  }

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
        context.showErrorSnackBar(
          'Les recettes n\'ont pas pu être lues. Réessayez.',
        );
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

  /// « Composer le repas » : le plat, ce qu'il apporte, ses accompagnements
  /// (0 à six), ce qui manque et ce que le programme propose pour le
  /// combler. Une seule écriture, à « Enregistrer ».
  Future<void> _composeMeal(PlannedMeal meal) => showMealComposer(
    context,
    load: () => _composerData(meal),
    sides: [
      for (final c in meal.components)
        if (c.isMainSide) c,
    ],
    fallbackTitle: meal.recipeTitre,
    dismissedRecipeIds: meal.dismissedRecipeIds.toSet(),
    onSave: (composition) => _saveComposition(meal, composition),
  );

  /// Ce que l'éditeur lit : le plat du repas, et les recettes proposées —
  /// les miennes validées et celles, non privées, de la famille. Une erreur
  /// remonte à l'éditeur, qui l'affiche avec « Réessayer ».
  Future<MealComposerData> _composerData(PlannedMeal meal) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) throw StateError('Utilisateur non connecté.');
    if (!_recipesLoaded) {
      final recipes = await repo.getValidatedRecipes();
      if (mounted) {
        setState(() {
          _availableRecipes = recipes;
          _recipesLoaded = true;
        });
      }
    }
    final familyRecipes = await _loadFamilySideRecipesIfNeeded();
    final main = await _mainRecipeFor(meal);
    final seen = <String>{};
    return MealComposerData(
      main: main,
      recipes: [
        for (final r in [..._availableRecipes, ...familyRecipes])
          if (seen.add(r.id)) r,
      ],
    );
  }

  /// La recette du plat de [meal] : déjà lue pour la tuile, chargée avec mes
  /// recettes validées, ou relue par identifiant (brouillon, recette de la
  /// famille). `null` pour un repas libre ou une recette introuvable.
  Future<Recipe?> _mainRecipeFor(PlannedMeal meal) async {
    final id = meal.recipeId;
    if (id == null || id.isEmpty) return null;
    final known = _mealRecipes[id] ?? _validatedRecipeById(id);
    if (known != null) return known;
    final repo = ref.read(planningRepositoryProvider);
    final fetched = (await repo?.getRecipesByIds([id]))?.firstOrNull;
    if (fetched != null && mounted) {
      setState(() => _mealRecipes[fetched.id] = fetched);
    }
    return fetched;
  }

  /// Écrit ce que l'éditeur rend : les accompagnements seuls, ou le plat et
  /// ses accompagnements quand « Changer » a posé un autre plat. Une erreur
  /// remonte à l'éditeur, qui reste ouvert.
  Future<void> _saveComposition(
    PlannedMeal meal,
    MealComposition composition,
  ) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) throw StateError('Utilisateur non connecté.');
    final components = replaceMainSides(meal.components, composition.sides);
    final recipe = composition.main;
    if (!composition.mainChanged || recipe == null) {
      await repo.updateMealComponents(meal.id, components);
      return;
    }
    final recipeId = recipe.id.isEmpty ? null : recipe.id;
    await repo.updateMealRecipe(
      meal.id,
      recipeId: recipeId,
      recipeTitre: recipe.titre,
      durationMinutes:
          (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0),
      prepMinutes: recipe.tags.prepTime,
      cookMinutes: recipe.tags.cookTime,
      basePortions: recipe.portions,
      targetPortions: meal.targetPortions ?? recipe.portions,
      dismissRecipeId: _oustedBy(meal, recipeId),
      components: components,
      choiceSource: MealChoiceSource.manual,
    );
    if (recipeId != null && mounted) {
      setState(() => _mealRecipes[recipeId] = recipe);
    }
    _recordRefusal(meal, recipeId);
  }

  /// « Compléter » : un accompagnement de plus, choisi dans la feuille
  /// filtrée sur ce qui manque, suggestions du plat en tête.
  Future<void> _completeMeal(PlannedMeal meal, SideNeed need) async {
    final main = _mealRecipes[meal.recipeId];
    if (main == null) return;
    // La tuile masque « Compléter » au sixième accompagnement.
    final sideCount = meal.components.where((c) => c.isMainSide).length;
    if (sideCount >= kMaxSidesPerDish) return;
    await _loadRecipesIfNeeded();
    final familyRecipes = await _loadFamilySideRecipesIfNeeded();
    if (!mounted) return;
    final staples = ref.read(myStaplesProvider).value ?? const [];
    final seen = <String>{};
    final result = await showModalBottomSheet<SidePickerResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SidePickerSheet(
        main: main,
        candidates: sideCandidatesFrom(
          staples: staples,
          recipes: [
            for (final r in [..._availableRecipes, ...familyRecipes])
              if (seen.add(r.id)) r,
          ],
        ),
        initialNeed: need,
      ),
    );
    final component = result?.toComponent(justification: 'Choisi à la main.');
    if (component == null || !mounted) return;
    try {
      await ref
          .read(planningRepositoryProvider)
          ?.updateMealComponents(
            meal.id,
            insertMainSide(meal.components, component),
          );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.completeMeal',
        error: e,
        stackTrace: stackTrace,
        context: {'meal_id': meal.id, 'need': need.name},
      );
      if (mounted) {
        context.showErrorSnackBar('Repas non enregistré. Réessayez.');
      }
    }
  }

  /// Recettes validées et non privées des autres membres de la famille, lues
  /// une fois, pour proposer leurs recettes d'accompagnement à la main —
  /// « Pommes dauphine » d'un autre membre. En cas d'échec, l'erreur est
  /// signalée et la feuille s'ouvre avec les seules recettes du compte.
  Future<List<Recipe>> _loadFamilySideRecipesIfNeeded() async {
    final cached = _familySideRecipes;
    if (cached != null) return cached;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return const [];
    try {
      final familyIds = (ref.read(groupMemberIdsProvider).value ?? {})
          .where((id) => id != repo.uid)
          .toList();
      final recipes = await repo.getFamilyValidatedRecipes(familyIds);
      _familySideRecipes = recipes;
      return recipes;
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.loadFamilySideRecipes',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  /// Retire un accompagnement déjà posé sur ce repas, auto ou choisi à la
  /// main. « Annuler » remet la liste d'avant.
  Future<void> _removeComponent(
    PlannedMeal meal,
    MealComponent component,
  ) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    final before = meal.components;
    final updated = before.where((c) => !identical(c, component)).toList();
    try {
      await repo.updateMealComponents(meal.id, updated);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.removeComponent',
        error: e,
        stackTrace: stackTrace,
        context: {'meal_id': meal.id},
      );
      if (mounted) {
        context.showErrorSnackBar('Accompagnement non retiré. Réessayez.');
      }
      return;
    }
    if (!mounted) return;
    context.showSuccessSnackBar(
      'Accompagnement retiré.',
      action: SnackBarAction(
        label: 'Annuler',
        onPressed: () => _restoreComponents(meal.id, before),
      ),
    );
  }

  Future<void> _restoreComponents(
    String mealId,
    List<MealComponent> components,
  ) async {
    try {
      await ref
          .read(planningRepositoryProvider)
          ?.updateMealComponents(mealId, components);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.restoreComponents',
        error: e,
        stackTrace: stackTrace,
        context: {'meal_id': mealId},
      );
      if (mounted) {
        context.showErrorSnackBar('Accompagnement non remis. Réessayez.');
      }
    }
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
      components: replaceMainSides(meal.components, _composeComponents(recipe)),
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

  /// Un repas compte-t-il pour les courses ? Il lui faut une recette ou un
  /// accompagnement qui s'achète : un repas libre sans rien, ou avec un
  /// accompagnement en texte libre, n'apporte aucun article.
  static bool _bringsShopping(PlannedMeal meal) =>
      (meal.recipeId ?? '').isNotEmpty || meal.components.any((c) => !c.isFree);

  /// « Ajouter aux courses » sur un repas, ou null quand l'action n'existe
  /// pas : repas passé, plat dont la recette ne se lit pas (cadenas), repas
  /// libre sans accompagnement. Tous les rôles l'ont, lecteur compris.
  VoidCallback? _shopActionFor(
    PlannedMeal meal, {
    required bool isPast,
    Set<String> locked = const {},
  }) {
    if (isPast || !_bringsShopping(meal)) return null;
    if (meal.recipeId != null && locked.contains(meal.recipeId)) return null;
    return () => _addMealToShopping(meal);
  }

  /// Les repas à venir de la période lue, dans tous les plannings affichés,
  /// qui apportent des articles.
  List<PlannedMeal> _periodMealsToShop(List<PlannedMeal> shown) {
    final today = DateTime.now();
    return [
      for (final m in mealsToShop(shown, today: today, week: _period(today)))
        if (_bringsShopping(m)) m,
    ];
  }

  /// Les articles de [meals] : chaque recette mise à l'échelle des parts du
  /// repas (`planningScaleRecipeForMeal`), les garnitures multipliées par ces
  /// parts. Rien n'est écrit dans une recette.
  ///
  /// Null quand la lecture des recettes échoue : l'écran l'a déjà dit.
  ///
  /// Une recette non rendue se range dans `notShared` quand l'écran la sait
  /// illisible pour le compte (cadenas), dans `missing` sinon.
  Future<
    ({List<ShoppingItem> items, List<String> missing, List<String> notShared})?
  >
  _shoppingItemsFor(List<PlannedMeal> meals) async {
    // Résoudre par identifiant : un repas peut pointer sur un brouillon ou une
    // recette de la famille, absente des recettes validées de l'utilisateur.
    // Une recette que le compte ne peut pas lire n'est pas rendue : elle
    // est dite non partagée (cadenas connu) ou introuvable.
    final repo = ref.read(planningRepositoryProvider);
    // Les plats, et les recettes d'accompagnement des repas : une garniture
    // avec recette se compte comme le plat qu'elle accompagne.
    final ids = <String>[
      for (final m in meals) ...[
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
        feature: 'planningScreen.shoppingItems',
        error: e,
        stackTrace: stackTrace,
        context: {'meal_count': meals.length, 'recipe_count': ids.length},
      );
      if (mounted) {
        context.showErrorSnackBar(
          'Les recettes n\'ont pas pu être lues. Réessayez.',
        );
      }
      return null;
    }
    final recipesById = {for (final r in resolved) r.id: r};
    final missing = <String>[];
    final notShared = <String>[];
    void absent(String id, String label) =>
        (_readableRecipes[id] == false ? notShared : missing).add(label);
    final planningRecipes = <Recipe>[];
    // Les garnitures, multipliées par les parts du repas ; elles se fondent
    // dans les lignes des recettes — le riz d'une garniture et le riz d'une
    // recette font une seule ligne de courses.
    final extras = <PlanningExtraProduct>[];
    for (final meal in meals) {
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
            absent(c.recipeId!, c.label);
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
        absent(recipeId, meal.recipeTitre);
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
    final aggregated = planningAggregateProducts(
      planningRecipes,
      extras: extras,
    );
    final items = shoppingItemsFromProducts(
      aggregated.products,
      (p) => aggregated.sources[p.name] ?? 'Planning',
    );
    return (items: items, missing: missing, notShared: notShared);
  }

  /// Une recette non comptée ne disparaît pas sans un mot : sinon la liste
  /// paraît complète alors qu'il y manque un repas entier. Une recette au
  /// cadenas se dit « non partagée », les autres « introuvables ».
  void _sayMissing(List<String> missing, List<String> notShared) {
    if (!mounted) return;
    if (notShared.isNotEmpty) {
      context.showSnackBar(
        'Recette non partagée, ingrédients non comptés : '
        '${notShared.join(', ')}',
      );
    }
    if (missing.isNotEmpty) {
      context.showSnackBar(
        'Recette introuvable, ingrédients non comptés : ${missing.join(', ')}',
      );
    }
  }

  /// Repas dont l'ajout aux courses est en cours : leur tuile montre un
  /// indicateur, et un second appui est ignoré.
  final Set<String> _shoppingMealIds = {};

  /// « Ajouter la période aux courses » en cours : l'icône devient un
  /// indicateur, et un second appui est ignoré.
  bool _periodShopping = false;

  /// « Ajouter aux courses » sur un repas, d'où qu'il vienne : les articles
  /// vont dans le panier du compte connecté.
  Future<void> _addMealToShopping(PlannedMeal meal) async {
    if (_shoppingMealIds.contains(meal.id) || _periodShopping) return;
    setState(() => _shoppingMealIds.add(meal.id));
    try {
      await _addMealToShoppingNow(meal);
    } finally {
      if (mounted) setState(() => _shoppingMealIds.remove(meal.id));
    }
  }

  Future<void> _addMealToShoppingNow(PlannedMeal meal) async {
    final collected = await _shoppingItemsFor([meal]);
    if (collected == null || !mounted) return;
    if (collected.items.isEmpty) {
      _sayMissing(collected.missing, collected.notShared);
      if (collected.missing.isEmpty && collected.notShared.isEmpty) {
        context.showSnackBar('Aucun ingrédient à ajouter');
      }
      return;
    }
    final added = await addToShoppingList(
      context,
      ref,
      incoming: collected.items,
      summary:
          '« ${meal.recipeTitre} » apporte '
          '${shoppingArticles(collected.items.length)}.',
    );
    // Après l'ajout : annoncées avant, ces lignes passaient sous la boîte et
    // retardaient le message qui porte « Annuler ». Rien d'ajouté, rien à dire.
    if (added) _sayMissing(collected.missing, collected.notShared);
  }

  /// « Ajouter la période aux courses » : les repas à venir de la période
  /// lue, dans tous les plannings affichés.
  Future<void> _addPeriodToShopping(
    List<PlannedMeal> shown,
    _PlanningView view,
  ) async {
    if (_periodShopping || _shoppingMealIds.isNotEmpty) return;
    setState(() => _periodShopping = true);
    try {
      await _addPeriodToShoppingNow(shown, view);
    } finally {
      if (mounted) setState(() => _periodShopping = false);
    }
  }

  Future<void> _addPeriodToShoppingNow(
    List<PlannedMeal> shown,
    _PlanningView view,
  ) async {
    final meals = _periodMealsToShop(shown);
    if (meals.isEmpty) {
      context.showSnackBar('Aucun repas à venir sur cette période.');
      return;
    }
    final collected = await _shoppingItemsFor(meals);
    if (collected == null || !mounted) return;
    if (collected.items.isEmpty) {
      _sayMissing(collected.missing, collected.notShared);
      if (collected.missing.isEmpty && collected.notShared.isEmpty) {
        context.showSnackBar(
          'Aucune recette avec ingrédients dans le planning.',
        );
      }
      return;
    }
    final n = meals.length;
    final added = await addToShoppingList(
      context,
      ref,
      incoming: collected.items,
      summary:
          '$n repas à venir ${n > 1 ? 'apportent' : 'apporte'} '
          '${shoppingArticles(collected.items.length)}.',
      breakdown: planningShoppingBreakdown(
        meals,
        myUid: view.myUid,
        nameOf: view.nameOf,
        groupNameOf: (groupId) => view.groupNames[groupId] ?? 'Groupe',
      ),
    );
    if (added) _sayMissing(collected.missing, collected.notShared);
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
      // dans ce que l'écran affiche déjà : aucune lecture de plus. Mon
      // planning et ceux de mes groupes : un plat servi à la famille compte
      // pour moi, qui le cuisine.
      final recentlyServed = recentlyServedBefore(
        [
          ...?ref.read(plannedMealsProvider).value,
          for (final groupId in _ownedGroupIdsShown)
            ...?ref
                .read(
                  groupPlannedMealsProvider((
                    groupId: groupId,
                    ownerUid: meal.uid,
                  )),
                )
                .value,
        ],
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
            groupId: meal.groupId,
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
        components: replaceMainSides(
          meal.components,
          _composeComponents(recipe),
        ),
        choiceSource: suggestion.source,
        justification: suggestion.justification,
        // Un écart de la présélection (déjà servi, note relâchée) reste
        // lisible sur le repas.
        relaxedCriteria: result.rankings[0]?.relaxed ?? const [],
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
        components: replaceMainSides(
          meal.components,
          _composeComponents(recipe),
        ),
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
    final myMealsAsync = ref.watch(plannedMealsProvider);
    final canPlan = ref.watch(canEditProvider);
    final myUid = ref.watch(appUserProvider).value?.uid;
    // Garder le provider de préférences vivant pour que ref.read() dans les
    // callbacks d'export ait toujours la valeur Firestore à jour.
    ref.watch(planningPreferencesProvider);
    // Les garnitures aussi : « Changer la recette » compose l'accompagnement
    // depuis ce que le compte a sous la main, lu ici pour être prêt. Le
    // lecteur ne planifie pas : il n'en a pas besoin.
    if (canPlan) ref.watch(myStaplesProvider);
    ref.listen(planningReachProvider, _onReachChanged);
    final theme = Theme.of(context);
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    final optionsAsync = ref.watch(planningOwnerOptionsProvider);
    final options = optionsAsync.value ?? const <PlanningOwnerOption>[];
    final mineShown = options.any((o) => o.isMine && o.shown);
    final shownOthers = [
      for (final o in options)
        if (!o.isMine && !o.isGroup && o.shown) o,
    ];
    final shownGroups = [
      for (final o in options)
        if (o.isGroup && o.shown) o,
    ];
    _mineShown = mineShown;
    _ownerNames = {
      for (final o in options)
        if (!o.isMine && !o.isGroup) o.uid: o.name,
    };
    _groupNames = {
      for (final o in options)
        if (o.isGroup) o.groupId!: o.name,
    };
    _ownedGroupIdsShown = [
      for (final o in shownGroups)
        if (o.isOrganizer) o.groupId!,
    ];

    // Un flux par planning partagé ou de groupe affiché : l'erreur de l'un ne
    // masque pas les autres.
    final sharedMeals = <PlannedMeal>[];
    final failed = <PlanningOwnerOption>[];
    var sharedLoading = false;
    for (final owner in shownOthers) {
      final async = ref.watch(sharedPlannedMealsProvider(owner.uid));
      if (async.hasValue) {
        sharedMeals.addAll(async.value!);
      } else if (async.hasError) {
        failed.add(owner);
      } else {
        sharedLoading = true;
      }
    }
    final failedGroups = <PlanningOwnerOption>[];
    for (final group in shownGroups) {
      final async = ref.watch(groupPlannedMealsProvider(group.groupKey));
      if (async.hasValue) {
        sharedMeals.addAll(async.value!);
      } else if (async.hasError) {
        failedGroups.add(group);
      } else {
        sharedLoading = true;
      }
    }
    final reachAsync = ref.watch(planningReachProvider);

    // Mes repas : le flux temps réel ne remonte que quatre-vingt-dix jours ;
    // les mois plus anciens sont lus à la demande. On les réunit ici, en
    // écartant les doublons : un mois d'archive peut chevaucher le flux.
    final myMeals = mineShown
        ? <String, PlannedMeal>{
            for (final m in myMealsAsync.value ?? const <PlannedMeal>[])
              m.id: m,
            for (final month in _archive.values)
              for (final m in month) m.id: m,
          }.values.toList()
        : const <PlannedMeal>[];
    // L'export vers le calendrier ne porte que sur mes repas, et est réservé
    // à qui planifie.
    final canExport = canPlan && myMeals.isNotEmpty;
    // Les courses portent sur tous les plannings affichés, pour tous les
    // rôles : les articles vont dans le panier de celui qui regarde.
    final shownMeals = [...myMeals, ...sharedMeals];
    final canShopPeriod = _periodMealsToShop(shownMeals).isNotEmpty;

    final showSelector = options.length > 1 || (!canPlan && options.isNotEmpty);

    // Suggestions de repas : celles que j'ai faites aux groupes dont je suis
    // membre, celles que je reçois pour les groupes dont je suis
    // propriétaire. Une lecture en échec est signalée par le repository ; la
    // fenêtre des suggestions l'affiche.
    final suggestableIds = {
      for (final g in ref.watch(suggestableGroupsProvider)) g.id,
    };
    final ownerSuggestIds = {
      for (final g in ref.watch(suggestionOwnerGroupsProvider)) g.id,
    };
    final sentSuggestions =
        ref.watch(sentSuggestionsProvider).value ?? const <MealSuggestion>[];
    final receivedSuggestions =
        ref.watch(receivedSuggestionsProvider).value ??
        const <MealSuggestion>[];

    final view = _PlanningView(
      myUid: myUid,
      canPlan: canPlan,
      mineShown: mineShown,
      othersShown: shownOthers.isNotEmpty || shownGroups.isNotEmpty,
      names: {
        for (final o in options)
          if (!o.isGroup) o.uid: o.isMine ? 'Vous' : o.name,
      },
      groupNames: {for (final o in shownGroups) o.groupId!: o.name},
      writableGroups: [
        if (canPlan)
          for (final o in shownGroups)
            if (o.isOrganizer) o,
      ],
      shownCount: options.where((o) => o.shown).length,
      selectorOnWide: isWide && showSelector,
      suggestGroups: {
        for (final o in shownGroups)
          if (!o.isOrganizer && suggestableIds.contains(o.groupId))
            o.groupId!: o.name,
      },
      ownerSuggestGroups: {
        for (final o in shownGroups)
          if (o.isOrganizer && ownerSuggestIds.contains(o.groupId))
            o.groupId!: o.name,
      },
      sentSuggestions: sentSuggestions,
      receivedSuggestions: receivedSuggestions,
    );

    final Widget content;
    if ((!myMealsAsync.hasValue && !myMealsAsync.hasError) ||
        (!optionsAsync.hasValue && !optionsAsync.hasError)) {
      content = const AppLoadingState();
    } else if (myMealsAsync.hasError && !myMealsAsync.hasValue) {
      content = AppErrorState(
        error: myMealsAsync.error,
        onRetry: _refreshMeals,
      );
    } else {
      content = _buildContent(
        context,
        theme,
        view,
        meals: shownMeals,
        isWide: isWide,
        sharedLoading: sharedLoading,
        // Une portée en erreur n'est pas une portée vide.
        reachEmpty:
            reachAsync.hasValue &&
            (reachAsync.value ?? PlanningReach.empty).isEmpty,
        reachFailed: reachAsync.hasError && !reachAsync.hasValue,
        anyShown: options.any((o) => o.shown),
        mineOffered: options.any((o) => o.isMine),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Planning des repas'),
        centerTitle: false,
        actions: [
          if (isWide) ...[
            // Sur grand écran, le bouton rejoint la barre : il ne flotte plus
            // au-dessus des repas.
            if (canPlan)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: FilledButton.icon(
                  onPressed: () => openNewPlanning(context, ref),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('Nouveau planning'),
                ),
              ),
            MealSuggestionsButton(
              onPlan: _planSuggestion,
              onSearch: _searchSuggestion,
            ),
            // Le « tirer pour rafraîchir » du corps n'existe pas à la souris.
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Actualiser le planning',
              onPressed: _refreshMeals,
            ),
            if (canShopPeriod)
              IconButton(
                icon: _periodShopping
                    ? const SizedBox(
                        width: AppIconSize.small,
                        height: AppIconSize.small,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_shopping_cart),
                tooltip: _periodShopping
                    ? 'Préparation des courses…'
                    : 'Ajouter la période aux courses',
                onPressed: _periodShopping
                    ? null
                    : () => _addPeriodToShopping(shownMeals, view),
              ),
            const ShoppingCartButton(),
            if (canExport) ...[
              // La même icône que sur chaque repas et chaque créneau : un
              // geste, une icône. Elle reste distincte de celle du calendrier
              // de l'écran, qui sert à voir, pas à envoyer.
              IconButton(
                icon: const Icon(AppIcons.calendarExport),
                tooltip: 'Exporter le planning vers le calendrier',
                onPressed: () => _exportAllToCalendar(myMeals),
              ),
            ],
            if (canPlan)
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'Préférences du planning',
                onPressed: () => context.push('/planning/config'),
              ),
          ] else ...[
            MealSuggestionsButton(
              onPlan: _planSuggestion,
              onSearch: _searchSuggestion,
            ),
            const ShoppingCartButton(),
            PopupMenuButton<int>(
              tooltip: 'Actions',
              onSelected: (value) {
                if (value == 0 && canPlan) context.push('/planning/config');
                if (value == 3) _chooseDates();
                if (value == 1 && canShopPeriod) {
                  _addPeriodToShopping(shownMeals, view);
                }
                if (value == 2 && canExport) _exportAllToCalendar(myMeals);
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
                if (canPlan)
                  const PopupMenuItem(
                    value: 0,
                    child: ListTile(
                      leading: Icon(Icons.settings_outlined),
                      title: Text('Préférences du planning'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (canShopPeriod)
                  const PopupMenuItem(
                    value: 1,
                    child: ListTile(
                      leading: Icon(Icons.add_shopping_cart),
                      title: Text('Ajouter la période aux courses'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                if (canExport) ...[
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
      floatingActionButton: isWide || !canPlan
          ? null
          : AnimatedSlide(
              offset: _fabHidden ? const Offset(0, 2) : Offset.zero,
              duration: const Duration(milliseconds: 200),
              child: FloatingActionButton.extended(
                onPressed: () => openNewPlanning(context, ref),
                // Étendu, le libellé se lit déjà : l'infobulle le doublerait.
                tooltip: _fabCompact ? 'Nouveau planning' : null,
                isExtended: !_fabCompact,
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Nouveau planning'),
              ),
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isWide && showSelector) const PlanningOwnersChipRow(),
          // Mes repas sont là ; les plannings partagés arrivent encore. Ou
          // la période part aux courses : sur téléphone, le menu ⋮ s'est
          // refermé, la barre dit que le geste est pris.
          if ((sharedLoading && myMealsAsync.hasValue) ||
              (_periodShopping && !isWide))
            const LinearProgressIndicator(),
          if (reachAsync.hasError && !reachAsync.hasValue)
            _PlanningReadFailure(
              message: 'Les plannings partagés n\'ont pas pu être lus.',
              onRetry: () => ref.invalidate(planningReachProvider),
            ),
          for (final owner in failed)
            _PlanningReadFailure(
              message: 'Le planning de ${owner.name} n\'a pas pu être lu.',
              onRetry: () =>
                  ref.invalidate(sharedPlannedMealsProvider(owner.uid)),
            ),
          for (final group in failedGroups)
            _PlanningReadFailure(
              message:
                  'Le planning du groupe ${group.name} n\'a pas pu être lu.',
              onRetry: () =>
                  ref.invalidate(groupPlannedMealsProvider(group.groupKey)),
            ),
          Expanded(
            child: RefreshIndicator(onRefresh: _refreshMeals, child: content),
          ),
        ],
      ),
    );
  }

  /// Un planning partagé a cessé de l'être, ou un planning de groupe d'être
  /// accessible : l'entrée quitte le sélecteur, et l'écran le dit une fois.
  void _onReachChanged(
    AsyncValue<PlanningReach>? previous,
    AsyncValue<PlanningReach> next,
  ) {
    final before = previous?.value;
    final after = next.value;
    if (before == null || after == null || !mounted) return;
    for (final uid in before.uids.difference(after.uids)) {
      final name = _ownerNames[uid] ?? UserProfile.fallbackName;
      context.showSnackBar(
        'Le planning de $name n\'est plus partagé avec vous.',
      );
    }
    final groupsBefore = before.groupIds, groupsAfter = after.groupIds;
    if (groupsBefore == null || groupsAfter == null) return;
    for (final groupId in groupsBefore.difference(groupsAfter)) {
      // Un groupe qu'on ne proposait pas n'est pas nommé : rien à dire.
      final name = _groupNames[groupId];
      if (name == null) continue;
      context.showSnackBar(
        'Le planning du groupe $name ne vous est plus accessible.',
      );
    }
  }

  /// Ce qu'affiche le corps une fois les repas lus : un état vide, ou la
  /// période.
  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    _PlanningView view, {
    required List<PlannedMeal> meals,
    required bool isWide,
    required bool sharedLoading,
    required bool reachEmpty,
    required bool reachFailed,
    required bool anyShown,
    required bool mineOffered,
  }) {
    if (!anyShown) {
      // Les plannings partagés n'ont pas pu être lus : le dire, pas
      // prétendre que personne ne partage.
      if (reachFailed) {
        return _withSelectorOnWide(
          view,
          AppErrorState(
            error: ref.read(planningReachProvider).error,
            title: 'Les plannings partagés n\'ont pas pu être lus',
            onRetry: () => ref.invalidate(planningReachProvider),
          ),
        );
      }
      if (!view.canPlan && reachEmpty) {
        return _withSelectorOnWide(
          view,
          _buildReaderWithoutShares(hasOwnMeals: mineOffered),
        );
      }
      return _withSelectorOnWide(
        view,
        AppEmptyState(
          icon: Icons.visibility_off_outlined,
          title: 'Aucun planning affiché.',
          // Sur grand écran, la carte « Plannings affichés » est déjà là.
          action: view.selectorOnWide
              ? null
              : FilledButton.icon(
                  onPressed: () => showPlanningOwnersSheet(context),
                  icon: const Icon(Icons.people_outline),
                  label: const Text('Choisir les plannings'),
                ),
        ),
      );
    }
    // Seuls des plannings partagés sont affichés, et ils arrivent encore :
    // des jours « Rien de prévu » seraient faux.
    if (sharedLoading && !view.mineShown) return const AppLoadingState();
    // Un membre d'un groupe garde les jours : c'est là qu'il suggère un plat.
    if (meals.isEmpty &&
        view.canPlan &&
        view.mineShown &&
        !sharedLoading &&
        view.suggestGroups.isEmpty) {
      return _withSelectorOnWide(view, _buildPlannerEmptyState(theme));
    }
    return _buildPeriod(context, theme, meals, isWide, view);
  }

  /// Sur grand écran, la carte des plannings reste visible au-dessus d'un
  /// état vide : c'est d'elle que vient la solution.
  Widget _withSelectorOnWide(_PlanningView view, Widget child) {
    if (!view.selectorOnWide) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(width: 360, child: PlanningOwnersCard()),
        Expanded(child: child),
      ],
    );
  }

  /// Un lecteur à qui personne ne partage de planning : sans groupe, on lui
  /// dit d'en rejoindre un ; membre, on lui dit qui peut partager. Quand tous
  /// ses groupes sont en pause (propriétaire qui n'est plus éditeur), on le
  /// dit : il en possède un, ou il attend celui d'un proche.
  ///
  /// Les deux lectures (groupes, groupes en pause) arrivent avant tout état
  /// vide, et une erreur se dit avant la pause.
  ///
  /// Un lecteur qui garde d'anciens repas apprend où les retrouver.
  Widget _buildReaderWithoutShares({required bool hasOwnMeals}) {
    const ownMealsHint =
        'Cochez « Mon planning » pour revoir vos anciens repas.';
    String withHint(String text) => hasOwnMeals ? '$text $ownMealsHint' : text;
    final groups = ref.watch(myGroupsProvider);
    final paused = ref.watch(myPausedGroupsProvider);
    if (groups.hasError && !groups.hasValue) {
      return AppErrorState(
        error: groups.error,
        title: 'Vos groupes familiaux n\'ont pas pu être lus',
        onRetry: () => ref.invalidate(myGroupsProvider),
      );
    }
    if (paused.hasError && !paused.hasValue) {
      return AppErrorState(
        error: paused.error,
        title: 'Vos groupes familiaux n\'ont pas pu être lus',
        onRetry: () => ref.invalidate(maskedGroupIdsProvider),
      );
    }
    if (!groups.hasValue || !paused.hasValue) return const AppLoadingState();
    final all = groups.value!;
    final pausedGroups = paused.value!;
    final active = all.length - pausedGroups.length;
    if (all.isNotEmpty && active == 0) {
      final myUid = ref.read(appUserProvider).value?.uid;
      final owned = [
        for (final g in pausedGroups)
          if (g.ownerId == myUid) g,
      ];
      if (owned.isNotEmpty) {
        return AppEmptyState(
          icon: Icons.pause_circle_outline,
          title: pausedGroupsTitle(owned)!,
          message: withHint(pausedGroupsMessage(owned.length)),
        );
      }
      final several = pausedMemberGroupsTitle(pausedGroups);
      if (several != null) {
        return AppEmptyState(
          icon: Icons.pause_circle_outline,
          title: several,
          message: hasOwnMeals ? ownMealsHint : null,
        );
      }
      final group = pausedGroups.single;
      final ownerName =
          ref.watch(memberNameProvider(group.ownerId)) ??
          UserProfile.fallbackName;
      return AppEmptyState(
        icon: Icons.pause_circle_outline,
        title: 'Le groupe ${group.name} est en pause.',
        message: withHint(pausedMemberGroupMessage(ownerName)),
      );
    }
    if (all.isEmpty) {
      return AppEmptyState(
        icon: Icons.group_outlined,
        title: 'Vous ne faites partie d\'aucun groupe familial.',
        message: withHint(
          'Rejoignez le groupe de votre famille pour voir ses plannings.',
        ),
        action: FilledButton.icon(
          onPressed: () => context.push('/groups'),
          icon: const Icon(Icons.group_outlined),
          label: const Text('Voir les groupes familiaux'),
        ),
      );
    }
    return AppEmptyState(
      icon: Icons.calendar_today_outlined,
      title: 'Aucun planning n\'est partagé avec vous.',
      message: withHint(
        'Un membre de votre groupe peut partager le sien depuis les '
        'préférences de son planning.',
      ),
    );
  }

  /// Le planning vide de qui planifie : créer un planning, ou régler ses
  /// préférences.
  Widget _buildPlannerEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_today_outlined,
              size: AppIconSize.hero,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
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
              onPressed: () => openNewPlanning(context, ref),
              icon: const Icon(Icons.auto_awesome_outlined),
              label: const Text('Générer un nouveau planning'),
            ),
            const SizedBox(height: 12),
            // Accès direct aux préférences
            OutlinedButton.icon(
              onPressed: () => context.push('/planning/config'),
              icon: const Icon(Icons.tune_outlined),
              label: const Text('Préférences du planning'),
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

  /// L'écran : le calendrier, puis les jours de la période choisie.
  ///
  /// Aucun document n'est créé pour cette vue : elle range par jour les repas
  /// des plannings affichés et ceux de l'archive déjà lue. Une semaine est
  /// une lecture, pas un porteur.
  Widget _buildPeriod(
    BuildContext context,
    ThemeData theme,
    List<PlannedMeal> meals,
    bool isWide,
    _PlanningView view,
  ) {
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

    final days = _buildPeriodDays(theme, meals, period, today, isWide, view);

    if (isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 360,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 8),
              child: view.selectorOnWide
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [const PlanningOwnersCard(), calendar],
                    )
                  : calendar,
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
  ///
  /// Une seule liste par jour : mes repas d'abord, puis ceux des autres par
  /// ordre alphabétique de leur prénom, par heure à l'intérieur.
  Widget _buildPeriodDays(
    ThemeData theme,
    List<PlannedMeal> meals,
    PlanningPeriod period,
    DateTime today,
    bool isWide,
    _PlanningView view,
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
      list.sort(view.compare);
    }

    _dayKeys.removeWhere((day, _) => !period.contains(day));
    _resolveSharedRecipes(meals, period, view);
    if (view.canPlan) {
      _resolveMyMealRecipes(meals, period, view);
      _stapleCategories = {
        for (final u in ref.watch(myStaplesProvider).value ?? const [])
          u.staple.id: u.staple.category,
      };
    }

    final locked = {
      for (final e in _readableRecipes.entries)
        if (!e.value) e.key,
    };

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
                ..._buildDayMeals(
                  day: day,
                  isPast: day.isBefore(today),
                  meals: grouped[day] ?? const [],
                  isWide: isWide,
                  view: view,
                  locked: locked,
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
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // La même ligne que la tuile du repas : la recette
                          // d'un autre membre peut ne pas se lire.
                          if (!view.ownsMeal(meal) &&
                              locked.contains(meal.recipeId))
                            const PlanningRecipeNotSharedLine(),
                          Text(
                            [
                              if (view.labelsOwners) view.labelOf(meal),
                              'pour le ${DateFormat('EEEE d MMMM', 'fr').format(meal.plannedAt)}',
                            ].join(' · '),
                          ),
                        ],
                      ),
                      onTap: _openRecipeIfReadable(meal, view),
                    ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  /// Les repas d'un jour, et les lignes « Rien de prévu » quand il le faut.
  ///
  /// Une ligne « Choisir une recette » par planning où l'utilisateur planifie
  /// — le sien, ceux des groupes dont il est le propriétaire — affiché et vide
  /// ce jour-là : « Rien de prévu pour vous », « Rien de prévu pour Famille
  /// Dupont ». Elles viennent avant les repas. Un seul planning affiché, et
  /// c'est le sien : « Rien de prévu », comme avant. Le lecteur, qui ne
  /// planifie pas, lit seulement « Rien de prévu » un jour sans aucun repas.
  List<Widget> _buildDayMeals({
    required DateTime day,
    required bool isPast,
    required List<PlannedMeal> meals,
    required bool isWide,
    required _PlanningView view,
    required Set<String> locked,
  }) {
    final own = [
      for (final m in meals)
        if (view.ownsMeal(m)) m,
    ];
    final others = [
      for (final m in meals)
        if (!view.ownsMeal(m)) m,
    ];
    final targets = view.writableTargets;
    final emptyRows = <Widget>[];
    for (final target in targets) {
      final filled = own.any((m) => m.groupId == target.groupId);
      if (filled) continue;
      final alone = targets.length == 1 && view.shownCount <= 1;
      emptyRows.add(
        PlanningEmptyDayRow(
          isPast: isPast,
          label: alone
              ? 'Rien de prévu'
              : target.isGroup
              ? 'Rien de prévu pour ${target.groupName}'
              : 'Rien de prévu pour vous',
          onPick: isPast ? null : () => _addMealOnDay(day, target: target),
        ),
      );
    }
    // Les plannings de groupe dont je suis membre sans en être le
    // propriétaire : un jour sans repas du groupe propose de suggérer un
    // plat (aujourd'hui et après), et montre mes suggestions.
    for (final entry in view.suggestGroups.entries) {
      if (others.any((m) => m.groupId == entry.key)) continue;
      emptyRows.add(
        PlanningEmptyDayRow(
          isPast: isPast,
          label: view.shownCount <= 1
              ? 'Rien de prévu'
              : 'Rien de prévu pour ${entry.value}',
          actionLabel: 'Suggérer un plat',
          actionIcon: Icons.lightbulb_outline,
          onPick: _canSuggestOn(day, isPast: isPast)
              ? () => _suggestOnDay(day, entry.key)
              : null,
        ),
      );
      emptyRows.addAll(
        _memberSuggestionRows(
          day: day,
          isPast: isPast,
          groupId: entry.key,
          groupMeals: const [],
          view: view,
          withButton: false,
        ),
      );
    }
    if (emptyRows.isEmpty && meals.isEmpty) {
      emptyRows.add(PlanningEmptyDayRow(isPast: isPast));
    }
    // Le repère du propriétaire : les suggestions reçues pour ce jour, par
    // groupe affiché.
    final markers = <Widget>[
      for (final entry in view.ownerSuggestGroups.entries)
        if (view.receivedOn(day, entry.key) case final count when count > 0)
          SuggestionsDayMarker(
            count: count,
            groupName: view.ownerSuggestGroups.length > 1 ? entry.value : null,
            onTap: () => showMealSuggestionsWindow(
              context,
              onPlan: _planSuggestion,
              onSearch: _searchSuggestion,
              focusDay: day,
              groupId: entry.key,
            ),
          ),
    ];
    final otherRows = <Widget>[];
    for (var i = 0; i < others.length; i++) {
      final meal = others[i];
      otherRows.add(
        PlanningMealTile(
          meal: meal,
          isPast: isPast,
          aiLoading: _shoppingMealIds.contains(meal.id),
          isWide: isWide,
          readOnly: true,
          onAddToShopping: _shopActionFor(meal, isPast: isPast, locked: locked),
          ownerName: view.labelOf(meal),
          ownerIsGroup: meal.isGroupMeal,
          lockedRecipeIds: locked,
          // Pendant la résolution, un composant-recette ne s'ouvre pas plus
          // que le plat.
          openableRecipeIds: {
            for (final c in meal.components)
              if (_canOpenShared(c.recipeId)) c.recipeId!,
          },
          onTap: _openRecipeIfReadable(meal, view),
          onComponentTap: (c) => _openComponentRecipe(meal, c),
        ),
      );
      // Sous le dernier repas d'un groupe dont je suis membre : mes
      // suggestions et « Suggérer un plat ».
      final groupId = meal.groupId;
      final lastOfGroup =
          groupId != null &&
          (i == others.length - 1 || others[i + 1].groupId != groupId);
      if (lastOfGroup && view.suggestGroups.containsKey(groupId)) {
        otherRows.addAll(
          _memberSuggestionRows(
            day: day,
            isPast: isPast,
            groupId: groupId,
            groupMeals: [
              for (final m in others)
                if (m.groupId == groupId) m,
            ],
            view: view,
          ),
        );
      }
    }
    return [
      ...emptyRows,
      for (final meal in own) _buildMyMeal(meal, isPast, isWide, view),
      ...markers,
      ...otherRows,
    ];
  }

  /// Un de mes repas : de mon planning, ou du planning d'un groupe dont je
  /// suis le propriétaire. Qui planifie a toutes les actions ; le lecteur —
  /// propriétaire rétrogradé compris — relit ses repas antérieurs et les
  /// ajoute à ses courses, sans les modifier ni les supprimer : les règles
  /// Firestore le lui refusent.
  Widget _buildMyMeal(
    PlannedMeal meal,
    bool isPast,
    bool isWide,
    _PlanningView view,
  ) {
    if (!view.canPlan) {
      return PlanningMealTile(
        meal: meal,
        isPast: isPast,
        aiLoading: _shoppingMealIds.contains(meal.id),
        isWide: isWide,
        readOnly: true,
        ownerName: view.labelsOwners ? view.labelOf(meal) : null,
        ownerIsGroup: meal.isGroupMeal,
        onAddToShopping: _shopActionFor(meal, isPast: isPast),
        onTap: _openRecipeFor(meal),
        onComponentTap: (c) => _openComponentRecipe(meal, c),
      );
    }
    return PlanningMealTile(
      meal: meal,
      isPast: isPast,
      aiLoading:
          _aiLoadingIds.contains(meal.id) ||
          _storageLoadingIds.contains(meal.id) ||
          _shoppingMealIds.contains(meal.id),
      isWide: isWide,
      ownerName: view.labelsOwners ? view.labelOf(meal) : null,
      ownerIsGroup: meal.isGroupMeal,
      onDelete: () => _deleteMeal(meal),
      onChangeRecipe: () => _changeRecipe(meal),
      onReschedule: () => _rescheduleMeal(meal),
      onCompose: () => _composeMeal(meal),
      onComplete: (need) => _completeMeal(meal, need),
      sideStatus: _sideStatusFor(meal),
      onRemoveComponent: (c) => _removeComponent(meal, c),
      onClearRecipe: () => _clearRecipe(meal),
      onOtherSuggestion: () => _otherSuggestion(meal),
      onStorageAdvice: () => _showStorageAdvice(meal),
      onTimeChanged: () => _changeTime(meal),
      onExportToCalendar: () => _exportMealToCalendar(meal),
      onAddToShopping: _shopActionFor(meal, isPast: isPast),
      onTap: _openRecipeFor(meal),
      onComponentTap: (c) => _openComponentRecipe(meal, c),
    );
  }

  /// La fiche d'un repas, si son plat se lit : les miens toujours, ceux des
  /// autres une fois leur recette résolue et lisible.
  VoidCallback? _openRecipeIfReadable(PlannedMeal meal, _PlanningView view) {
    if (view.ownsMeal(meal)) return _openRecipeFor(meal);
    if (!_canOpenShared(meal.recipeId)) return null;
    return _openRecipeFor(meal);
  }

  /// La recette d'un repas d'autrui s'ouvre-t-elle ? Oui si elle se lit ;
  /// oui aussi quand la résolution a échoué : la fiche dit elle-même
  /// « Recette non partagée » sur un refus. Non tant qu'elle se résout.
  bool _canOpenShared(String? id) {
    if (id == null || id.isEmpty) return false;
    return _readableRecipes[id] == true || _readableFailed.contains(id);
  }

  /// Résout, par une lecture groupée, la lisibilité des recettes des repas
  /// d'autrui dans [period]. On n'élargit pas la lecture des recettes : une
  /// recette refusée s'affiche par son titre, « Recette non partagée ».
  void _resolveSharedRecipes(
    List<PlannedMeal> meals,
    PlanningPeriod period,
    _PlanningView view,
  ) {
    final ids =
        <String>{
          for (final m in meals)
            if (!view.ownsMeal(m) &&
                period.contains(PlanningPeriodCalendar.dayOf(m.plannedAt))) ...[
              if (m.recipeId != null && m.recipeId!.isNotEmpty) m.recipeId!,
              for (final c in m.components)
                if (c.isRecipe && (c.recipeId ?? '').isNotEmpty) c.recipeId!,
            ],
        }..removeWhere(
          (id) =>
              _readableRecipes.containsKey(id) ||
              _readablePending.contains(id) ||
              _readableFailed.contains(id),
        );
    if (ids.isEmpty) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    _readablePending.addAll(ids);
    // Après le rendu : l'écran se met à jour quand la lecture revient.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final readable = await repo.readableRecipeIds(ids);
        if (!mounted) return;
        setState(() {
          for (final id in ids) {
            _readableRecipes[id] = readable.contains(id);
          }
          _readablePending.removeAll(ids);
        });
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'planningScreen.resolveSharedRecipes',
          error: e,
          stackTrace: stackTrace,
          context: {'recipe_count': ids.length},
        );
        if (!mounted) return;
        setState(() {
          _readablePending.removeAll(ids);
          _readableFailed.addAll(ids);
        });
      }
    });
  }

  /// Lit, par lots, les recettes de mes repas de la période — le plat et les
  /// accompagnements qui sont des recettes — pour dire ce qui manque au
  /// plat. Même lecture groupée que pour les repas d'autrui ; une recette
  /// refusée ou supprimée n'est pas rendue, et la tuile ne dit rien.
  void _resolveMyMealRecipes(
    List<PlannedMeal> meals,
    PlanningPeriod period,
    _PlanningView view,
  ) {
    final ids =
        <String>{
          for (final m in meals)
            if (view.ownsMeal(m) &&
                period.contains(PlanningPeriodCalendar.dayOf(m.plannedAt))) ...[
              if ((m.recipeId ?? '').isNotEmpty) m.recipeId!,
              for (final c in m.components)
                if (c.isMainSide && c.isRecipe) c.recipeId!,
            ],
        }..removeWhere(
          (id) =>
              _mealRecipes.containsKey(id) ||
              _mealRecipesPending.contains(id) ||
              _mealRecipesFailed.contains(id),
        );
    if (ids.isEmpty) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    _mealRecipesPending.addAll(ids);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final recipes = await repo.getRecipesByIds(ids.toList());
        if (!mounted) return;
        setState(() {
          for (final r in recipes) {
            _mealRecipes[r.id] = r;
          }
          _mealRecipesPending.removeAll(ids);
          // Lue sans résultat : refusée ou supprimée, pas de nouvel essai.
          _mealRecipesFailed.addAll(
            ids.where((id) => !_mealRecipes.containsKey(id)),
          );
        });
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'planningScreen.resolveMyMealRecipes',
          error: e,
          stackTrace: stackTrace,
          context: {'recipe_count': ids.length},
        );
        if (!mounted) return;
        setState(() {
          _mealRecipesPending.removeAll(ids);
          _mealRecipesFailed.addAll(ids);
        });
      }
    });
  }

  /// Ce qui manque au plat de [meal], en comptant ses accompagnements ; `null`
  /// tant que sa recette n'est pas lue, ou pour un repas libre.
  DishSideStatus? _sideStatusFor(PlannedMeal meal) {
    final main = _mealRecipes[meal.recipeId];
    if (main == null) return null;
    return dishSideStatus(
      mainTags: main.tags,
      sides: meal.components.where((c) => c.isMainSide),
      stapleCategories: _stapleCategories,
      recipesById: _mealRecipes,
    );
  }

  /// Pose une recette sur un jour libre de la période lue, dans le planning
  /// [target] : le sien, ou celui d'un groupe dont on est le propriétaire.
  ///
  /// Le repas prend l'heure et les parts de son jour de semaine, comme dans
  /// « Nouveau planning » ; pour un groupe, les parts du groupe (réglées,
  /// sinon son nombre de membres). L'heure se change ensuite d'un appui sur
  /// le repas.
  Future<void> _addMealOnDay(
    DateTime day, {
    PlanningTarget target = const PlanningTarget.personal(),
  }) async {
    final recipe = await _pickRecipeForDay(day);
    if (recipe == null || !mounted) return;
    await _placeRecipeOnDay(day, recipe, target: target);
  }

  /// Le sélecteur de recette d'un jour : recettes validées du compte, nom
  /// libre, et l'IA pour qui peut créer. [initialQuery] pré-remplit la
  /// recherche (suggestion d'un membre à planifier).
  Future<Recipe?> _pickRecipeForDay(
    DateTime day, {
    String initialQuery = '',
  }) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return null;
    final canCreate = ref.read(canEditProvider);
    return showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: _availableRecipes,
        hintText: 'Rechercher ou saisir un nom libre…',
        freeNameAlways: true,
        initialQuery: initialQuery,
        onGenerateIdeas: canCreate ? _generateMealIdeas : null,
        onConceiveIdea: canCreate
            ? (idea) => _conceiveMealIdea(idea, on: day)
            : null,
      ),
    );
  }

  /// Écrit le repas [recipe] le jour [day] dans le planning [target] et rend
  /// son identifiant, ou `null` si l'écriture a échoué (signalée au rapport
  /// d'erreurs, et à l'écran du planning si [showError]).
  Future<String?> _placeRecipeOnDay(
    DateTime day,
    Recipe recipe, {
    PlanningTarget target = const PlanningTarget.personal(),
    bool showError = true,
  }) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return null;
    final prefs =
        ref.read(planningPreferencesProvider).value ??
        const PlanningPreferences();
    final time = prefs.mealTimeFor(day.weekday);
    final constraint = prefs.dailyConstraints[day.weekday];
    final group = target.isGroup
        ? ref
              .read(myGroupsProvider)
              .value
              ?.where((g) => g.id == target.groupId)
              .firstOrNull
        : null;
    final targetPortions = group != null
        ? groupDefaultPortions(groupPortions: prefs.groupPortions, group: group)
        : (constraint?.targetPortions ?? 0) > 0
        ? constraint!.targetPortions
        : recipe.portions;
    final prepMinutes = recipe.tags.prepTime;
    final cookMinutes = recipe.tags.cookTime;
    try {
      return await repo.addMeal(
        PlannedMeal(
          id: '',
          uid: repo.uid,
          groupId: target.groupId,
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
        context: {'group_id': ?target.groupId},
      );
      if (showError && mounted) {
        context.showErrorSnackBar('Repas non enregistré : $e');
      }
      return null;
    }
  }

  // ── Suggestions des membres ───────────────────────────────────────────────

  /// Le groupe de la suggestion et le dépôt du planning, ou
  /// [PlanSuggestionFailure] quand l'un des deux manque.
  (FamilyGroup, PlanningRepository) _suggestionGroupAndRepo(
    MealSuggestion suggestion,
  ) {
    final group = ref
        .read(suggestionOwnerGroupsProvider)
        .where((g) => g.id == suggestion.groupId)
        .firstOrNull;
    final repo = ref.read(planningRepositoryProvider);
    if (group == null || repo == null) {
      reportUnexpectedError(
        feature: 'meal_suggestions.plan_group_missing',
        error: StateError('Groupe ou planning indisponible'),
        stackTrace: StackTrace.current,
        context: {
          'group_id': suggestion.groupId,
          'group_found': group != null,
          'repo_ready': repo != null,
        },
      );
      throw const PlanSuggestionFailure(
        'Ce groupe n\'est plus accessible. Réessayez.',
      );
    }
    return (group, repo);
  }

  /// « Chercher » : l'Explorer en mode choix, pré-rempli du titre de la
  /// suggestion, puis un calendrier posé sur son jour. Le repas est posé dans
  /// le planning du groupe, aux parts du groupe. Une idée de l'IA enregistrée
  /// en brouillon est posée en texte libre. La suggestion n'est pas modifiée.
  Future<PlannedSuggestion?> _searchSuggestion(
    MealSuggestion suggestion,
  ) async {
    final (group, _) = _suggestionGroupAndRepo(suggestion);
    final dayLabel = DateFormat('EEEE d MMMM', 'fr').format(suggestion.day);
    final choice = await Navigator.of(context, rootNavigator: true)
        .push<ExploreChoice>(
          MaterialPageRoute(
            builder: (_) => SearchScreen(
              pick: ExplorePick(
                initialQuery: suggestion.title,
                banner: 'Recette pour $dayLabel, ${group.name}',
              ),
            ),
          ),
        );
    if (choice == null || !mounted) return null;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: suggestion.day.isBefore(today) ? today : suggestion.day,
      firstDate: today,
      lastDate: lastSuggestionDay(today),
      helpText: 'Planifier quel jour ?',
      confirmText: 'Planifier',
    );
    if (picked == null || !mounted) return null;
    final day = DateTime(picked.year, picked.month, picked.day);
    final recipe = choice.recipe ?? _freeTextRecipe(choice.title);
    final mealId = await _placeRecipeOnDay(
      day,
      recipe,
      target: PlanningTarget.ofGroup(group),
      showError: false,
    );
    if (mealId == null) {
      throw const PlanSuggestionFailure('Repas non enregistré. Réessayez.');
    }
    return PlannedSuggestion(
      title: choice.title,
      mealId: mealId,
      day: day,
      groupName: group.name,
      draft: choice.recipe == null,
    );
  }

  /// Un repas sans recette : le titre seul, comme un nom libre du sélecteur.
  Recipe _freeTextRecipe(String title) => Recipe(
    id: '',
    titre: title,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: '',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  /// « Planifier ce jour-là » : le propriétaire pose dans le planning du
  /// groupe le plat qu'un membre a suggéré. Une recette qu'il lit est posée
  /// telle quelle, aux parts du groupe ; un nom libre ou une recette qu'il
  /// ne lit pas ouvre le sélecteur, pré-rempli du titre. La suggestion n'est
  /// pas modifiée : « Au planning » se calcule à l'affichage.
  Future<PlannedSuggestion?> _planSuggestion(MealSuggestion suggestion) async {
    final (group, repo) = _suggestionGroupAndRepo(suggestion);
    final target = PlanningTarget.ofGroup(group);
    Recipe? recipe;
    final recipeId = suggestion.recipeId;
    if (recipeId != null) {
      try {
        recipe = (await repo.getRecipesByIds([recipeId])).firstOrNull;
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'planningScreen.planSuggestion',
          error: e,
          stackTrace: stackTrace,
          context: {'group_id': group.id, 'recipe_id': recipeId},
        );
        throw const PlanSuggestionFailure(
          'La recette n\'a pas pu être lue. Réessayez.',
        );
      }
    }
    if (!mounted) return null;
    recipe ??= await _pickRecipeForDay(
      suggestion.day,
      initialQuery: suggestion.title,
    );
    if (recipe == null || !mounted) return null;
    final mealId = await _placeRecipeOnDay(
      suggestion.day,
      recipe,
      target: target,
      showError: false,
    );
    if (mealId == null) {
      throw const PlanSuggestionFailure('Repas non enregistré. Réessayez.');
    }
    return PlannedSuggestion(
      title: recipe.titre,
      mealId: mealId,
      day: suggestion.day,
      groupName: group.name,
    );
  }

  /// On suggère un plat d'aujourd'hui à [lastSuggestionDay] : les règles
  /// refusent un jour plus lointain.
  bool _canSuggestOn(DateTime day, {required bool isPast}) {
    if (isPast) return false;
    final now = DateTime.now();
    return !day.isAfter(
      lastSuggestionDay(DateTime(now.year, now.month, now.day)),
    );
  }

  /// « Suggérer un plat » sur le jour [day] du planning du groupe [groupId].
  void _suggestOnDay(DateTime day, String groupId) {
    final groups = ref.read(suggestableGroupsProvider);
    final group = groups.where((g) => g.id == groupId).firstOrNull;
    if (group == null) return;
    openSuggestMeal(context, groups: groups, group: group, day: day);
  }

  /// Les lignes de suggestion d'un groupe dont l'utilisateur est membre, un
  /// jour donné : ses suggestions, puis « Suggérer un plat » (aujourd'hui et
  /// après seulement). [groupMeals] : les repas du groupe ce jour-là.
  List<Widget> _memberSuggestionRows({
    required DateTime day,
    required bool isPast,
    required String groupId,
    required List<PlannedMeal> groupMeals,
    required _PlanningView view,
    bool withButton = true,
  }) {
    final mine = [
      for (final s in view.sentSuggestions)
        if (s.groupId == groupId && s.day == day) s,
    ];
    return [
      for (final s in mine)
        MySuggestionTile(
          suggestion: s,
          planned: plannedMatchFor(s, groupMeals) != null,
        ),
      if (withButton && _canSuggestOn(day, isPast: isPast))
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Wrap(
            children: [
              TextButton.icon(
                onPressed: () => _suggestOnDay(day, groupId),
                icon: const Icon(Icons.lightbulb_outline),
                label: const Text('Suggérer un plat'),
              ),
            ],
          ),
        ),
    ];
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
    // L'archive ne porte que sur mes repas : inutile de la lire quand « Mon
    // planning » n'est pas affiché.
    if (!_mineShown) return;
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
    setState(() {
      _readableRecipes.clear();
      _mealRecipes.clear();
      _mealRecipesFailed.clear();
      _readableFailed.clear();
    });
    ref.invalidate(plannedMealsProvider);
    ref.invalidate(planningReachProvider);
    ref.invalidate(sharedPlannedMealsProvider);
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

/// Ce que la liste du planning sait des plannings affichés.
class _PlanningView {
  final String? myUid;
  final bool canPlan;
  final bool mineShown;

  /// Un planning partagé ou de groupe est affiché à côté du mien.
  final bool othersShown;

  /// Prénom de chaque propriétaire affiché ; « Vous » pour le compte.
  final Map<String, String> names;

  /// Nom de chaque groupe dont le planning est affiché.
  final Map<String, String> groupNames;

  /// Les plannings de groupe affichés où l'utilisateur planifie : il en est
  /// le propriétaire, et il est éditeur.
  final List<PlanningOwnerOption> writableGroups;

  /// Nombre de plannings affichés, le mien compris.
  final int shownCount;

  /// Grand écran avec plusieurs plannings proposés : la carte « Plannings
  /// affichés » est posée au-dessus du calendrier.
  final bool selectorOnWide;

  /// Les plannings de groupe affichés où je suggère un plat (membre, pas
  /// propriétaire) : identifiant du groupe → nom.
  final Map<String, String> suggestGroups;

  /// Les plannings de groupe affichés où je reçois des suggestions
  /// (propriétaire d'un groupe actif qui compte un autre membre).
  final Map<String, String> ownerSuggestGroups;

  /// Mes suggestions envoyées, et celles que je reçois.
  final List<MealSuggestion> sentSuggestions;
  final List<MealSuggestion> receivedSuggestions;

  const _PlanningView({
    required this.myUid,
    required this.canPlan,
    required this.mineShown,
    required this.othersShown,
    required this.names,
    required this.groupNames,
    required this.writableGroups,
    required this.shownCount,
    required this.selectorOnWide,
    this.suggestGroups = const {},
    this.ownerSuggestGroups = const {},
    this.sentSuggestions = const [],
    this.receivedSuggestions = const [],
  });

  /// Le nombre de suggestions reçues pour le groupe [groupId] le jour [day].
  int receivedOn(DateTime day, String groupId) => receivedSuggestions
      .where((s) => s.groupId == groupId && s.day == day)
      .length;

  /// Un repas de mon planning personnel.
  bool isMine(PlannedMeal meal) => meal.uid == myUid && !meal.isGroupMeal;

  /// Un repas que je cuisine : de mon planning, ou d'un groupe dont je suis
  /// le propriétaire. Sa recette est la mienne, il porte mes actions.
  bool ownsMeal(PlannedMeal meal) => meal.uid == myUid;

  /// Les plannings affichés où je planifie, dans l'ordre de la journée :
  /// le mien, puis ceux de mes groupes par nom.
  List<PlanningTarget> get writableTargets => [
    if (canPlan && mineShown) const PlanningTarget.personal(),
    for (final o in writableGroups)
      PlanningTarget.group(
        groupId: o.groupId!,
        groupName: o.name,
        memberCount: 0,
      ),
  ];

  /// Pas d'étiquette quand seul « Mon planning » est affiché.
  bool get labelsOwners => othersShown;

  String nameOf(String uid) =>
      uid == myUid ? 'Vous' : (names[uid] ?? UserProfile.fallbackName);

  /// L'étiquette d'un repas : le nom de son groupe, ou le prénom de son
  /// propriétaire.
  String labelOf(PlannedMeal meal) {
    final groupId = meal.groupId;
    if (groupId != null) return groupNames[groupId] ?? 'Groupe';
    return nameOf(meal.uid);
  }

  /// Rang d'un repas dans la journée : les miens, puis ceux des groupes,
  /// puis les plannings personnels des autres.
  int _rank(PlannedMeal meal) => isMine(meal)
      ? 0
      : meal.isGroupMeal
      ? 1
      : 2;

  /// Mes repas d'abord, puis ceux des groupes par nom de groupe, puis ceux
  /// des autres par prénom, puis par heure.
  int compare(PlannedMeal a, PlannedMeal b) {
    final rankA = _rank(a), rankB = _rank(b);
    if (rankA != rankB) return rankA.compareTo(rankB);
    if (rankA != 0) {
      final byName = labelOf(
        a,
      ).toLowerCase().compareTo(labelOf(b).toLowerCase());
      if (byName != 0) return byName;
      final byKey = (a.groupId ?? a.uid).compareTo(b.groupId ?? b.uid);
      if (byKey != 0) return byKey;
    }
    return a.plannedAt.compareTo(b.plannedAt);
  }
}

/// Un planning partagé illisible : le dire sous son nom, sans masquer les
/// autres, et proposer de réessayer.
class _PlanningReadFailure extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _PlanningReadFailure({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Région vive : le lecteur d'écran annonce l'échec sans qu'on y aille.
    return Semantics(
      liveRegion: true,
      child: Material(
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Row(
            children: [
              Icon(Icons.error_outline, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('Réessayer')),
            ],
          ),
        ),
      ),
    );
  }
}
