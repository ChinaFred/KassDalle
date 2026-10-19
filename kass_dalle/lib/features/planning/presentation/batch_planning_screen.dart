import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../auth/presentation/auth_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/storage_advice.dart';
import '../../groups/presentation/group_providers.dart';
import '../../books/presentation/book_providers.dart';
import '../domain/calendar_event_description.dart';
import '../domain/meal_candidates.dart';
import '../domain/meal_choice_source.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_history.dart';
import '../domain/planning_preferences.dart';
import '../domain/planning_refusals.dart';
import '../domain/planning_target.dart';
import '../../groups/domain/family_group.dart';
import '../domain/ranked_candidates.dart';
import '../domain/registered_meals.dart';
import '../domain/week_replay.dart';
import '../domain/meal_component.dart';
import '../domain/meal_staple.dart';
import '../domain/side_chooser.dart';
import '../services/calendar_service.dart';
import '../services/planning_ai_service.dart';
import 'batch_planning_widgets.dart';
import 'planning_providers.dart';
import 'recipe_picker_sheet.dart';
import 'replay_week_sheet.dart';
import 'side_picker_sheet.dart';
import 'meal_staples_providers.dart';
import '../../recipes/domain/recipe_advice_access.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/presentation/leave_guard.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shortcuts.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_service.dart'
    show GeminiCallableException;
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Décision prise au moment de valider un planning qui recouvre des repas
/// déjà enregistrés.
enum _ValidateChoice { cancel, append, replace }

/// Créneaux d'un cycle, au plus : la borne de `suggestMealPlanFn`.
const kMaxCycleSlots = 31;

/// Choix proposé quand « Autre suggestion » n'a plus de recette.
enum _ExhaustedChoice { pick, conceive }

/// Issue d'une conception : faite, en échec, ou refusée par le plafond de la
/// génération.
enum _ConceptOutcome { done, failed, denied }

/// Écran de génération de planning en masse (Axe B).
///
/// Permet de planifier plusieurs repas d'un coup sur un cycle entier,
/// avec suggestion IA ou assignation manuelle.
///
/// [groupId] : le planning visé est celui de ce groupe, dont l'utilisateur
/// est le propriétaire ; absent, c'est « Mon planning ». La reprise de ce que
/// le planning contient déjà, la validation et « Reprendre une semaine
/// passée » lisent le planning visé ; la fenêtre de variété lit tout ce que
/// l'utilisateur cuisine.
class BatchPlanningScreen extends ConsumerStatefulWidget {
  final String? groupId;

  const BatchPlanningScreen({super.key, this.groupId});

  @override
  ConsumerState<BatchPlanningScreen> createState() =>
      _BatchPlanningScreenState();
}

class _BatchPlanningScreenState extends ConsumerState<BatchPlanningScreen> {
  List<DateTime> _slotDates = [];
  Map<int, Recipe?> _slots = {};
  Map<int, TimeOfDay> _slotTimes = {};
  Map<int, String> _slotJustifications = {};
  Map<int, DateTime?> _slotPrepDates = {};
  Map<int, bool> _slotWasResized = {};
  Map<int, String> _slotResizeReasons = {};
  bool _generating = false;
  bool _saving = false;
  List<Recipe> _availableRecipes = [];
  bool _recipesLoaded = false;
  List<Recipe> _draftRecipes = [];
  List<Recipe> _familyRecipes = [];
  // Périmètre de recherche choisi dans « Où chercher des recettes ? »,
  // persisté sous l'utilisateur (`saveRecipeSearchScope`) : il survit à la
  // fermeture de l'écran, pas seulement à cette session.
  Set<RecipeSource> _selectedSources = {RecipeSource.myRecipes};
  // `null` tant que l'utilisateur n'a jamais restreint sa recherche à des
  // livres précis : la feuille propose alors tous les livres du réservoir,
  // cochés par défaut — la bibliothèque entière, comme avant ce réglage.
  Set<String>? _selectedBookIds;
  // Marque les slots générés par IA (conception)
  Map<int, bool> _slotIsGenerated = {};
  // Qui a choisi la recette de chaque créneau : l'IA, les règles de
  // Kass'Dalle, une conception, ou l'utilisateur.
  Map<int, MealChoiceSource> _slotSources = {};
  // Listes classées par le serveur, par créneau : « Autre suggestion » y
  // pioche sans appel. Retirée quand les contraintes du créneau changent.
  Map<int, SlotRanking> _slotRankings = {};
  // Génération à laquelle se rattachent les conceptions automatiques, et
  // combien elle en permet encore.
  String? _runId;
  int _conceptsRemaining = 0;
  // Bandeau d'avis : l'IA n'a pas répondu, un plafond, des créneaux laissés
  // vides par le plafond de conceptions. [_noticeRetry] : offrir « Réessayer
  // avec l'IA ».
  String? _notice;
  bool _noticeRetry = false;
  // Créneaux dont la recette est en cours de conception.
  final Set<int> _conceivingSlots = {};
  Map<int, DayConstraint> _slotConstraints = {};
  // Recettes écartées de chaque créneau pendant cette session : une nouvelle
  // suggestion ne les repropose pas, et elles suivent le repas à la validation.
  Map<int, Set<String>> _slotDismissed = {};
  // Recettes proposées (IA, règles, conception) que l'utilisateur a écartées
  // pendant cette session. Enregistrées comme refus à la validation du cycle
  // seulement : un cycle abandonné ne laisse aucun refus.
  final Set<String> _refusedIds = {};
  // Identifiant du repas déjà enregistré pour un créneau, depuis son icône
  // calendrier. « Valider » réécrit ce repas sous le même identifiant au lieu
  // d'en créer un second sur la même date. Les repas déjà au planning à
  // l'ouverture y figurent aussi (voir `_prefillRegisteredMeals`).
  Map<int, String> _slotSavedMealIds = {};
  // Les repas déjà au planning sur les dates du cycle, tels qu'ils étaient à
  // l'ouverture, par identifiant. Ils occupent leur créneau : l'IA les
  // contourne, et « Valider » ne les réécrit que s'ils ont changé sur l'écran.
  final Map<String, PlannedMeal> _registeredMeals = {};
  // L'empreinte de chacun juste après sa reprise (`plannedMealContentKey`) :
  // identique à la validation, le repas n'a pas été touché.
  final Map<String, String> _registeredBaseline = {};
  bool _prefillStarted = false;
  // L'accompagnement de chaque créneau, choisi par le programme depuis ce que
  // le plat n'apporte pas. Un accompagnement posé à la main n'est plus
  // recalculé tant que le plat ne change pas.
  Map<int, MealComponent?> _slotSides = {};
  final Set<int> _slotSideManual = {};
  // L'entrée et le dessert d'un créneau dont le format en demande : posés par
  // la suggestion, changés ou retirés à la main.
  Map<int, MealComponent?> _slotStarters = {};
  Map<int, MealComponent?> _slotDesserts = {};
  // Les garnitures de l'utilisateur, lues une fois à l'ouverture.
  List<UserStaple> _staples = const [];
  PlanningPreferences? _prefs;
  final TextEditingController _globalConstraintsCtrl = TextEditingController();
  // Index du slot en cours de génération IA individuelle (null = aucun)
  int? _generatingSlot;
  bool _constraintsLocked = false;
  // Conseils de conservation déjà connus, par identifiant de recette.
  final Map<String, StorageAdvice> _storageAdviceByRecipe = {};

  /// Recettes sans conseil de conservation que l'utilisateur ne peut pas
  /// faire produire (ni créateur ni administrateur). Retenues au premier
  /// essai : le créneau affiche alors une phrase au lieu du bouton.
  final Set<String> _storageReservedRecipeIds = {};
  final Set<int> _storageLoadingSlots = {};

  /// Le cycle vient d'être validé, ou l'utilisateur a renoncé à le valider :
  /// l'écran se quitte sans question.
  bool _validated = false;

  /// Garde de sortie : la question posée avant de quitter un cycle composé
  /// mais pas validé. Un seul objet, pour que la navigation puisse le
  /// reconnaître quand elle le retire.
  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmLeave;
  bool _leaveGuardSet = false;

  /// Les consignes du cycle sont dépliées (téléphone). Gardé ici : la liste
  /// recrée le pli quand il sort de l'écran puis y revient.
  bool _cycleConstraintsExpanded = false;

  TimeOfDay get _defaultTime => TimeOfDay(
    hour: _prefs?.defaultMealHour ?? 19,
    minute: _prefs?.defaultMealMinute ?? 0,
  );

  /// Heure prévue pour une date : celle de son jour de semaine.
  ///
  /// Un créneau ajouté après coup, ou décalé d'un jour, doit prendre l'heure de
  /// son nouveau jour — pas celle de tout le monde.
  TimeOfDay _timeForDate(PlanningPreferences prefs, DateTime date) {
    final t = prefs.mealTimeFor(date.weekday);
    return TimeOfDay(hour: t.hour, minute: t.minute);
  }

  /// La même, avec les préférences déjà chargées.
  TimeOfDay _timeFor(DateTime date) =>
      _prefs == null ? _defaultTime : _timeForDate(_prefs!, date);

  @override
  void initState() {
    super.initState();
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    // Différé : un provider ne se modifie pas pendant le démontage de l'arbre.
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    Future.microtask(() => notifier.clearIf(guard));
    _globalConstraintsCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    try {
      final familyIds = (ref.read(groupMemberIdsProvider).value ?? {}).toList();
      final results = await Future.wait([
        repo.getValidatedRecipes(),
        repo.getMyDraftRecipes(),
        repo.getFamilyValidatedRecipes(
          familyIds.where((id) => id != repo.uid).toList(),
        ),
      ]);
      if (mounted) {
        setState(() {
          _availableRecipes = results[0];
          _draftRecipes = results[1];
          _familyRecipes = results[2];
          _recipesLoaded = true;
        });
      }
      unawaited(_prefillRegisteredMeals());
      // Les garnitures, à part : leur absence ne prive pas de planifier, elle
      // prive seulement d'accompagnements — et le dit dans les rapports.
      try {
        final staples = await ref
            .read(mealStaplesRepositoryProvider)
            .loadMyStaples(repo.uid);
        if (mounted) setState(() => _staples = staples);
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'batchPlanningScreen.loadStaples',
          error: e,
          stackTrace: stackTrace,
        );
      }
      // Le périmètre de recherche, à part aussi : son absence laisse la
      // feuille se rabattre sur ses défauts (recettes validées, tous les
      // livres), pas planifier devenir impossible.
      try {
        final scope = await repo.loadRecipeSearchScope();
        if (mounted && scope != null) {
          setState(() {
            _selectedSources = scope.sources;
            _selectedBookIds = scope.bookIds;
          });
        }
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'batchPlanningScreen.loadRecipeSearchScope',
          error: e,
          stackTrace: stackTrace,
        );
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.init',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _recipesLoaded = true);
        _showError('Impossible de charger les recettes : $e');
        unawaited(_prefillRegisteredMeals());
      }
    }
  }

  void _applyPrefs(PlanningPreferences prefs) {
    if (_prefs != null) return;
    _prefs = prefs;
    final dates = prefs.nextCycleDates();
    _slotDates = dates;
    _slots = {for (int i = 0; i < dates.length; i++) i: null};
    // L'heure d'un créneau est celle de son jour de semaine — la sienne s'il en
    // a une, celle par défaut sinon. Poser l'heure globale partout aurait rendu
    // muet le réglage par jour.
    _slotTimes = {
      for (int i = 0; i < dates.length; i++) i: _timeForDate(prefs, dates[i]),
    };
    // Le planning d'un groupe se cuisine pour le groupe : ses parts par
    // défaut (réglées, sinon le nombre de membres) remplacent celles du jour.
    final group = _group;
    final groupPortions = group == null
        ? null
        : groupDefaultPortions(
            groupPortions: prefs.groupPortions,
            group: group,
          );
    _slotConstraints = {
      for (int i = 0; i < dates.length; i++)
        i: groupPortions == null
            ? prefs.dailyConstraints[dates[i].weekday] ?? const DayConstraint()
            : (prefs.dailyConstraints[dates[i].weekday] ??
                      const DayConstraint())
                  .copyWith(targetPortions: groupPortions),
    };
    _globalConstraintsCtrl.text = prefs.globalConstraints;
    // Les préférences arrivent parfois après les recettes : c'est alors ici que
    // les deux conditions de la reprise sont réunies.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => unawaited(_prefillRegisteredMeals()),
    );
  }

  /// Reprend sur l'écran les repas déjà au planning sur les dates du cycle.
  ///
  /// Sans cette lecture, un jour déjà planifié s'affichait « à assigner » :
  /// « Compléter les créneaux vides » lui cherchait une suggestion, et
  /// « Valider » proposait ensuite de remplacer ou de doubler ce qui existait.
  /// Le repas repris occupe son créneau : l'IA le contourne et le compte dans
  /// la variété du cycle, et « Valider » ne le réécrit que s'il a changé ici.
  ///
  /// Un repas par jour, le premier de la journée. Un repas sans recette liée
  /// (repas libre) est repris sous la forme d'une recette sans identifiant,
  /// comme le sélecteur en rend une.
  Future<void> _prefillRegisteredMeals() async {
    if (_prefillStarted || !_recipesLoaded || _slotDates.isEmpty) return;
    _prefillStarted = true;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;

    final List<PlannedMeal> meals;
    try {
      meals = await repo.getMealsBetween(
        from: _slotDates.first,
        to: _slotDates.last,
        groupId: widget.groupId,
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.prefillRegisteredMeals',
        error: e,
        stackTrace: stackTrace,
      );
      _showError(
        'Impossible de lire les repas déjà au planning : $e. Un créneau '
        'affiché vide peut être déjà occupé.',
      );
      return;
    }
    if (!mounted || meals.isEmpty) return;

    // Les recettes absentes des corpus chargés sont relues par identifiant : un
    // repas peut pointer sur un brouillon ou une recette de la famille.
    final byId = <String, Recipe>{
      for (final r in _allRecipes)
        if (r.id.isNotEmpty) r.id: r,
    };
    final missing = <String>{
      for (final m in meals)
        if (m.recipeId != null &&
            m.recipeId!.isNotEmpty &&
            !byId.containsKey(m.recipeId))
          m.recipeId!,
    }.toList(growable: false);
    if (missing.isNotEmpty) {
      try {
        for (final r in await repo.getRecipesByIds(missing)) {
          byId[r.id] = r;
        }
      } catch (e, stackTrace) {
        // Le repas est repris quand même, sous son titre et son identifiant :
        // le lien vers la recette n'est pas perdu.
        reportUnexpectedError(
          feature: 'batchPlanningScreen.prefillRegisteredMeals.resolve',
          error: e,
          stackTrace: stackTrace,
          context: {'missing': missing.length},
        );
      }
    }
    if (!mounted) return;

    // Le rapprochement se fait après la dernière attente : une date ajoutée ou
    // retirée entre-temps a déjà décalé les créneaux.
    setState(() {
      final bySlot = registeredMealsBySlot(slotDates: _slotDates, meals: meals);
      for (final e in bySlot.entries) {
        final meal = e.value;
        if (_slots[e.key] != null || _slotSavedMealIds.containsValue(meal.id)) {
          continue;
        }
        _seedRegisteredMeal(
          e.key,
          meal,
          byId[meal.recipeId] ?? _recipeStandingFor(meal),
          uid: repo.uid,
        );
      }
    });
  }

  /// Pose sur le créneau [i] le repas déjà enregistré, avec tout ce que l'écran
  /// sait en montrer : heure, parts, jour de préparation, écarts, entrée,
  /// accompagnement et dessert.
  void _seedRegisteredMeal(
    int i,
    PlannedMeal meal,
    Recipe recipe, {
    required String uid,
  }) {
    MealComponent? first(MealComponentRole role) {
      for (final c in meal.components) {
        if (c.role == role) return c;
      }
      return null;
    }

    final starter = first(MealComponentRole.entree);
    final dessert = first(MealComponentRole.dessert);

    _slots[i] = recipe;
    _slotSavedMealIds[i] = meal.id;
    _slotTimes[i] = TimeOfDay(
      hour: meal.plannedAt.hour,
      minute: meal.plannedAt.minute,
    );
    final why = (meal.justification ?? '').trim();
    if (why.isNotEmpty) _slotJustifications[i] = why;
    if (meal.choiceSource != null) _slotSources[i] = meal.choiceSource!;
    if (meal.prepDate != null) _slotPrepDates[i] = meal.prepDate;
    if (meal.dismissedRecipeIds.isNotEmpty) {
      _slotDismissed[i] = meal.dismissedRecipeIds.toSet();
    }
    _slotSides[i] = first(MealComponentRole.accompagnement);
    _slotStarters[i] = starter;
    _slotDesserts[i] = dessert;
    // Sa composition est décidée : le programme ne la recalcule pas.
    _slotSideManual.add(i);

    // Les parts et le format du créneau suivent le repas : sans eux, la
    // validation réécrirait les parts de la recette et écarterait l'entrée ou
    // le dessert que le format du jour ne demande pas.
    var constraint = _slotConstraints[i] ?? const DayConstraint();
    final format = constraint.effectiveFormat;
    if ((starter != null && !format.wantsStarter) ||
        (dessert != null && !format.wantsDessert)) {
      final withStarter = starter != null || format.wantsStarter;
      final withDessert = dessert != null || format.wantsDessert;
      constraint = constraint.copyWith(
        mealFormat: withStarter && withDessert
            ? MealFormat.entreePlatDessert
            : withStarter
            ? MealFormat.entreePlat
            : MealFormat.platDessert,
      );
    }
    final target = meal.targetPortions ?? 0;
    if (target > 0 && target != constraint.targetPortions) {
      constraint = constraint.copyWith(targetPortions: target);
    }
    _slotConstraints[i] = constraint;

    _registeredMeals[meal.id] = meal;
    final built = _plannedMealForSlot(i, uid: uid);
    if (built != null) {
      _registeredBaseline[meal.id] = plannedMealContentKey(built);
    }
  }

  /// La recette qui tient lieu d'un repas dont la recette n'est pas chargée :
  /// un repas libre, ou une recette supprimée ou devenue privée. Le titre et
  /// l'identifiant du repas y sont conservés, pour que rien ne se perde si le
  /// repas est réécrit.
  Recipe _recipeStandingFor(PlannedMeal meal) {
    final now = DateTime.now();
    return Recipe(
      id: meal.recipeId ?? '',
      titre: meal.recipeTitre,
      langue: 'fr',
      rawCooklang: '',
      imageUrls: const [],
      reviewStatus: ReviewStatus.validated,
      tags: RecipeTags(prepTime: meal.prepMinutes, cookTime: meal.cookMinutes),
      ingredientsIndex: const [],
      portions: meal.basePortions,
      createdBy: '',
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Ce que « Valider » enregistrera, et les repas déjà au planning qu'il
  /// laisse tels quels parce que l'écran ne les a pas modifiés.
  ({List<PlannedMeal> toWrite, Set<String> keptIds}) _validationPlan(
    String uid,
  ) {
    final toWrite = <PlannedMeal>[];
    final keptIds = <String>{};
    for (int i = 0; i < _slotDates.length; i++) {
      final meal = _plannedMealForSlot(i, uid: uid);
      if (meal == null) continue;
      if (_isUnchangedRegistered(meal)) {
        keptIds.add(meal.id);
      } else {
        toWrite.add(meal);
      }
    }
    return (toWrite: toWrite, keptIds: keptIds);
  }

  /// Vrai pour un repas déjà au planning, repris sur l'écran et resté tel quel.
  bool _isUnchangedRegistered(PlannedMeal meal) =>
      meal.id.isNotEmpty &&
      _registeredBaseline[meal.id] == plannedMealContentKey(meal);

  Map<int, DayConstraint> _dailyConstraintsForAI() {
    final out = <int, DayConstraint>{};
    for (int i = 0; i < _slotDates.length; i++) {
      final c = _slotConstraints[i];
      if (c != null && !c.isEmpty) {
        out[_slotDates[i].weekday] = c;
      }
    }
    return out;
  }

  /// Contraintes indexées par slot : un cycle de plus de sept jours a deux
  /// créneaux le même jour de semaine, qui s'écrasent dans une map par weekday.
  List<DayConstraint?> _slotConstraintsForAI() => [
    for (int i = 0; i < _slotDates.length; i++)
      if (_slotConstraints[i]?.isEmpty ?? true) null else _slotConstraints[i],
  ];

  /// Conseil de conservation applicable au créneau [index], s'il existe.
  StorageAdvice? _storageAdviceFor(int index) {
    final id = _slots[index]?.id;
    if (id == null || id.isEmpty) return null;
    return _storageAdviceByRecipe[id];
  }

  /// Pool complet de recettes selon les sources chargées.
  List<Recipe> get _allRecipes {
    final seen = <String>{};
    return [
      for (final r in [
        ..._availableRecipes,
        ..._draftRecipes,
        ..._familyRecipes,
      ])
        if (r.id.isEmpty || seen.add(r.id)) r,
    ];
  }

  /// Livres qui portent au moins une recette dans les trois réservoirs déjà
  /// chargés, triés par titre.
  ///
  /// Le choix se fait parmi ce qui peut réellement être trouvé, pas parmi
  /// tout ce qui existe : un livre sans recette validée ni brouillon
  /// n'apporterait qu'une case à cocher qui ne changerait jamais rien.
  List<({String id, String titre})> _booksInPool() {
    final Map<String, String> titles = {
      for (final book in ref.read(accessibleBooksProvider).value ?? const [])
        book.id: book.titre,
    };
    final ids = <String>{
      for (final r in _allRecipes)
        if (r.bookId != null && r.bookId!.isNotEmpty) r.bookId!,
    };
    final books = [for (final id in ids) (id: id, titre: titles[id] ?? id)]
      ..sort((a, b) => a.titre.toLowerCase().compareTo(b.titre.toLowerCase()));
    return books;
  }

  /// Enregistre le périmètre choisi, pour qu'il retrouve l'utilisateur à sa
  /// prochaine ouverture de l'écran — pas seulement pendant cette session.
  /// Best-effort : un échec n'empêche pas de générer, il prive seulement de
  /// mémoire pour la prochaine fois.
  Future<void> _persistSearchScope(RecipeSearchScope scope) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    try {
      await repo.saveRecipeSearchScope(scope);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.saveRecipeSearchScope',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Le périmètre retenu en dernier, sans reposer la question : celui des
  /// gestes qui ne demandent pas de choisir (« Autre suggestion »,
  /// « Réessayer avec l'IA »).
  RecipeSearchScope get _currentScope => RecipeSearchScope(
    sources: _selectedSources,
    bookIds: _selectedBookIds ?? _booksInPool().map((b) => b.id).toSet(),
  );

  /// Les recettes du périmètre [scope].
  List<Recipe> _poolFor(RecipeSearchScope scope) => [
    if (scope.sources.contains(RecipeSource.myRecipes))
      ..._availableRecipes.where(scope.matchesBook),
    if (scope.sources.contains(RecipeSource.myDrafts))
      ..._draftRecipes.where(scope.matchesBook),
    if (scope.sources.contains(RecipeSource.familyRecipes))
      ..._familyRecipes.where(scope.matchesBook),
  ];

  /// Demande où chercher des recettes, puis génère.
  ///
  /// La question est la même que pour un créneau isolé, et elle est posée par
  /// le même widget : planifier une semaine ou un jour, c'est le même choix —
  /// mes recettes, mes brouillons, celles de la famille, et faut-il inventer
  /// quand rien ne convient.
  ///
  /// [replaceExisting] efface d'abord les créneaux remplis ; sinon les choix
  /// déjà faits (manuels ou IA) sont conservés.
  Future<void> _generateWithAI({bool replaceExisting = false}) async {
    final books = _booksInPool();
    // La question AVANT tout effacement : annuler la feuille ne doit pas vider
    // l'écran de ce qui y était déjà.
    final scope = await showModalBottomSheet<RecipeSearchScope>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => RecipeSourceSheet(
        initialSources: _selectedSources,
        initialBookIds: _selectedBookIds ?? books.map((b) => b.id).toSet(),
        availableBooks: books,
        allowAiCreation: ref.read(canEditProvider),
      ),
    );
    if (scope == null || scope.sources.isEmpty || !mounted) return;
    _selectedSources = scope.sources;
    _selectedBookIds = scope.bookIds;
    unawaited(_persistSearchScope(scope));
    await _runGeneration(scope, replaceExisting: replaceExisting);
  }

  /// « Réessayer avec l'IA » : les créneaux que Kass'Dalle a remplis faute de
  /// réponse du modèle sont vidés, puis la génération repart sur eux.
  Future<void> _retryWithAI() async {
    setState(() {
      for (final e in _slotSources.entries.toList()) {
        if (e.value != MealChoiceSource.rules) continue;
        if (_slotSavedMealIds.containsKey(e.key)) continue;
        _clearSlot(e.key);
      }
    });
    await _runGeneration(_currentScope);
  }

  /// Vide un créneau sans écarter sa recette.
  void _clearSlot(int i) {
    _slots[i] = null;
    _slotSides.remove(i);
    _slotSideManual.remove(i);
    _slotStarters.remove(i);
    _slotDesserts.remove(i);
    _slotJustifications.remove(i);
    _slotPrepDates.remove(i);
    _slotWasResized.remove(i);
    _slotResizeReasons.remove(i);
    _slotIsGenerated.remove(i);
    _slotSources.remove(i);
  }

  /// Génère les créneaux vides du cycle sur le périmètre [scope].
  ///
  /// Le serveur présélectionne les candidats de chaque créneau ; le modèle
  /// tranche entre eux. Quand le modèle ne répond pas ou qu'un plafond est
  /// atteint, le serveur remplit par ses règles et l'écran le dit.
  /// Les conceptions automatiques sont bornées par la génération : deux par
  /// défaut, réglées côté serveur.
  Future<void> _runGeneration(
    RecipeSearchScope scope, {
    bool replaceExisting = false,
  }) async {
    final pool = _poolFor(scope);
    // Un lecteur ne conçoit pas : la conception enregistre une recette, et
    // une préférence enregistrée avant ce changement peut encore la porter.
    final mayConceive =
        scope.sources.contains(RecipeSource.aiCreation) &&
        ref.read(canEditProvider);

    if (pool.isEmpty && !mayConceive) {
      _showError('Aucune recette disponible dans les sources sélectionnées.');
      return;
    }

    if (replaceExisting) {
      setState(() {
        // Tout régénérer, c'est écarter tout ce qui était en place : ces
        // écarts suivent chaque repas à la validation.
        for (final i in _slots.keys.toList()) {
          _dismissSlotRecipe(i);
        }
        _slots = {for (int i = 0; i < _slotDates.length; i++) i: null};
        _slotJustifications.clear();
        _slotPrepDates.clear();
        _slotWasResized.clear();
        _slotResizeReasons.clear();
        _slotIsGenerated.clear();
        _slotSides.clear();
        _slotSideManual.clear();
        _slotStarters.clear();
        _slotDesserts.clear();
        _slotSources.clear();
        _slotRankings.clear();
      });
    } else if (!_slots.values.any((r) => r == null)) {
      _showError(
        'Tous les créneaux sont déjà remplis — utilisez « Tout régénérer ».',
      );
      return;
    }
    // Les créneaux déjà remplis, dont ceux repris du planning : le constat
    // « rien proposé » se fait sur ce que la génération ajoute.
    final filledBefore = _slots.values.where((r) => r != null).length;
    setState(() {
      _generating = true;
      _notice = null;
      _noticeRetry = false;
    });
    try {
      final prefs = _prefs ?? const PlanningPreferences();
      // Passer les repas déjà assignés pour éviter les répétitions
      final alreadyAssigned = [
        for (final e in _slots.entries)
          if (e.value != null && e.value!.id.isNotEmpty)
            (slot: e.key, recipeId: e.value!.id),
      ];
      final recentlyServed = pool.isEmpty
          ? const <RecentlyServedMeal>[]
          : await _loadRecentlyServed();
      final suggestion = await ref
          .read(planningAiServiceProvider)
          .suggestMealPlan(
            recipes: pool,
            slotDates: _slotDates,
            dailyConstraints: _dailyConstraintsForAI(),
            slotConstraints: _slotConstraintsForAI(),
            globalConstraints: _globalConstraintsCtrl.text.trim(),
            batchCookingDay: prefs.batchCookingDay,
            alreadyAssigned: alreadyAssigned,
            recentlyServed: recentlyServed,
            slotDismissed: [
              for (int i = 0; i < _slotDates.length; i++) _slotDismissed[i],
            ],
            groupId: widget.groupId,
          );
      if (!mounted) return;
      setState(() {
        _constraintsLocked = true;
        _runId = suggestion.runId;
        _conceptsRemaining = suggestion.conceptsRemaining;
        _slotRankings = {..._slotRankings, ...suggestion.rankings};
        if (suggestion.modelUnavailable) {
          _notice = suggestion.notice;
          _noticeRetry = suggestion.modelStatus == 'failed';
        }
        final suggestions = suggestion.slots;
        for (int i = 0; i < suggestions.length; i++) {
          final s = suggestions[i];
          // Un créneau déjà rempli n'est pas écrasé : il a été envoyé comme
          // « déjà assigné », le remplacer effacerait un choix manuel.
          if (_slots[i] != null || s.recipe == null) continue;
          _slots[i] = s.recipe;
          _setSlotFacts(i, s);
          // L'entrée et le dessert du même appel, quand le format du
          // créneau en demandait : le serveur ne les rend que dans ce cas.
          _slotStarters[i] = s.starter == null
              ? null
              : MealComponent.recipe(
                  s.starter!,
                  role: MealComponentRole.entree,
                  justification: s.source.label,
                );
          _slotDesserts[i] = s.dessert == null
              ? null
              : MealComponent.recipe(
                  s.dessert!,
                  role: MealComponentRole.dessert,
                  justification: s.source.label,
                );
        }
        // Les plats sont posés : le programme choisit leurs accompagnements,
        // dans l'ordre des jours, sans en servir deux fois le même de suite.
        _recomputeSides();
      });

      // « Conception IA (si aucun résultat) » : un créneau resté vide reçoit
      // une recette inventée, dans la limite de la génération. Au-delà, le
      // créneau reste vide et l'écran dit comment le remplir.
      final stillEmpty = mayConceive
          ? [
              for (int i = 0; i < _slotDates.length; i++)
                if (_slots[i] == null) i,
            ]
          : const <int>[];
      var conceived = 0;
      var leftEmpty = 0;
      for (var k = 0; k < stillEmpty.length; k++) {
        if (!mounted) return;
        final runId = _runId;
        if (runId == null || _conceptsRemaining <= 0) {
          leftEmpty = stillEmpty.length - k;
          break;
        }
        final outcome = await _conceiveForSlot(
          stillEmpty[k],
          runId: runId,
          announce: false,
        );
        if (outcome == _ConceptOutcome.denied) {
          leftEmpty = stillEmpty.length - k;
          break;
        }
        if (outcome == _ConceptOutcome.done) {
          conceived++;
          _conceptsRemaining--;
        }
      }

      if (!mounted) return;
      final filled = _slots.values.where((r) => r != null).length;
      if (leftEmpty > 0) {
        final filledText =
            '$filled créneau${filled > 1 ? 'x' : ''} '
            'rempli${filled > 1 ? 's' : ''}. ';
        // « 0 recette conçue, c'est le maximum » serait faux : la génération
        // n'en permettait aucune, ou n'a pas pu en rattacher.
        final conceivedText = conceived > 0
            ? '$conceived recette${conceived > 1 ? 's' : ''} conçue'
                  '${conceived > 1 ? 's' : ''}, c\'est le maximum par '
                  'génération. '
            : 'Aucune recette n\'a pu être conçue pour cette génération. ';
        final capMessage =
            '$filledText$conceivedText'
            'Pour ${leftEmpty > 1 ? 'les $leftEmpty créneaux restants' : 'le créneau restant'}, '
            'appuyez sur « Proposer une recette » (icône ↻) sur '
            '${leftEmpty > 1 ? 'chacun' : 'lui'}.';
        setState(
          () => _notice = _notice == null ? capMessage : '$_notice $capMessage',
        );
      }
      if (filled - filledBefore <= 0) {
        // Aucune suggestion : le dire, plutôt qu'annoncer un succès devant
        // un écran resté vide.
        if (_notice == null) {
          _showError('Aucune recette ne convient aux créneaux vides.');
        }
      } else if (!suggestion.modelUnavailable) {
        // Les plats récents retirés du corpus sont dits : un plat qu'on ne
        // voit pas proposé doit pouvoir s'expliquer.
        final excluded = suggestion.excludedRecentCount;
        final suffix = excluded > 0
            ? ' · $excluded plat${excluded > 1 ? 's' : ''} récent'
                  '${excluded > 1 ? 's' : ''} écarté${excluded > 1 ? 's' : ''}'
            : '';
        context.showSuccessSnackBar(
          'Planning prêt : $filled créneau${filled > 1 ? 'x' : ''} '
          'rempli${filled > 1 ? 's' : ''}$suffix',
        );
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.generateWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('La génération n\'a pas abouti. Réessayez.');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// Origine, faits, parts et jour de préparation d'une suggestion posée sur
  /// le créneau [i].
  void _setSlotFacts(int i, SlotSuggestion s) {
    final why = (s.justification ?? '').trim();
    if (why.isNotEmpty) {
      _slotJustifications[i] = why;
    } else {
      _slotJustifications.remove(i);
    }
    _slotSources[i] = s.source;
    _slotIsGenerated[i] = s.isGenerated;
    _slotWasResized[i] = s.wasResized;
    final resizeReason = (s.resizeReason ?? '').trim();
    if (resizeReason.isNotEmpty) {
      _slotResizeReasons[i] = resizeReason;
    } else {
      _slotResizeReasons.remove(i);
    }
    _slotPrepDates[i] = s.prepDate;
  }

  Future<void> _pickRecipeForSlot(int slotIndex) async {
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => RecipePickerSheet(
        recipes: _allRecipes,
        dismissedRecipeIds: _slotDismissed[slotIndex] ?? const {},
        dismissedFrom: 'créneau',
      ),
    );
    if (recipe != null && mounted) {
      setState(() {
        // Choisir une autre recette, c'est écarter celle en place.
        if (_slots[slotIndex]?.id != recipe.id) _dismissSlotRecipe(slotIndex);
        _slots[slotIndex] = recipe;
        // L'origine dit le choix à la main : pas de phrase à sa place.
        _slotJustifications.remove(slotIndex);
        _slotSources[slotIndex] = MealChoiceSource.manual;
        _slotWasResized[slotIndex] = false;
        _slotResizeReasons.remove(slotIndex);
        _slotPrepDates.remove(slotIndex);
        _slotIsGenerated.remove(slotIndex);
        // Un autre plat, un autre accompagnement : le choix à la main tombe
        // avec le plat qu'il accompagnait.
        _slotSideManual.remove(slotIndex);
        _recomputeSides(only: {slotIndex});
      });
    }
  }

  /// Texte de la confirmation de « Valider » : ce qui sera ajouté, ce qui sera
  /// mis à jour parce que déjà enregistré depuis un créneau, ce qui est déjà
  /// au planning et reste tel quel, et ce que le planning contient déjà
  /// d'autre sur la période.
  ///
  /// [groupName] : le planning validé est celui de ce groupe.
  static String _validateDialogText({
    required int newCount,
    required int updatedCount,
    required int keptCount,
    required int existingCount,
    String? groupName,
  }) {
    final target = groupName == null
        ? 'votre planning'
        : 'au planning de $groupName';
    final into = groupName == null ? 'à $target' : target;
    final ready = switch ((newCount, updatedCount)) {
      (_, 0) => '$newCount repas seront ajoutés $into',
      (0, _) => 'Les $updatedCount repas déjà enregistrés seront mis à jour',
      _ =>
        '$newCount repas seront ajoutés $into, et $updatedCount '
            'déjà enregistrés seront mis à jour',
    };
    final kept = switch (keptCount) {
      0 => '',
      1 => ' Le repas déjà au planning reste tel quel.',
      _ => ' Les $keptCount repas déjà au planning restent tels quels.',
    };
    if (existingCount == 0) return '$ready.$kept';
    final others = updatedCount > 0 || keptCount > 0 ? 'autres repas' : 'repas';
    final holder = groupName == null
        ? 'Votre planning'
        : 'Le planning de $groupName';
    return '$ready.$kept $holder contient déjà $existingCount $others '
        'sur cette période : voulez-vous les remplacer, ou ajouter les '
        'nouveaux à côté ?';
  }

  /// Le repas que le créneau [i] enregistrera, ou null s'il est vide.
  ///
  /// Un seul constructeur pour l'icône calendrier du créneau et pour
  /// « Valider » : ce que l'un enregistre est ce que l'autre aurait écrit.
  /// L'identifiant est celui du repas déjà enregistré pour ce créneau, s'il y
  /// en a un, pour qu'il soit réécrit et non doublé.
  PlannedMeal? _plannedMealForSlot(int i, {required String uid}) {
    final recipe = _slots[i];
    if (recipe == null) return null;
    final date = _slotDates[i];
    final slotConstraint = _slotConstraints[i] ?? const DayConstraint();
    final targetPortions = slotConstraint.targetPortions > 0
        ? slotConstraint.targetPortions
        : recipe.portions;
    final time = _slotTimes[i] ?? _defaultTime;
    final plannedAt = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final duration = (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
    return PlannedMeal(
      id: _slotSavedMealIds[i] ?? '',
      uid: uid,
      groupId: widget.groupId,
      recipeId: recipe.id.isEmpty ? null : recipe.id,
      recipeTitre: recipe.titre,
      plannedAt: plannedAt,
      durationMinutes: duration > 0 ? duration : 30,
      prepMinutes: recipe.tags.prepTime,
      cookMinutes: recipe.tags.cookTime,
      basePortions: recipe.portions,
      targetPortions: targetPortions,
      prepDate: _slotPrepDates[i],
      dismissedRecipeIds: (_slotDismissed[i] ?? const {}).toList(
        growable: false,
      ),
      // Le « pourquoi » suit le repas. Il était affiché pendant la
      // planification puis jeté à la validation : l'écran qu'on relit
      // ensuite, celui du planning, n'en gardait rien.
      justification: _slotJustifications[i],
      choiceSource: _slotSources[i],
      // Ce qui accompagne le plat suit le repas, dans l'ordre du repas :
      // l'entrée et le dessert seulement si le format du créneau en
      // demande, l'accompagnement — garniture figée ou recette — toujours.
      components: [
        if (slotConstraint.effectiveFormat.wantsStarter) ?_slotStarters[i],
        ?_slotSides[i],
        if (slotConstraint.effectiveFormat.wantsDessert) ?_slotDesserts[i],
      ],
      // Un repas déjà au planning garde sa date de création.
      createdAt:
          _registeredMeals[_slotSavedMealIds[i]]?.createdAt ?? DateTime.now(),
    );
  }

  Future<void> _validate() async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;

    // Les repas déjà au planning et restés tels quels ne sont pas réécrits :
    // ils sont conservés, ni remplacés ni doublés.
    final plan = _validationPlan(repo.uid);
    final mealsToAdd = plan.toWrite;

    if (mealsToAdd.isEmpty) {
      _showError(
        plan.keptIds.isEmpty
            ? 'Aucun repas assigné à valider.'
            : 'Aucun nouveau repas à valider : les repas déjà au planning '
                  'sont conservés.',
      );
      return;
    }

    // Ce que le cycle recouvre déjà : enregistrer sans le savoir empilait deux
    // repas sur le même créneau, et le planning affichait les deux. Les repas
    // enregistrés depuis l'icône d'un créneau de cet écran n'en font pas
    // partie : ils sont réécrits sous leur identifiant, pas remplacés.
    final ownIds = {
      for (final meal in mealsToAdd)
        if (meal.id.isNotEmpty) meal.id,
    };
    List<PlannedMeal> existing;
    try {
      final between = await repo.getMealsBetween(
        from: _slotDates.first,
        to: _slotDates.last,
        groupId: widget.groupId,
      );
      existing = [
        for (final meal in between)
          if (!ownIds.contains(meal.id) && !plan.keptIds.contains(meal.id))
            meal,
      ];
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.validateExisting',
        error: e,
        stackTrace: stackTrace,
      );
      existing = const [];
    }
    if (!mounted) return;

    final choice = await showDialog<_ValidateChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Valider le planning ?'),
        content: Text(
          _validateDialogText(
            newCount: mealsToAdd.length - ownIds.length,
            updatedCount: ownIds.length,
            keptCount: plan.keptIds.length,
            existingCount: existing.length,
            groupName: _group?.name,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _ValidateChoice.cancel),
            child: const Text('Annuler'),
          ),
          if (existing.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, _ValidateChoice.append),
              child: const Text('Ajouter'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(
              ctx,
              existing.isEmpty
                  ? _ValidateChoice.append
                  : _ValidateChoice.replace,
            ),
            child: Text(existing.isEmpty ? 'Valider' : 'Remplacer'),
          ),
        ],
      ),
    );
    if (choice == null || choice == _ValidateChoice.cancel || !mounted) return;

    setState(() => _saving = true);
    try {
      if (choice == _ValidateChoice.replace && existing.isNotEmpty) {
        await repo.deleteMeals(existing.map((m) => m.id).toList());
      }
      await repo.saveMeals(mealsToAdd);
      unawaited(_recordRefusals(repo.uid));
      await _ensureStorageAdviceForPreparedMeals(mealsToAdd);
      // Les repas posés dans le calendrier depuis leur créneau n'y retournent
      // pas ; les autres y entrent maintenant. Le planning est enregistré
      // quoi qu'il arrive au calendrier.
      final toExport = [
        for (final meal in mealsToAdd)
          if (meal.id.isEmpty) meal,
      ];
      final calendar = await _exportMealsToCalendar(toExport);
      if (mounted) {
        final replaced = choice == _ValidateChoice.replace
            ? ' (${existing.length} remplacés)'
            : '';
        final planned = '${mealsToAdd.length} repas planifiés$replaced';
        if (calendar.tokenError != null) {
          context.showSnackBar(
            '$planned ; calendrier non autorisé : ${calendar.tokenError}',
          );
        } else if (calendar.exported < toExport.length) {
          context.showSnackBar(
            '$planned, ${calendar.exported} sur ${toExport.length} ajoutés '
            'au calendrier',
          );
        } else {
          context.showSuccessSnackBar(
            toExport.isEmpty
                ? '$planned ✓'
                : '$planned, ajoutés au calendrier ✓',
          );
        }
        // Le cycle est enregistré : le garde de sortie n'a plus rien à
        // protéger.
        _validated = true;
        context.pop();
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.validate',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur lors de la sauvegarde : $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Produit le conseil de conservation des plats cuisinés à l'avance.
  ///
  /// Un plat préparé le dimanche pour le lundi pose une question que sa recette
  /// ne pose pas : comment le garder, et comment le réchauffer. Elle ne se
  /// posait qu'à la demande, d'un bouton que rien n'invitait à presser — et le
  /// repas arrivait dans le planning sans un mot sur sa conservation.
  ///
  /// Un appel par recette concernée, et **seulement** pour celles-là. Le
  /// conseil appartient au plat : une recette déjà conseillée n'en repaye pas
  /// un second.
  ///
  /// Best-effort : le planning est enregistré, c'est l'essentiel. Un conseil
  /// manquant se rattrape d'un bouton, un planning perdu ne se rattrape pas.
  Future<void> _ensureStorageAdviceForPreparedMeals(
    List<PlannedMeal> meals,
  ) async {
    final recipeIds = <String>{
      for (final meal in meals)
        if (meal.prepDate != null &&
            meal.recipeId != null &&
            meal.recipeId!.isNotEmpty)
          meal.recipeId!,
    };
    if (recipeIds.isEmpty) return;

    for (final id in recipeIds) {
      try {
        // Un plat dont l'utilisateur n'est ni le créateur ni l'administrateur
        // n'est pas conseillé ici : le serveur le refuserait. Son créateur le
        // fera, ou le conseil existe déjà et reste lu.
        final canGenerate = await ref.read(canWriteRecipeAdviceProvider.future);
        await ref
            .read(storageRepositoryProvider)
            .ensure(recipeId: id, canGenerate: canGenerate);
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'batchPlanningScreen.ensureStorageAdvice',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
  }

  void _addDay() {
    if (_slotDates.isEmpty) return;
    // Le serveur refuse plus de 31 créneaux dans une génération.
    if (_slotDates.length >= kMaxCycleSlots) {
      _showError('Un cycle compte $kMaxCycleSlots jours au plus.');
      return;
    }
    setState(() {
      // Rechercher le premier trou dans la séquence de dates
      int? gapIdx;
      DateTime? gapDate;
      for (int i = 1; i < _slotDates.length; i++) {
        final prev = _slotDates[i - 1];
        final expected = DateTime(prev.year, prev.month, prev.day + 1);
        if (_slotDates[i] != expected) {
          gapDate = expected;
          gapIdx = i;
          break;
        }
      }

      if (gapDate != null && gapIdx != null) {
        // Combler le trou : insérer la date manquante à la bonne position
        final newDates = [..._slotDates]..insert(gapIdx, gapDate);
        final newSlots = <int, Recipe?>{};
        final newTimes = <int, TimeOfDay>{};
        final newJustifications = <int, String>{};
        final newPrepDates = <int, DateTime?>{};
        final newWasResized = <int, bool>{};
        final newResizeReasons = <int, String>{};
        final newIsGenerated = <int, bool>{};
        final newConstraints = <int, DayConstraint>{};
        final newDismissed = <int, Set<String>>{};
        for (int i = 0; i < newDates.length; i++) {
          if (i < gapIdx) {
            newSlots[i] = _slots[i];
            newTimes[i] = _slotTimes[i] ?? _defaultTime;
            if (_slotJustifications.containsKey(i)) {
              newJustifications[i] = _slotJustifications[i]!;
            }
            if (_slotPrepDates.containsKey(i)) {
              newPrepDates[i] = _slotPrepDates[i];
            }
            if (_slotWasResized.containsKey(i)) {
              newWasResized[i] = _slotWasResized[i]!;
            }
            if (_slotResizeReasons.containsKey(i)) {
              newResizeReasons[i] = _slotResizeReasons[i]!;
            }
            if (_slotIsGenerated.containsKey(i)) {
              newIsGenerated[i] = _slotIsGenerated[i]!;
            }
            if (_slotConstraints.containsKey(i)) {
              newConstraints[i] = _slotConstraints[i]!;
            }
            if (_slotDismissed.containsKey(i)) {
              newDismissed[i] = _slotDismissed[i]!;
            }
          } else if (i == gapIdx) {
            newSlots[i] = null;
            // Le jour comblé prend l'heure de SON jour de semaine.
            newTimes[i] = _timeFor(gapDate);
            newConstraints[i] =
                _prefs?.dailyConstraints[gapDate.weekday] ??
                const DayConstraint();
          } else {
            newSlots[i] = _slots[i - 1];
            newTimes[i] = _slotTimes[i - 1] ?? _defaultTime;
            if (_slotJustifications.containsKey(i - 1)) {
              newJustifications[i] = _slotJustifications[i - 1]!;
            }
            if (_slotPrepDates.containsKey(i - 1)) {
              newPrepDates[i] = _slotPrepDates[i - 1];
            }
            if (_slotWasResized.containsKey(i - 1)) {
              newWasResized[i] = _slotWasResized[i - 1]!;
            }
            if (_slotResizeReasons.containsKey(i - 1)) {
              newResizeReasons[i] = _slotResizeReasons[i - 1]!;
            }
            if (_slotIsGenerated.containsKey(i - 1)) {
              newIsGenerated[i] = _slotIsGenerated[i - 1]!;
            }
            if (_slotConstraints.containsKey(i - 1)) {
              newConstraints[i] = _slotConstraints[i - 1]!;
            }
            if (_slotDismissed.containsKey(i - 1)) {
              newDismissed[i] = _slotDismissed[i - 1]!;
            }
          }
        }
        _slotDates = newDates;
        _slots = newSlots;
        _slotTimes = newTimes;
        _slotJustifications = newJustifications;
        _slotPrepDates = newPrepDates;
        _slotWasResized = newWasResized;
        _slotResizeReasons = newResizeReasons;
        _slotIsGenerated = newIsGenerated;
        _slotConstraints = newConstraints;
        _slotDismissed = newDismissed;
        _slotSavedMealIds = _shiftAfterInsert(_slotSavedMealIds, gapIdx);
        _slotSources = _shiftAfterInsert(_slotSources, gapIdx);
        _slotRankings = _shiftAfterInsert(_slotRankings, gapIdx);
        _slotSides = _shiftAfterInsert(_slotSides, gapIdx);
        _slotStarters = _shiftAfterInsert(_slotStarters, gapIdx);
        _slotDesserts = _shiftAfterInsert(_slotDesserts, gapIdx);
        final manual = _shiftAfterInsert({
          for (final i in _slotSideManual) i: true,
        }, gapIdx).keys.toSet();
        _slotSideManual
          ..clear()
          ..addAll(manual);
      } else {
        // Pas de trou : étendre d'un jour après le dernier
        final last = _slotDates.last;
        final newDate = DateTime(last.year, last.month, last.day + 1);
        _slotDates = [..._slotDates, newDate];
        _slots[_slotDates.length - 1] = null;
        _slotTimes[_slotDates.length - 1] = _timeFor(newDate);
        _slotConstraints[_slotDates.length - 1] =
            _prefs?.dailyConstraints[newDate.weekday] ?? const DayConstraint();
      }
    });
  }

  /// Confirmation avant de perdre la recette posée sur [index]. Un créneau
  /// vide part sans question : il n'y a rien à perdre. Le menu ⋮ et le clic
  /// droit rendent ces actions faciles à toucher par mégarde.
  Future<bool> _confirmLoss(
    int index, {
    required String title,
    required String action,
  }) async {
    final recipe = _slots[index];
    if (recipe == null) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text('« ${recipe.titre} » sera retiré de ce cycle.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true && mounted;
  }

  /// Supprime le jour à [index] de la liste des slots.
  void _removeDay(int index) {
    if (_slotDates.length <= 1) {
      _showError('Impossible de supprimer le dernier jour.');
      return;
    }
    setState(() {
      final newDates = [..._slotDates]..removeAt(index);
      final newSlots = <int, Recipe?>{};
      final newTimes = <int, TimeOfDay>{};
      final newJustifications = <int, String>{};
      final newPrepDates = <int, DateTime?>{};
      final newWasResized = <int, bool>{};
      final newResizeReasons = <int, String>{};
      final newIsGenerated = <int, bool>{};
      final newConstraints = <int, DayConstraint>{};
      final newDismissed = <int, Set<String>>{};
      for (int i = 0; i < newDates.length; i++) {
        newSlots[i] = i < index ? _slots[i] : _slots[i + 1];
        newTimes[i] = i < index
            ? (_slotTimes[i] ?? _defaultTime)
            : (_slotTimes[i + 1] ?? _defaultTime);
        final sourceIndex = i < index ? i : i + 1;
        if (_slotJustifications.containsKey(sourceIndex)) {
          newJustifications[i] = _slotJustifications[sourceIndex]!;
        }
        if (_slotPrepDates.containsKey(sourceIndex)) {
          newPrepDates[i] = _slotPrepDates[sourceIndex];
        }
        if (_slotWasResized.containsKey(sourceIndex)) {
          newWasResized[i] = _slotWasResized[sourceIndex]!;
        }
        if (_slotResizeReasons.containsKey(sourceIndex)) {
          newResizeReasons[i] = _slotResizeReasons[sourceIndex]!;
        }
        if (_slotIsGenerated.containsKey(sourceIndex)) {
          newIsGenerated[i] = _slotIsGenerated[sourceIndex]!;
        }
        if (_slotConstraints.containsKey(sourceIndex)) {
          newConstraints[i] = _slotConstraints[sourceIndex]!;
        }
        if (_slotDismissed.containsKey(sourceIndex)) {
          newDismissed[i] = _slotDismissed[sourceIndex]!;
        }
      }
      _slotDates = newDates;
      _slots = newSlots;
      _slotTimes = newTimes;
      _slotJustifications = newJustifications;
      _slotPrepDates = newPrepDates;
      _slotWasResized = newWasResized;
      _slotResizeReasons = newResizeReasons;
      _slotIsGenerated = newIsGenerated;
      _slotConstraints = newConstraints;
      _slotDismissed = newDismissed;
      _slotSavedMealIds = _shiftAfterRemove(_slotSavedMealIds, index);
      _slotSources = _shiftAfterRemove(_slotSources, index);
      _slotRankings = _shiftAfterRemove(_slotRankings, index);
      _slotSides = _shiftAfterRemove(_slotSides, index);
      _slotStarters = _shiftAfterRemove(_slotStarters, index);
      _slotDesserts = _shiftAfterRemove(_slotDesserts, index);
      final manual = _shiftAfterRemove({
        for (final i in _slotSideManual) i: true,
      }, index).keys.toSet();
      _slotSideManual
        ..clear()
        ..addAll(manual);
    });
  }

  /// Écarte la recette en place sur [slotIndex], s'il y en a une enregistrée.
  ///
  /// Appelé par « Autre suggestion », « Changer la recette » et « Tout
  /// régénérer ». Une recette proposée (et non choisie à la main) compte
  /// aussi comme un refus. « Réessayer avec l'IA » et le retrait d'une
  /// recette passent par [_clearSlot] : ce ne sont pas des refus.
  void _dismissSlotRecipe(int slotIndex) {
    final current = _slots[slotIndex];
    if (current == null || current.id.isEmpty) return;
    (_slotDismissed[slotIndex] ??= {}).add(current.id);
    if (countsAsRefusal(_slotSources[slotIndex])) _refusedIds.add(current.id);
  }

  /// Enregistre les refus de la session, une fois le cycle validé. Une
  /// recette écartée puis reprise sur un créneau du cycle n'est pas refusée.
  Future<void> _recordRefusals(String uid) async {
    final kept = {
      for (final r in _slots.values)
        if (r != null && r.id.isNotEmpty) r.id,
    };
    final refused = _refusedIds.difference(kept);
    if (refused.isEmpty) return;
    // Jamais bloquant : le repository remonte lui-même un échec au rapport.
    await ref.read(planningRefusalsRepositoryProvider).record(uid, refused);
  }

  /// « Autre suggestion » sur un créneau rempli, « Proposer une recette » sur
  /// un créneau vide — sans appel de modèle.
  ///
  /// La recette suivante de la liste classée par le serveur, si l'écran en a
  /// une ; sinon le serveur classe ce créneau seul, en mode `code`. La recette
  /// remplacée est écartée du créneau. Liste épuisée : l'écran le dit et
  /// propose de choisir une recette ou de la concevoir avec l'IA.
  Future<void> _otherSuggestion(int slotIndex) async {
    final pool = _poolFor(_currentScope);
    final byId = {
      for (final r in pool)
        if (r.id.isNotEmpty) r.id: r,
    };
    final current = _slots[slotIndex]?.id ?? '';
    final excluded = <String>{
      ...?_slotDismissed[slotIndex],
      if (current.isNotEmpty) current,
    };
    final usedElsewhere = <String>{
      for (final e in _slots.entries)
        if (e.key != slotIndex && e.value != null && e.value!.id.isNotEmpty)
          e.value!.id,
    };

    final ranking = _slotRankings[slotIndex];
    final local = ranking == null
        ? null
        : nextRankedCandidate(
            ranking.plats,
            dismissed: excluded,
            usedElsewhere: usedElsewhere,
            availableIds: byId.keys.toSet(),
          );
    if (local != null) {
      _replaceWithSuggestion(
        slotIndex,
        SlotSuggestion(
          recipe: byId[local.recipeId],
          justification: local.why,
          wasResized: local.resizeReason != null,
          resizeReason: local.resizeReason,
          prepDate: ranking?.prepDate,
          source: MealChoiceSource.rules,
          repeat: local.repeat,
        ),
      );
      return;
    }

    // Pas de liste en main, ou liste épuisée : le serveur classe ce créneau
    // seul, sans appel de modèle.
    final candidates = candidatesForMeal(pool, dismissedRecipeIds: excluded);
    SlotSuggestion? suggestion;
    if (candidates.isNotEmpty) {
      setState(() => _generatingSlot = slotIndex);
      try {
        final prefs = _prefs ?? const PlanningPreferences();
        final slotConstraint =
            _slotConstraints[slotIndex] ?? const DayConstraint();
        final result = await ref
            .read(planningAiServiceProvider)
            .suggestMealPlan(
              recipes: candidates,
              slotDates: [_slotDates[slotIndex]],
              dailyConstraints: {_slotDates[slotIndex].weekday: slotConstraint},
              slotConstraints: [slotConstraint.isEmpty ? null : slotConstraint],
              globalConstraints: _globalConstraintsCtrl.text.trim(),
              batchCookingDay: prefs.batchCookingDay,
              // Les recettes posées sur les autres créneaux, hors de cette
              // demande (créneau −1) : le serveur les évite tant qu'il peut.
              alreadyAssigned: [
                for (final id in usedElsewhere) (slot: -1, recipeId: id),
              ],
              recentlyServed: await _loadRecentlyServed(),
              withoutModel: true,
              groupId: widget.groupId,
            );
        if (!mounted) return;
        final fresh = result.rankings[0];
        if (fresh != null) setState(() => _slotRankings[slotIndex] = fresh);
        if (result.slots.isNotEmpty && result.slots.first.recipe != null) {
          suggestion = result.slots.first;
        }
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'batchPlanningScreen.otherSuggestion',
          error: e,
          stackTrace: stackTrace,
        );
        _showError('La suggestion n\'a pas abouti. Réessayez.');
        return;
      } finally {
        if (mounted) setState(() => _generatingSlot = null);
      }
    }
    if (!mounted) return;
    if (suggestion == null) {
      await _offerWhenExhausted(slotIndex);
      return;
    }
    _replaceWithSuggestion(slotIndex, suggestion);
  }

  /// Pose [suggestion] sur le créneau, en écartant la recette en place.
  void _replaceWithSuggestion(int slotIndex, SlotSuggestion suggestion) {
    setState(() {
      _dismissSlotRecipe(slotIndex);
      _constraintsLocked = true;
      _slots[slotIndex] = suggestion.recipe;
      _setSlotFacts(slotIndex, suggestion);
      _slotSideManual.remove(slotIndex);
      _recomputeSides(only: {slotIndex});
    });
  }

  /// Liste épuisée : choisir une recette, ou la concevoir avec l'IA — un
  /// appel facturé, demandé par la personne, hors plafond de génération.
  Future<void> _offerWhenExhausted(int slotIndex) async {
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
        await _pickRecipeForSlot(slotIndex);
      case _ExhaustedChoice.conceive:
        await _conceiveForSlot(slotIndex);
    }
  }

  /// Fait inventer une recette pour un créneau.
  ///
  /// [runId] rattache la conception à sa génération : le serveur y applique le
  /// plafond de conceptions et de coût, et refuse au-delà ([_ConceptOutcome.denied]).
  /// Sans [runId], c'est un geste unitaire que la personne demande sur un
  /// créneau : il ne compte pas dans le plafond de la génération.
  /// [announce] : dire le résultat (geste unitaire) ; la génération du cycle
  /// fait son propre bilan.
  Future<_ConceptOutcome> _conceiveForSlot(
    int slotIndex, {
    String? runId,
    bool announce = true,
  }) async {
    final slotConstraint = _slotConstraints[slotIndex] ?? const DayConstraint();
    // Ce que le cycle contient déjà, y compris ce qui vient d'être conçu au
    // créneau précédent. Une contrainte de variété porte sur l'ENSEMBLE.
    final alreadyPlanned = [
      for (int i = 0; i < _slotDates.length; i++)
        if (i != slotIndex && _slots[i] != null) _slots[i]!.titre,
    ];
    setState(() => _conceivingSlots.add(slotIndex));
    try {
      final suggestion = await ref
          .read(planningAiServiceProvider)
          .generateRecipeConcept(
            slotDate: _slotDates[slotIndex],
            globalConstraints: _globalConstraintsCtrl.text.trim(),
            dayConstraint: slotConstraint.isEmpty ? null : slotConstraint,
            alreadyPlanned: alreadyPlanned,
            runId: runId,
          );
      if (!mounted) return _ConceptOutcome.failed;
      if (suggestion.recipe == null) {
        _conceptFailed(slotIndex);
        return _ConceptOutcome.failed;
      }
      await _applySuggestionToSlot(slotIndex, suggestion);
      if (announce && mounted) {
        context.showSuccessSnackBar(
          'Recette conçue et enregistrée dans vos brouillons',
        );
      }
      return _ConceptOutcome.done;
    } on GeminiCallableException catch (e, stackTrace) {
      // Refus du plafond de la génération : la boucle s'arrête et l'écran
      // dit combien de créneaux restent vides. Ce n'est pas une panne.
      final details = e.details;
      if (runId != null &&
          details is Map &&
          details['reason'] is String &&
          (e.code == 'resource-exhausted' || e.code == 'not-found')) {
        return _ConceptOutcome.denied;
      }
      reportUnexpectedError(
        feature: 'batchPlanningScreen.conceiveForSlot',
        error: e,
        stackTrace: stackTrace,
        context: {'code': e.code},
      );
      if (!mounted) return _ConceptOutcome.failed;
      if (e.code == 'resource-exhausted' && e.message.isNotEmpty) {
        // Plafond du jour : le message du serveur est écrit pour l'écran.
        _showError(e.message);
        return runId != null ? _ConceptOutcome.denied : _ConceptOutcome.failed;
      }
      _conceptFailed(slotIndex);
      return _ConceptOutcome.failed;
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.conceiveForSlot',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) _conceptFailed(slotIndex);
      return _ConceptOutcome.failed;
    } finally {
      if (mounted) setState(() => _conceivingSlots.remove(slotIndex));
    }
  }

  void _conceptFailed(int slotIndex) {
    if (!mounted) return;
    context.showErrorSnackBar(
      'La conception n\'a pas abouti.',
      action: SnackBarAction(
        label: 'Réessayer',
        onPressed: () => _conceiveForSlot(slotIndex),
      ),
    );
  }

  /// Pose une suggestion sur un créneau, en enregistrant d'abord la recette si
  /// l'IA vient de l'inventer.
  ///
  /// Une recette conçue à l'instant n'existe nulle part : sans ce brouillon,
  /// elle n'aurait pas d'identifiant, et le repas planifié pointerait vers
  /// rien.
  Future<void> _applySuggestionToSlot(
    int slotIndex,
    SlotSuggestion suggestion,
  ) async {
    Recipe? finalRecipe = suggestion.recipe;
    if (suggestion.isGenerated && finalRecipe != null) {
      final repo = ref.read(planningRepositoryProvider);
      if (repo != null) {
        try {
          final newId = await repo.saveAsDraft(finalRecipe);
          finalRecipe = Recipe(
            id: newId,
            titre: finalRecipe.titre,
            langue: finalRecipe.langue,
            rawCooklang: finalRecipe.rawCooklang,
            draftCooklang: finalRecipe.draftCooklang,
            imageUrls: finalRecipe.imageUrls,
            reviewStatus: finalRecipe.reviewStatus,
            tags: finalRecipe.tags,
            ingredientsIndex: finalRecipe.ingredientsIndex,
            // Les parts et les ingrédients suivent : sans eux, le repas
            // perdait la base de son redimensionnement et de ses courses.
            ingredients: finalRecipe.ingredients,
            portions: finalRecipe.portions,
            origin: finalRecipe.origin,
            createdBy: repo.uid,
            createdAt: finalRecipe.createdAt,
            updatedAt: finalRecipe.updatedAt,
          );
          // Ajouter à la liste des brouillons pour future sélection
          _draftRecipes = [finalRecipe, ..._draftRecipes];
        } catch (error, stackTrace) {
          reportUnexpectedError(
            feature: 'batchPlanningScreen.applySuggestionToSlot',
            error: error,
            stackTrace: stackTrace,
          );
          // Sauvegarde échouée : on utilise quand même la recette sans id
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _dismissSlotRecipe(slotIndex);
      _constraintsLocked = true;
      _slots[slotIndex] = finalRecipe;
      _setSlotFacts(slotIndex, suggestion);
      _slotSideManual.remove(slotIndex);
      _recomputeSides(only: {slotIndex});
      // L'entrée et le dessert rendus avec le plat, quand le format en
      // demandait ; un créneau régénéré sans eux garde ceux qu'il avait.
      if (suggestion.starter != null) {
        _slotStarters[slotIndex] = MealComponent.recipe(
          suggestion.starter!,
          role: MealComponentRole.entree,
          justification: suggestion.source.label,
        );
      }
      if (suggestion.dessert != null) {
        _slotDesserts[slotIndex] = MealComponent.recipe(
          suggestion.dessert!,
          role: MealComponentRole.dessert,
          justification: suggestion.source.label,
        );
      }
    });
  }

  /// Produit le conseil de conservation d'un créneau, ou relit celui qui
  /// existe. Seuls le créateur de la recette et un administrateur en
  /// produisent un : les autres reçoivent une explication.
  ///
  /// Le conseil appartient au plat, pas au repas : une fois produit, tous les
  /// créneaux portant cette recette l'affichent sans repayer d'appel. Il vit
  /// sur la recette, dans son champ dédié, et nulle part ailleurs — l'écrire
  /// aussi dans le texte en aurait fait deux versions à tenir d'accord.
  Future<void> _generateStorageAdvice(int slotIndex) async {
    final recipe = _slots[slotIndex];
    if (recipe == null || recipe.id.isEmpty) {
      _showError('Assignez d\'abord une recette à ce créneau.');
      return;
    }
    setState(() => _storageLoadingSlots.add(slotIndex));
    try {
      final canGenerate = await ref.read(canWriteRecipeAdviceProvider.future);
      final lookup = await ref
          .read(storageRepositoryProvider)
          .ensure(recipeId: recipe.id, canGenerate: canGenerate);
      if (!mounted) return;
      switch (lookup) {
        case StorageAdviceAvailable(:final advice):
          setState(() => _storageAdviceByRecipe[recipe.id] = advice);
          context.showSuccessSnackBar('Conservation de « ${recipe.titre} » ✓');
        case StorageAdviceReserved():
          setState(() => _storageReservedRecipeIds.add(recipe.id));
        case StorageAdviceRecipeMissing():
          _showError(kRecipeNotFoundMessage);
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.generateStorageAdvice',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur conservation : $e');
    } finally {
      if (mounted) {
        setState(() => _storageLoadingSlots.remove(slotIndex));
      }
    }
  }

  /// Navigation vers la recette (detail ou draft).
  ///
  /// Les parts visées par le créneau voyagent en paramètre : la fiche s'ouvre
  /// à l'échelle du repas, sans que rien ne soit écrit sur la recette.
  void _onRecipeTap(Recipe recipe, int slotIndex) {
    if (recipe.id.isEmpty) return;
    if (recipe.reviewStatus != ReviewStatus.validated) {
      context.push('${AppRoutes.drafts}/${recipe.id}');
      return;
    }
    final target = _slotConstraints[slotIndex]?.targetPortions ?? 0;
    final suffix = target > 0 && target != recipe.portions
        ? '?portions=$target'
        : '';
    context.push('${AppRoutes.recipes}/${recipe.id}$suffix');
  }

  /// Les repas servis dans la fenêtre de variété, lus au moment de générer.
  ///
  /// Lus à la demande et non à l'ouverture : la fenêtre se compte depuis le
  /// premier jour du cycle, et ce jour peut changer d'ici là. Best-effort :
  /// une lecture qui échoue ne bloque pas la suggestion, elle la rend seulement
  /// aveugle à l'historique — et le dit dans les rapports d'erreurs.
  Future<List<RecentlyServedMeal>> _loadRecentlyServed() async {
    final repo = ref.read(planningRepositoryProvider);
    final prefs = _prefs;
    if (repo == null || prefs == null || _slotDates.isEmpty) return const [];
    if (prefs.varietyWindowWeeks == 0) return const [];
    final cycleStart = _slotDates.first;
    try {
      // La variété regarde tout ce que le cuisinier a servi, planning
      // personnel et plannings de ses groupes : le même plat ne revient pas
      // d'un planning à l'autre.
      final meals = await repo.getCookedMealsBetween(
        from: varietyWindowStart(
          cycleStart: cycleStart,
          windowWeeks: prefs.varietyWindowWeeks,
        ),
        to: DateTime(cycleStart.year, cycleStart.month, cycleStart.day - 1),
      );
      return recentlyServedBefore(
        meals,
        cycleStart: cycleStart,
        windowWeeks: prefs.varietyWindowWeeks,
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.loadRecentlyServed',
        error: e,
        stackTrace: stackTrace,
      );
      return const [];
    }
  }

  /// Reprend les repas d'une semaine passée sur les créneaux vides.
  ///
  /// « Prends ce qu'on a fait il y a deux semaines » ne demande rien à l'IA :
  /// les repas sont déjà là. Les recettes absentes des corpus chargés sont
  /// relues par identifiant — un repas peut pointer sur un brouillon ou une
  /// recette de la famille ; celles qui n'existent plus sont comptées et
  /// dites, pas inventées.
  Future<void> _replayPastWeek() async {
    final repo = ref.read(planningRepositoryProvider);
    final prefs = _prefs;
    if (repo == null || prefs == null || _slotDates.isEmpty) return;
    if (!_slots.values.any((r) => r == null)) {
      _showError('Tous les créneaux sont déjà remplis.');
      return;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    List<ReplayableWeek> weeks;
    try {
      // La même profondeur que l'écran du planning : ce qu'on peut relire,
      // on peut le reprendre.
      final meals = await repo.getMealsBetween(
        from: today.subtract(PlanningRepository.historyWindow),
        to: _slotDates.last,
        groupId: widget.groupId,
      );
      weeks = replayableWeeks(
        meals,
        cycleStartDay: prefs.cycleStartDay,
        cycleDates: _slotDates,
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.replayPastWeek.load',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Impossible de lire les semaines passées : $e');
      return;
    }
    if (!mounted) return;
    if (weeks.isEmpty) {
      _showError('Aucune semaine passée avec des repas à reprendre.');
      return;
    }

    final chosen = await showModalBottomSheet<ReplayableWeek>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ReplayWeekSheet(weeks: weeks, today: today),
    );
    if (chosen == null || !mounted) return;

    final byId = <String, Recipe>{
      for (final r in _allRecipes)
        if (r.id.isNotEmpty) r.id: r,
    };
    final missing = chosen.recipeIds
        .where((id) => !byId.containsKey(id))
        .toList(growable: false);
    if (missing.isNotEmpty) {
      try {
        for (final r in await repo.getRecipesByIds(missing)) {
          byId[r.id] = r;
        }
      } catch (e, stackTrace) {
        // Elles resteront comptées introuvables : la reprise continue avec
        // ce qu'on a, et l'échec part dans les rapports.
        reportUnexpectedError(
          feature: 'batchPlanningScreen.replayPastWeek.resolve',
          error: e,
          stackTrace: stackTrace,
          context: {'missing': missing.length},
        );
      }
    }
    if (!mounted) return;

    final replay = replayWeek(
      source: chosen,
      slotDates: _slotDates,
      slots: _slots,
      recipesById: byId,
    );
    final weekLabel = DateFormat('d MMM', 'fr').format(chosen.week.start);
    if (replay.applied == 0) {
      _showError(
        replay.skippedMissing > 0
            ? 'Aucun repas repris : les recettes de la semaine du $weekLabel '
                  'sont introuvables.'
            : 'Aucun repas de la semaine du $weekLabel ne tombe sur un '
                  'créneau vide.',
      );
      return;
    }
    setState(() {
      for (final e in replay.assignments.entries) {
        _slots[e.key] = e.value;
        _slotJustifications[e.key] = 'Repris de la semaine du $weekLabel.';
        _slotSources[e.key] = MealChoiceSource.manual;
        _slotWasResized[e.key] = false;
        _slotResizeReasons.remove(e.key);
        _slotPrepDates.remove(e.key);
        _slotIsGenerated.remove(e.key);
        _slotSideManual.remove(e.key);
      }
      _recomputeSides(only: replay.assignments.keys.toSet());
    });
    final details = <String>[
      if (replay.skippedMissing > 0)
        '${replay.skippedMissing} recette'
            '${replay.skippedMissing > 1 ? 's' : ''} introuvable'
            '${replay.skippedMissing > 1 ? 's' : ''}',
      if (replay.skippedDuplicate > 0)
        '${replay.skippedDuplicate} déjà posée'
            '${replay.skippedDuplicate > 1 ? 's' : ''}',
    ];
    context.showSuccessSnackBar(
      '${replay.applied} repas repris de la semaine du $weekLabel'
      '${details.isEmpty ? '' : ' · ${details.join(', ')}'} ✓',
    );
  }

  /// Les accompagnements possibles : les garnitures visibles de l'utilisateur
  /// et les recettes d'accompagnement des corpus chargés.
  List<SideCandidate> get _sideCandidates =>
      sideCandidatesFrom(staples: _staples, recipes: _allRecipes);

  /// Recompose les accompagnements des créneaux, dans l'ordre des jours.
  ///
  /// Le programme choisit ; un créneau dont l'accompagnement a été posé à la
  /// main garde son choix tant que le plat ne change pas. Un accompagnement
  /// ne revient pas deux jours de suite quand un autre est possible, ni deux
  /// fois dans le cycle tant qu'il en reste. [only] limite le recalcul à
  /// quelques créneaux, les autres gardant ce qu'ils ont.
  void _recomputeSides({Set<int>? only}) {
    final candidates = _sideCandidates;
    final next = <int, MealComponent?>{};
    final used = <String>{};
    for (var i = 0; i < _slotDates.length; i++) {
      final recipe = _slots[i];
      if (recipe == null) {
        next[i] = null;
        continue;
      }
      final keep =
          _slotSideManual.contains(i) || (only != null && !only.contains(i));
      if (keep) {
        next[i] = _slotSides[i];
        final id = _slotSides[i]?.sourceId;
        if (id != null) used.add(id);
        continue;
      }
      final avoid = <String>{
        ?next[i - 1]?.sourceId,
        ?_slotSides[i + 1]?.sourceId,
      };
      final choice = chooseSide(
        main: recipe,
        candidates: candidates,
        avoidIds: avoid,
        usedInCycleIds: used,
      );
      next[i] = choice?.component;
      if (choice != null) used.add(choice.component.sourceId);
    }
    _slotSides = next;
  }

  /// Choisir l'accompagnement d'un créneau à la main.
  Future<void> _changeSide(int index) async {
    final recipe = _slots[index];
    if (recipe == null) return;
    final result = await showModalBottomSheet<SidePickerResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SidePickerSheet(
        main: recipe,
        candidates: _sideCandidates,
        current: _slotSides[index],
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _slotSideManual.add(index);
      _slotSides[index] = result.toComponent(
        justification: 'Choisi à la main.',
      );
    });
  }

  void _removeSide(int index) => setState(() {
    _slotSideManual.add(index);
    _slotSides[index] = null;
  });

  /// Décale les clés à partir de [insertedAt] d'un cran vers le haut, pour
  /// un jour inséré au milieu du cycle.
  static Map<int, T> _shiftAfterInsert<T>(Map<int, T> map, int insertedAt) => {
    for (final e in map.entries)
      (e.key < insertedAt ? e.key : e.key + 1): e.value,
  };

  /// Retire la clé [removedAt] et ramène les suivantes d'un cran.
  static Map<int, T> _shiftAfterRemove<T>(Map<int, T> map, int removedAt) => {
    for (final e in map.entries)
      if (e.key != removedAt) (e.key < removedAt ? e.key : e.key - 1): e.value,
  };

  /// Choisir l'entrée ou le dessert d'un créneau à la main, parmi les
  /// recettes de ce rôle.
  Future<void> _changeCourse(int index, MealComponentRole role) async {
    final wanted = role == MealComponentRole.entree ? 'entree' : 'dessert';
    final candidates = [
      for (final r in _allRecipes)
        if (r.id.isNotEmpty && r.tags.mealRole == wanted) r,
    ];
    if (candidates.isEmpty) {
      _showError(
        'Aucune recette classée en ${role.label.toLowerCase()}. Classez vos '
        'recettes depuis Admin › Backfills, ou changez le format du créneau.',
      );
      return;
    }
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: candidates,
        dismissedRecipeIds: const {},
        dismissedFrom: 'créneau',
      ),
    );
    if (recipe == null || !mounted) return;
    setState(() {
      final component = MealComponent.recipe(
        recipe,
        role: role,
        justification: 'Choisi à la main.',
      );
      if (role == MealComponentRole.entree) {
        _slotStarters[index] = component;
      } else {
        _slotDesserts[index] = component;
      }
    });
  }

  void _removeCourse(int index, MealComponentRole role) => setState(() {
    if (role == MealComponentRole.entree) {
      _slotStarters[index] = null;
    } else {
      _slotDesserts[index] = null;
    }
  });

  void _showError(String msg) {
    if (!mounted) return;
    context.showErrorSnackBar(msg);
  }

  /// Pose l'événement Google Calendar d'un repas tel qu'il sera au planning :
  /// même lien, mêmes parts, même jour de préparation, mêmes accompagnements.
  ///
  /// L'événement dure la durée par défaut des préférences : dans le
  /// calendrier, le repas est le moment où l'on mange, pas celui où l'on
  /// prépare. Les temps de la recette ne servent qu'au rappel.
  ///
  /// [token] : jeton déjà obtenu, pour une série d'événements sans rouvrir
  /// la fenêtre d'autorisation à chacun.
  Future<void> _createCalendarEvent(PlannedMeal meal, {String? token}) {
    final prefs = _prefs ?? const PlanningPreferences();
    return CalendarService.createEvent(
      titre: meal.recipeTitre,
      startTime: meal.plannedAt,
      duration: Duration(minutes: prefs.defaultCalendarDurationMinutes),
      description: mealCalendarDescription(meal),
      reminderMinutes: meal.prepMinutes ?? 30,
      calendarId: prefs.calendarId,
      token: token,
    );
  }

  /// Pose dans Google Calendar les événements de [meals], avec un seul jeton.
  ///
  /// Rend le nombre d'événements créés, et le message d'erreur si le jeton
  /// n'a pas pu être obtenu. Un événement qui échoue est signalé et compté
  /// en moins ; les autres sont posés quand même.
  Future<({int exported, String? tokenError})> _exportMealsToCalendar(
    List<PlannedMeal> meals,
  ) async {
    if (meals.isEmpty) return (exported: 0, tokenError: null);
    final String token;
    try {
      token = await CalendarService.getToken();
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.exportMealsToCalendarToken',
        error: e,
        stackTrace: stackTrace,
      );
      return (exported: 0, tokenError: '$e');
    }
    var exported = 0;
    for (final meal in meals) {
      try {
        await _createCalendarEvent(meal, token: token);
        exported++;
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'batchPlanningScreen.exportMealsToCalendar',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
    return (exported: exported, tokenError: null);
  }

  /// Exporte le repas du slot [index] vers Google Calendar, et l'enregistre
  /// au planning dans le même geste.
  ///
  /// Le repas est écrit sous son identifiant s'il l'a déjà été depuis ce
  /// créneau : un second appui met à jour, il ne double pas.
  Future<void> _exportSlotToCalendar(int index) async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    final meal = _plannedMealForSlot(index, uid: repo.uid);
    if (meal == null) return;
    try {
      await _createCalendarEvent(meal);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.exportSlotToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur Calendar : $e');
      return;
    }

    // Un repas déjà au planning et resté tel quel n'a pas à y être réécrit :
    // l'écran ne connaît pas tout ce qu'il porte.
    if (_isUnchangedRegistered(meal)) {
      if (!mounted) return;
      context.showSuccessSnackBar(
        '« ${meal.recipeTitre} » ajouté au calendrier ✓',
      );
      return;
    }

    // L'événement est posé ; le repas entre au planning avec le même
    // contenu. Un échec ici se dit tel quel : le calendrier a l'événement,
    // le planning n'a pas le repas, et « Valider » le rattrapera.
    try {
      final ids = await repo.saveMeals([meal]);
      if (!mounted) return;
      setState(() => _slotSavedMealIds[index] = ids.single);
      context.showSuccessSnackBar(
        '« ${meal.recipeTitre} » ajouté au calendrier et au planning ✓',
      );
      await _ensureStorageAdviceForPreparedMeals([meal]);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.exportSlotSaveMeal',
        error: e,
        stackTrace: stackTrace,
      );
      _showError(
        'Événement créé, mais le repas n\'a pas pu être enregistré au '
        'planning : $e',
      );
    }
  }

  /// Le groupe visé, une fois ses groupes lus ; null pour « Mon planning ».
  FamilyGroup? _group;

  /// « Nouveau planning », ou « Nouveau planning — Famille Dupont ».
  String get _title => _group == null
      ? 'Nouveau planning'
      : 'Nouveau planning — ${_group!.name}';

  @override
  Widget build(BuildContext context) {
    final groupId = widget.groupId;
    if (groupId != null) {
      // Le planning d'un groupe ne s'ouvre qu'à son propriétaire : la cible
      // est résolue avant tout, et l'écran ne planifie pas « à côté ».
      final owned = ref.watch(ownedPlanningGroupsProvider);
      if (owned.hasError && !owned.hasValue) {
        return Scaffold(
          appBar: AppBar(title: const Text('Nouveau planning')),
          body: AppErrorState(
            error: owned.error,
            title: 'Vos groupes n\'ont pas pu être lus',
            onRetry: () => ref.invalidate(myGroupsProvider),
          ),
        );
      }
      if (!owned.hasValue) {
        return const Scaffold(
          appBar: _NewPlanningAppBar(),
          body: AppLoadingState(),
        );
      }
      final group = owned.value!.where((g) => g.id == groupId).firstOrNull;
      if (group == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('Nouveau planning')),
          body: AppEmptyState(
            icon: Icons.groups_outlined,
            title: 'Le planning de ce groupe ne vous est pas accessible.',
            message:
                'Seul le propriétaire du groupe, éditeur, planifie pour lui.',
            action: FilledButton(
              onPressed: () => context.go(AppRoutes.planning),
              child: const Text('Retour au planning'),
            ),
          ),
        );
      }
      _group = group;
    }
    final prefsAsync = ref.watch(planningPreferencesOnceProvider);

    return prefsAsync.when(
      loading: () =>
          const Scaffold(appBar: _NewPlanningAppBar(), body: AppLoadingState()),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: Text(_title)),
        body: AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(planningPreferencesOnceProvider),
        ),
      ),
      data: (prefs) {
        _applyPrefs(prefs);
        return _buildScaffold(prefs);
      },
    );
  }

  Widget _buildScaffold(PlanningPreferences prefs) {
    final effectivePrefs = _prefs ?? prefs;
    final assignedCount = _slots.values.where((r) => r != null).length;
    final totalSlots = _slotDates.length;
    // Ce que « Valider » écrira : les repas déjà au planning et restés tels
    // quels n'y comptent pas.
    final writeCount = _validationPlan(
      ref.read(planningRepositoryProvider)?.uid ?? '',
    ).toWrite.length;
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    _syncLeaveGuard(writeCount > 0 && !_validated);
    final canValidate = writeCount > 0 && !_saving;

    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(_title),
        centerTitle: false,
        actions: [
          if (_constraintsLocked)
            IconButton(
              icon: const Icon(Icons.edit_note_outlined),
              tooltip: 'Modifier les contraintes',
              onPressed: () => setState(() => _constraintsLocked = false),
            ),
          // Reprendre une semaine passée n'est pas une action d'IA : elle a
          // sa propre icône, sur les deux dispositions.
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Reprendre une semaine passée',
            onPressed: _recipesLoaded && !_generating ? _replayPastWeek : null,
          ),
          // Sur grand écran, la même action vit dans le panneau de gauche,
          // sous forme de bouton nommé, au-dessus de « Valider ». Une icône
          // seule dans un coin n'apprend pas ce qu'elle fait, et c'est
          // pourtant l'action principale de l'écran.
          if (!isWide) ...[
            if (_generating)
              const Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              PopupMenuButton<int>(
                icon: const Icon(Icons.auto_awesome_outlined),
                tooltip: 'Suggérer avec l\'IA',
                enabled: _recipesLoaded,
                onSelected: (value) =>
                    _generateWithAI(replaceExisting: value == 1),
                itemBuilder: (_) => _aiMenuItems(),
              ),
          ],
        ],
      ),
      body: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 320,
                  child: _buildSidePanel(
                    assignedCount: assignedCount,
                    totalSlots: totalSlots,
                    writeCount: writeCount,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: _buildSlotGrid(effectivePrefs)),
              ],
            )
          : Column(
              children: [
                _buildCycleBanner(assignedCount, totalSlots),
                ?_buildNotice(),
                Expanded(child: _buildSlotList(effectivePrefs)),
              ],
            ),
      // Sur grand écran, « Valider » vit au pied du panneau de gauche.
      bottomNavigationBar: isWide
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: _buildValidateButton(writeCount),
              ),
            ),
    );

    // Ctrl+S valide le cycle, comme « Enregistrer » ailleurs. Le retour —
    // bouton, geste, flèche de la barre — passe par PopScope ; la navigation
    // du shell passe par le garde de sortie.
    return PopScope(
      canPop: writeCount == 0 || _validated,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(_leaveAfterConfirmation());
      },
      child: AppShortcuts(
        onSave: canValidate ? _validate : null,
        child: scaffold,
      ),
    );
  }

  /// Pose ou retire le garde de sortie selon qu'il reste des repas à valider.
  ///
  /// Après le rendu : un provider ne se modifie pas pendant `build`.
  void _syncLeaveGuard(bool dirty) {
    if (dirty == _leaveGuardSet) return;
    _leaveGuardSet = dirty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (dirty) {
        _leaveGuardNotifier.set(_leaveGuard);
      } else {
        _leaveGuardNotifier.clearIf(_leaveGuard);
      }
    });
  }

  /// Quitte l'écran si l'utilisateur renonce aux repas non validés.
  Future<void> _leaveAfterConfirmation() async {
    if (!await _confirmLeave() || !mounted) return;
    _validated = true;
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoutes.planning);
    }
  }

  /// La question posée avant de quitter un cycle composé mais pas validé.
  ///
  /// Vrai quand on peut partir : rien à valider, ou l'utilisateur renonce.
  Future<bool> _confirmLeave() async {
    if (_validated) return true;
    final pending = _validationPlan(
      ref.read(planningRepositoryProvider)?.uid ?? '',
    ).toWrite.length;
    if (pending == 0) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter sans valider ?'),
        content: Text(
          pending == 1
              ? 'Le repas composé sur cet écran n\'est pas enregistré au '
                    'planning. Il sera perdu.'
              : 'Les $pending repas composés sur cet écran ne sont pas '
                    'enregistrés au planning. Ils seront perdus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rester'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(ctx).colorScheme.error,
            ),
            child: const Text('Quitter sans valider'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }

  /// « 16 → 22 oct. · 7/7 repas » : les bornes du cycle et son remplissage.
  Widget _buildCycleBanner(int assignedCount, int totalSlots) {
    final theme = Theme.of(context);
    final String label;
    // Lu à voix haute : ni « flèche droite » ni « barre oblique ».
    String spoken;
    if (_slotDates.isEmpty) {
      label = 'Chargement…';
      spoken = label;
    } else {
      final first = _slotDates.first;
      final last = _slotDates.last;
      final sameMonth = first.year == last.year && first.month == last.month;
      final from = DateFormat(sameMonth ? 'd' : 'd MMM', 'fr').format(first);
      final to = DateFormat('d MMM', 'fr').format(last);
      // Le planning d'un groupe se nomme en tête : « Famille Dupont · 16 →
      // 22 oct. · 7/7 repas ».
      final group = _group == null ? '' : '${_group!.name} · ';
      label = '$group$from → $to · $assignedCount/$totalSlots repas';
      spoken =
          '${_group == null ? '' : 'Planning du groupe ${_group!.name}, '}'
          'du ${DateFormat('d MMMM', 'fr').format(first)} au '
          '${DateFormat('d MMMM', 'fr').format(last)}, '
          '$assignedCount repas sur $totalSlots';
    }
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.calendar_month_outlined,
            size: AppIconSize.small,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              label: spoken,
              excludeSemantics: true,
              child: Text(label, style: theme.textTheme.bodyMedium),
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildNotice() {
    if (_notice == null) return null;
    return PlanningNoticeBanner(
      message: _notice!,
      actionLabel: _noticeRetry ? 'Réessayer avec l\'IA' : null,
      onAction: _noticeRetry && !_generating ? _retryWithAI : null,
      onClose: () => setState(() {
        _notice = null;
        _noticeRetry = false;
      }),
    );
  }

  /// Le champ des consignes du cycle, partagé par les deux dispositions.
  Widget _buildGlobalConstraintsField({required int minLines}) {
    return StylusPadTextField(
      controller: _globalConstraintsCtrl,
      minLines: minLines,
      maxLines: 8,
      decoration: const InputDecoration(
        labelText: 'Consignes du cycle',
        hintText: 'Ex: pas de dessert, varier protéines, utiliser les restes',
        border: OutlineInputBorder(),
      ),
    );
  }

  Widget _buildValidateButton(int writeCount) {
    final scheme = Theme.of(context).colorScheme;
    return FilledButton.icon(
      onPressed: (writeCount == 0 || _saving) ? null : _validate,
      icon: _saving
          ? SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onPrimary,
              ),
            )
          : const Icon(Icons.check_circle_outline),
      label: Text('Valider le planning ($writeCount repas)'),
    );
  }

  /// Panneau de gauche du grand écran : le cycle, l'avis, les consignes, et
  /// au pied les deux actions de l'écran, toujours visibles.
  Widget _buildSidePanel({
    required int assignedCount,
    required int totalSlots,
    required int writeCount,
  }) {
    return SafeArea(
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildCycleBanner(assignedCount, totalSlots),
                  ?_buildNotice(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: _buildGlobalConstraintsField(minLines: 3),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PlanWithAiButton(
                  generating: _generating,
                  enabled: _recipesLoaded,
                  emptySlots: totalSlots - assignedCount,
                  itemBuilder: _aiMenuItems,
                  onSelected: (value) =>
                      _generateWithAI(replaceExisting: value == 1),
                ),
                const SizedBox(height: 8),
                _buildValidateButton(writeCount),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Les consignes du cycle sur téléphone : repliées, elles laissent la place
  /// aux créneaux, et le titre dit combien de règles elles portent.
  Widget _buildConstraintsTile() {
    return Card.outlined(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        // L'état ouvert vit dans l'écran, pas dans un PageStorageKey : la
        // clé serait partagée avec le défilement du champ multiligne, qui y
        // range un double.
        initiallyExpanded: _cycleConstraintsExpanded,
        onExpansionChanged: (open) => _cycleConstraintsExpanded = open,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.rule_outlined),
        title: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _globalConstraintsCtrl,
          builder: (context, value, _) {
            final rules = value.text
                .split('\n')
                .where((line) => line.trim().isNotEmpty)
                .length;
            final count = rules == 0
                ? 'aucune'
                : '$rules règle${rules > 1 ? 's' : ''}';
            return Text('Consignes du cycle · $count');
          },
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [_buildGlobalConstraintsField(minLines: 3)],
      ),
    );
  }

  /// Téléphone : les consignes, les créneaux, puis « Ajouter un jour », dans
  /// une seule liste qui défile.
  Widget _buildSlotList(PlanningPreferences effectivePrefs) {
    if (_slotDates.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      // +1 pour les consignes, +1 pour « Ajouter un jour ».
      itemCount: _slotDates.length + 2,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) return _buildConstraintsTile();
        final slot = index - 1;
        if (slot == _slotDates.length) {
          return AddSlotDayCard(onPressed: _addDay);
        }
        return _buildSlotTile(slot, effectivePrefs);
      },
    );
  }

  /// Grand écran : les créneaux en colonnes sur toute la largeur, autant de
  /// colonnes qu'il en faut pour qu'aucune carte ne dépasse
  /// [kBatchSlotCardMaxWidth].
  ///
  /// Des colonnes indépendantes plutôt qu'une grille : une carte dépliée est
  /// plus haute que ses voisines, et une grille à hauteur fixe la
  /// tronquerait. L'ordre de lecture reste ligne par ligne : le créneau `i`
  /// va dans la colonne `i % colonnes`.
  Widget _buildSlotGrid(PlanningPreferences effectivePrefs) {
    if (_slotDates.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    const gap = 12.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final usable = constraints.maxWidth - 2 * 16;
        // Des cartes de 560 px au plus, et de 340 px au moins : sous cette
        // largeur, l'éditeur des contraintes d'une carte dépliée se tasse.
        final columns = math.max(
          1,
          math.min(
            (usable / kBatchSlotCardMaxWidth).ceil(),
            (usable / kBatchSlotCardMinWidth).floor(),
          ),
        );
        final items = <Widget>[
          for (var i = 0; i < _slotDates.length; i++)
            _buildSlotTile(i, effectivePrefs),
          AddSlotDayCard(onPressed: _addDay),
        ];
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) const SizedBox(width: gap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = c; i < items.length; i += columns) ...[
                        if (i >= columns) const SizedBox(height: gap),
                        items[i],
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSlotTile(int index, PlanningPreferences effectivePrefs) {
    return BatchSlotTile(
      // La date identifie le créneau : supprimer un jour ne fait pas passer
      // l'état d'une carte (pli ouvert) à sa voisine.
      key: ValueKey(_slotDates[index]),
      index: index,
      date: _slotDates[index],
      recipe: _slots[index],
      savedToPlanning: _slotSavedMealIds.containsKey(index),
      constraintsReadOnly: _constraintsLocked,
      isBatchDay: effectivePrefs.batchCookingDay == _slotDates[index].weekday,
      dayConstraint: _slotConstraints[index] ?? const DayConstraint(),
      slotTime: _slotTimes[index] ?? _defaultTime,
      isGenerating:
          _generatingSlot == index || _conceivingSlots.contains(index),
      conceiving: _conceivingSlots.contains(index),
      justification: _slotJustifications[index],
      choiceSource: _slotSources[index],
      prepDate: _slotPrepDates[index],
      wasResized: _slotWasResized[index] ?? false,
      resizeReason: _slotResizeReasons[index],
      isGeneratedByAI: _slotIsGenerated[index] ?? false,
      storageAdvice: _storageAdviceFor(index),
      storageLoading: _storageLoadingSlots.contains(index),
      storageReserved: _storageReservedRecipeIds.contains(_slots[index]?.id),
      // Offert dès qu'une recette est posée : la conservation se demande
      // aussi pour un plat qu'on décide de garder après coup, et l'exiger
      // d'un créneau « réchauffage » rendait la fonction introuvable sans
      // jour de préparation configuré.
      onGenerateStorageAdvice: (_slots[index]?.id.isNotEmpty ?? false)
          ? () => _generateStorageAdvice(index)
          : null,
      onAssign: () => _pickRecipeForSlot(index),
      onRemove: () async {
        if (!await _confirmLoss(
          index,
          title: 'Retirer la recette ?',
          action: 'Retirer',
        )) {
          return;
        }
        setState(() {
          _slots[index] = null;
          _slotSides.remove(index);
          _slotSideManual.remove(index);
          _slotStarters.remove(index);
          _slotDesserts.remove(index);
          _slotJustifications.remove(index);
          _slotPrepDates.remove(index);
          _slotWasResized.remove(index);
          _slotResizeReasons.remove(index);
          _slotIsGenerated.remove(index);
          _slotSources.remove(index);
        });
      },
      onDelete: () async {
        if (await _confirmLoss(
          index,
          title: 'Supprimer ce jour ?',
          action: 'Supprimer',
        )) {
          _removeDay(index);
        }
      },
      onTimeChanged: (t) => setState(() => _slotTimes[index] = t),
      onMaxPrepChanged: (maxPrep) => setState(() {
        final current = _slotConstraints[index] ?? const DayConstraint();
        _slotConstraints[index] = current.copyWith(maxPrepMinutes: maxPrep);
        // La liste classée ne vaut plus pour ce créneau.
        _slotRankings.remove(index);
      }),
      onTargetPortionsChanged: (targetPortions) => setState(() {
        final current = _slotConstraints[index] ?? const DayConstraint();
        _slotConstraints[index] = current.copyWith(
          targetPortions: targetPortions,
        );
      }),
      onReheatChanged: (isReheat) => setState(() {
        final current = _slotConstraints[index] ?? const DayConstraint();
        _slotConstraints[index] = current.copyWith(isBatchCooking: isReheat);
        _slotRankings.remove(index);
      }),
      onNotesChanged: (notes) => setState(() {
        final current = _slotConstraints[index] ?? const DayConstraint();
        _slotConstraints[index] = current.copyWith(notes: notes);
      }),
      onGenerateWithAI: _recipesLoaded ? () => _otherSuggestion(index) : null,
      onExportToCalendar: _slots[index] != null
          ? () => _exportSlotToCalendar(index)
          : null,
      onRecipeTap: _slots[index] != null
          ? () => _onRecipeTap(_slots[index]!, index)
          : null,
      side: _slotSides[index],
      onChangeSide: _slots[index] != null ? () => _changeSide(index) : null,
      onRemoveSide: _slotSides[index] != null ? () => _removeSide(index) : null,
      starter: _slotStarters[index],
      dessert: _slotDesserts[index],
      onChangeStarter: _slots[index] != null
          ? () => _changeCourse(index, MealComponentRole.entree)
          : null,
      onRemoveStarter: _slotStarters[index] != null
          ? () => _removeCourse(index, MealComponentRole.entree)
          : null,
      onChangeDessert: _slots[index] != null
          ? () => _changeCourse(index, MealComponentRole.dessert)
          : null,
      onRemoveDessert: _slotDesserts[index] != null
          ? () => _removeCourse(index, MealComponentRole.dessert)
          : null,
      // Le plat seul est le défaut : le choisir remet le créneau à « pas
      // réglé », il n'est jamais stocké.
      onFormatChanged: (f) => setState(() {
        final current = _slotConstraints[index] ?? const DayConstraint();
        _slotConstraints[index] = f == MealFormat.defaultFormat
            ? current.copyWith(clearMealFormat: true)
            : current.copyWith(mealFormat: f);
        _slotRankings.remove(index);
      }),
    );
  }

  /// Les deux façons de demander des suggestions, définies une seule fois.
  ///
  /// Le menu est le même en haut sur mobile et en bas sur grand écran : deux
  /// copies auraient divergé au premier libellé changé.
  List<PopupMenuEntry<int>> _aiMenuItems() => const [
    PopupMenuItem(
      value: 0,
      child: ListTile(
        leading: Icon(Icons.playlist_add_outlined),
        title: Text('Compléter les créneaux vides'),
        contentPadding: EdgeInsets.zero,
      ),
    ),
    PopupMenuItem(
      value: 1,
      child: ListTile(
        leading: Icon(Icons.refresh),
        title: Text('Tout régénérer'),
        // Dire « les créneaux de cet écran » et non « les choix » : rien n'est
        // touché dans le planning déjà enregistré, et le laisser entendre
        // serait un contresens.
        subtitle: Text('Vide les créneaux de cet écran'),
        contentPadding: EdgeInsets.zero,
      ),
    ),
  ];
}

/// La barre de « Nouveau planning » pendant un chargement : le titre est là
/// avant le contenu, et le retour reste possible.
class _NewPlanningAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _NewPlanningAppBar();

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) =>
      AppBar(title: const Text('Nouveau planning'));
}
