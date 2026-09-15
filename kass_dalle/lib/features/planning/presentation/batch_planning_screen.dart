import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/storage_advice.dart';
import '../../groups/presentation/group_providers.dart';
import '../../books/presentation/book_providers.dart';
import '../domain/calendar_event_description.dart';
import '../domain/meal_candidates.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_history.dart';
import '../domain/planning_preferences.dart';
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
import '../../recipes/presentation/recipe_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Décision prise au moment de valider un planning qui recouvre des repas
/// déjà enregistrés.
enum _ValidateChoice { cancel, append, replace }

/// Écran de génération de planning en masse (Axe B).
///
/// Permet de planifier plusieurs repas d'un coup sur un cycle entier,
/// avec suggestion IA ou assignation manuelle.
class BatchPlanningScreen extends ConsumerStatefulWidget {
  const BatchPlanningScreen({super.key});

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
  Map<int, DayConstraint> _slotConstraints = {};
  // Recettes écartées de chaque créneau pendant cette session : une nouvelle
  // suggestion ne les repropose pas, et elles suivent le repas à la validation.
  Map<int, Set<String>> _slotDismissed = {};
  // Identifiant du repas déjà enregistré pour un créneau, depuis son icône
  // calendrier. « Valider » réécrit ce repas sous le même identifiant au lieu
  // d'en créer un second sur la même date.
  Map<int, String> _slotSavedMealIds = {};
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
  final Set<int> _storageLoadingSlots = {};

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
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
    _slotConstraints = {
      for (int i = 0; i < dates.length; i++)
        i: prefs.dailyConstraints[dates[i].weekday] ?? const DayConstraint(),
    };
    _globalConstraintsCtrl.text = prefs.globalConstraints;
  }

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

  /// Demande où chercher des recettes, puis génère.
  ///
  /// La question est la même que pour un créneau isolé, et elle est posée par
  /// le même widget : planifier une semaine ou un jour, c'est le même choix —
  /// mes recettes, mes brouillons, celles de la famille, et faut-il inventer
  /// quand rien ne convient. Le bouton global l'ignorait, et générait toujours
  /// depuis les seules recettes validées : deux comportements pour une même
  /// action, dont un que rien à l'écran n'annonçait.
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
      ),
    );
    if (scope == null || scope.sources.isEmpty || !mounted) return;
    final sources = scope.sources;
    _selectedSources = sources;
    _selectedBookIds = scope.bookIds;
    unawaited(_persistSearchScope(scope));

    final pool = <Recipe>[
      if (sources.contains(RecipeSource.myRecipes))
        ..._availableRecipes.where(scope.matchesBook),
      if (sources.contains(RecipeSource.myDrafts))
        ..._draftRecipes.where(scope.matchesBook),
      if (sources.contains(RecipeSource.familyRecipes))
        ..._familyRecipes.where(scope.matchesBook),
    ];
    final mayConceive = sources.contains(RecipeSource.aiCreation);

    if (pool.isEmpty && !mayConceive) {
      _showError('Aucune recette disponible dans les sources sélectionnées.');
      return;
    }

    if (replaceExisting) {
      setState(() {
        // Tout regénérer, c'est écarter tout ce qui était en place : ces
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
      });
    } else if (!_slots.values.any((r) => r == null)) {
      _showError(
        'Tous les créneaux sont déjà remplis — utilisez « Tout regénérer ».',
      );
      return;
    }
    setState(() => _generating = true);
    try {
      final prefs = _prefs ?? const PlanningPreferences();
      final dailyConstraints = _dailyConstraintsForAI();
      // Passer les repas déjà assignés pour éviter les répétitions
      final alreadyAssigned = [
        for (final e in _slots.entries)
          if (e.value != null && e.value!.id.isNotEmpty)
            (slot: e.key, recipeId: e.value!.id),
      ];
      final recentlyServed = pool.isEmpty
          ? const <RecentlyServedMeal>[]
          : await _loadRecentlyServed();
      final suggestion = pool.isEmpty
          ? const MealPlanSuggestion(slots: [], excludedRecentCount: 0)
          : await ref
                .read(planningAiServiceProvider)
                .suggestMealPlan(
                  recipes: pool,
                  slotDates: _slotDates,
                  dailyConstraints: dailyConstraints,
                  slotConstraints: _slotConstraintsForAI(),
                  globalConstraints: _globalConstraintsCtrl.text.trim(),
                  batchCookingDay: prefs.batchCookingDay,
                  alreadyAssigned: alreadyAssigned,
                  recentlyServed: recentlyServed,
                );
      final suggestions = suggestion.slots;
      if (mounted) {
        setState(() {
          _constraintsLocked = true;
          for (int i = 0; i < suggestions.length; i++) {
            final s = suggestions[i];
            // Un créneau déjà rempli n'est pas écrasé : il a été envoyé au
            // modèle comme « déjà assigné », le remplacer contredirait la
            // consigne et effacerait un choix manuel.
            if (_slots[i] != null) continue;
            if (s.recipe != null) {
              _slots[i] = s.recipe;
              _slotJustifications[i] = _buildSlotWhy(
                s.justification,
                fallback:
                    'Sélection IA basée sur vos contraintes du jour et la variété du cycle.',
              );
              _slotWasResized[i] = s.wasResized;
              final resizeReason = (s.resizeReason ?? '').trim();
              if (resizeReason.isNotEmpty) {
                _slotResizeReasons[i] = resizeReason;
              } else {
                _slotResizeReasons.remove(i);
              }
              _slotPrepDates[i] = s.prepDate;
              // L'entrée et le dessert du même appel, quand le format du
              // créneau en demandait : le serveur ne les rend que dans ce cas.
              _slotStarters[i] = s.starter == null
                  ? null
                  : MealComponent.recipe(
                      s.starter!,
                      role: MealComponentRole.entree,
                      justification: 'Entrée proposée par l\'IA.',
                    );
              _slotDesserts[i] = s.dessert == null
                  ? null
                  : MealComponent.recipe(
                      s.dessert!,
                      role: MealComponentRole.dessert,
                      justification: 'Dessert proposé par l\'IA.',
                    );
            }
          }
          // Les plats sont posés : le programme choisit leurs accompagnements,
          // dans l'ordre des jours, sans en servir deux fois le même de suite.
          _recomputeSides();
        });
      }

      // « Conception IA (si aucun résultat) » : la case cochée doit servir,
      // sinon elle ment. Un créneau resté vide reçoit une recette inventée —
      // un appel par créneau, comme pour la génération d'un jour isolé.
      final stillEmpty = mayConceive
          ? [
              for (int i = 0; i < _slotDates.length; i++)
                if (_slots[i] == null) i,
            ]
          : const <int>[];
      for (final index in stillEmpty) {
        if (!mounted) break;
        await _conceiveForSlot(index);
      }

      if (mounted) {
        final filled = _slots.values.where((r) => r != null).length;
        if (filled == 0) {
          // Aucune suggestion : le dire, plutôt qu'annoncer un succès devant
          // un écran resté vide.
          _showError('L\'IA n\'a rien proposé pour ce cycle.');
        } else {
          // Les plats récents retirés du corpus sont dits : un plat qu'on ne
          // voit pas proposé doit pouvoir s'expliquer.
          final excluded = suggestion.excludedRecentCount;
          final suffix = excluded > 0
              ? ' · $excluded plat${excluded > 1 ? 's' : ''} récent'
                    '${excluded > 1 ? 's' : ''} écarté${excluded > 1 ? 's' : ''}'
              : '';
          context.showSuccessSnackBar('Planning généré par l\'IA ✓$suffix');
        }
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.generateWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur lors de la génération : $e');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
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
        _slotJustifications[slotIndex] =
            'Sélection manuelle : recette choisie par l\'utilisateur.';
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
  /// mis à jour parce que déjà enregistré depuis un créneau, et ce que le
  /// planning contient déjà d'autre sur la période.
  static String _validateDialogText({
    required int newCount,
    required int updatedCount,
    required int existingCount,
  }) {
    final ready = switch ((newCount, updatedCount)) {
      (_, 0) => '$newCount repas seront ajoutés à votre planning',
      (0, _) => 'Les $updatedCount repas déjà enregistrés seront mis à jour',
      _ =>
        '$newCount repas seront ajoutés à votre planning, et $updatedCount '
            'déjà enregistrés seront mis à jour',
    };
    if (existingCount == 0) return '$ready.';
    final others = updatedCount > 0 ? 'autres repas' : 'repas';
    return '$ready. Votre planning contient déjà $existingCount $others sur '
        'cette période : voulez-vous les remplacer, ou ajouter les nouveaux '
        'à côté ?';
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
      // Ce qui accompagne le plat suit le repas, dans l'ordre du repas :
      // l'entrée et le dessert seulement si le format du créneau en
      // demande, l'accompagnement — garniture figée ou recette — toujours.
      components: [
        if (slotConstraint.effectiveFormat.wantsStarter) ?_slotStarters[i],
        ?_slotSides[i],
        if (slotConstraint.effectiveFormat.wantsDessert) ?_slotDesserts[i],
      ],
      createdAt: DateTime.now(),
    );
  }

  Future<void> _validate() async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;

    final mealsToAdd = <PlannedMeal>[
      for (int i = 0; i < _slotDates.length; i++)
        ?_plannedMealForSlot(i, uid: repo.uid),
    ];

    if (mealsToAdd.isEmpty) {
      _showError('Aucun repas assigné à valider.');
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
      );
      existing = [
        for (final meal in between)
          if (!ownIds.contains(meal.id)) meal,
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
            existingCount: existing.length,
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
        await ref.read(storageRepositoryProvider).ensure(recipeId: id);
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
    setState(() {
      // Rechercher le premier trou dans la séquence de dates
      int? gapIdx;
      DateTime? gapDate;
      for (int i = 1; i < _slotDates.length; i++) {
        final expected = _slotDates[i - 1].add(const Duration(days: 1));
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
        final newDate = _slotDates.last.add(const Duration(days: 1));
        _slotDates = [..._slotDates, newDate];
        _slots[_slotDates.length - 1] = null;
        _slotTimes[_slotDates.length - 1] = _timeFor(newDate);
        _slotConstraints[_slotDates.length - 1] =
            _prefs?.dailyConstraints[newDate.weekday] ?? const DayConstraint();
      }
    });
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
  void _dismissSlotRecipe(int slotIndex) {
    final current = _slots[slotIndex];
    if (current == null || current.id.isEmpty) return;
    (_slotDismissed[slotIndex] ??= {}).add(current.id);
  }

  /// Génère une suggestion IA pour un slot individuel.
  /// Affiche d'abord une sheet pour sélectionner les sources.
  Future<void> _generateSlotWithAI(int slotIndex) async {
    // Sélection des sources
    final books = _booksInPool();
    final scope = await showModalBottomSheet<RecipeSearchScope>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => RecipeSourceSheet(
        initialSources: _selectedSources,
        initialBookIds: _selectedBookIds ?? books.map((b) => b.id).toSet(),
        availableBooks: books,
      ),
    );
    if (scope == null || scope.sources.isEmpty || !mounted) return;
    final sources = scope.sources;
    _selectedSources = sources;
    _selectedBookIds = scope.bookIds;
    unawaited(_persistSearchScope(scope));

    // Construire le pool de recettes selon les sources et les livres choisis
    final pool = <Recipe>[
      if (sources.contains(RecipeSource.myRecipes))
        ..._availableRecipes.where(scope.matchesBook),
      if (sources.contains(RecipeSource.myDrafts))
        ..._draftRecipes.where(scope.matchesBook),
      if (sources.contains(RecipeSource.familyRecipes))
        ..._familyRecipes.where(scope.matchesBook),
    ];

    if (pool.isEmpty && !sources.contains(RecipeSource.aiCreation)) {
      _showError('Aucune recette disponible dans les sources sélectionnées.');
      return;
    }

    // Demander une autre suggestion, c'est écarter celle en place : elle ne
    // revient pas, ni maintenant ni au prochain essai sur ce créneau.
    _dismissSlotRecipe(slotIndex);
    final candidates = candidatesForMeal(
      pool,
      dismissedRecipeIds: _slotDismissed[slotIndex] ?? const {},
    );
    if (pool.isNotEmpty &&
        candidates.isEmpty &&
        !sources.contains(RecipeSource.aiCreation)) {
      _showError(
        'Toutes les recettes des sources choisies ont déjà été écartées pour ce créneau.',
      );
      return;
    }

    setState(() => _generatingSlot = slotIndex);
    try {
      final prefs = _prefs ?? const PlanningPreferences();
      final slotConstraint =
          _slotConstraints[slotIndex] ?? const DayConstraint();
      final alreadyAssigned = [
        for (final e in _slots.entries)
          if (e.value != null && e.value!.id.isNotEmpty)
            (slot: e.key, recipeId: e.value!.id),
      ];

      SlotSuggestion? suggestion;

      if (candidates.isNotEmpty) {
        final recentlyServed = await _loadRecentlyServed();
        final result = await ref
            .read(planningAiServiceProvider)
            .suggestMealPlan(
              recipes: candidates,
              slotDates: [_slotDates[slotIndex]],
              dailyConstraints: {_slotDates[slotIndex].weekday: slotConstraint},
              slotConstraints: [slotConstraint.isEmpty ? null : slotConstraint],
              globalConstraints: _globalConstraintsCtrl.text.trim(),
              batchCookingDay: prefs.batchCookingDay,
              alreadyAssigned: alreadyAssigned,
              recentlyServed: recentlyServed,
            );
        final suggestions = result.slots;
        if (suggestions.isNotEmpty && suggestions[0].recipe != null) {
          suggestion = suggestions[0];
        }
      }

      // Fallback : conception IA si aucun résultat et source cochée. Le
      // travail est le même que celui du bouton global sur un créneau resté
      // vide — il vit donc à un seul endroit.
      if (suggestion == null) {
        if (sources.contains(RecipeSource.aiCreation)) {
          await _conceiveForSlot(slotIndex);
        } else if (mounted) {
          _showError('L\'IA n\'a rien proposé pour ce créneau.');
        }
        return;
      }

      if (!mounted) return;
      _applySuggestionToSlot(slotIndex, suggestion);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.generateSlotWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur IA : $e');
    } finally {
      if (mounted) setState(() => _generatingSlot = null);
    }
  }

  /// Fait inventer une recette pour un créneau resté vide.
  ///
  /// C'est ce que promet la case « Conception IA (si aucun résultat) ».
  /// Appelée par la génération d'un créneau isolé comme par celle du cycle
  /// entier : la promesse est la même, le travail aussi.
  ///
  /// Un appel de modèle par créneau — c'est le prix d'une recette qui n'existe
  /// pas encore, et il n'est payé que pour les créneaux que rien n'a pu
  /// remplir.
  Future<void> _conceiveForSlot(int slotIndex) async {
    final slotConstraint = _slotConstraints[slotIndex] ?? const DayConstraint();
    // Ce que le cycle contient déjà, y compris ce qui vient d'être conçu au
    // créneau précédent. Une contrainte de variété porte sur l'ENSEMBLE : sans
    // cette liste, sept conceptions indépendantes rendent sept fois le même
    // réflexe, et « je veux de la variété » se solde par six poulets.
    final alreadyPlanned = [
      for (int i = 0; i < _slotDates.length; i++)
        if (i != slotIndex && _slots[i] != null) _slots[i]!.titre,
    ];
    try {
      final suggestion = await ref
          .read(planningAiServiceProvider)
          .generateRecipeConcept(
            slotDate: _slotDates[slotIndex],
            globalConstraints: _globalConstraintsCtrl.text.trim(),
            dayConstraint: slotConstraint.isEmpty ? null : slotConstraint,
            alreadyPlanned: alreadyPlanned,
          );

      if (!mounted) return;
      if (suggestion.recipe == null) {
        // Conception revenue vide : ne pas effacer le créneau en silence.
        _showError(
          suggestion.justification ??
              'L\'IA n\'a rien proposé pour ce créneau.',
        );
        return;
      }
      await _applySuggestionToSlot(slotIndex, suggestion);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.conceiveForSlot',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur IA : $e');
    }
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
      _constraintsLocked = true;
      _slots[slotIndex] = finalRecipe;
      _slotIsGenerated[slotIndex] = suggestion.isGenerated;
      _slotJustifications[slotIndex] = _buildSlotWhy(
        suggestion.justification,
        fallback: suggestion.isGenerated
            ? 'Recette créée par l\'IA pour ce créneau.'
            : 'Sélection IA basée sur vos contraintes du jour et la variété du cycle.',
      );
      _slotWasResized[slotIndex] = suggestion.wasResized;
      final resizeReason = (suggestion.resizeReason ?? '').trim();
      if (resizeReason.isNotEmpty) {
        _slotResizeReasons[slotIndex] = resizeReason;
      } else {
        _slotResizeReasons.remove(slotIndex);
      }
      _slotPrepDates[slotIndex] = suggestion.prepDate;
      _slotSideManual.remove(slotIndex);
      _recomputeSides(only: {slotIndex});
      // L'entrée et le dessert rendus avec le plat, quand le format en
      // demandait ; un créneau régénéré sans eux garde ceux qu'il avait.
      if (suggestion.starter != null) {
        _slotStarters[slotIndex] = MealComponent.recipe(
          suggestion.starter!,
          role: MealComponentRole.entree,
          justification: 'Entrée proposée par l\'IA.',
        );
      }
      if (suggestion.dessert != null) {
        _slotDesserts[slotIndex] = MealComponent.recipe(
          suggestion.dessert!,
          role: MealComponentRole.dessert,
          justification: 'Dessert proposé par l\'IA.',
        );
      }
    });
  }

  /// Produit le conseil de conservation d'un créneau.
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
      final advice = await ref
          .read(storageRepositoryProvider)
          .ensure(recipeId: recipe.id);
      if (!mounted) return;
      setState(() => _storageAdviceByRecipe[recipe.id] = advice);
      context.showSuccessSnackBar('Conservation de « ${recipe.titre} » ✓');
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
      final meals = await repo.getMealsBetween(
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
      _slotSides[index] = result.candidate?.toComponent(
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

  String _buildSlotWhy(String? raw, {required String fallback}) {
    final value = (raw ?? '').trim();
    return value.isNotEmpty ? value : fallback;
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

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(planningPreferencesOnceProvider);

    return prefsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Nouveau planning')),
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
    final theme = Theme.of(context);
    final assignedCount = _slots.values.where((r) => r != null).length;
    final totalSlots = _slotDates.length;
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nouveau planning'),
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
          // Sur grand écran, la même action vit en bas, sous forme de bouton
          // nommé, au-dessus de « Valider ». Une icône seule dans un coin
          // n'apprend pas ce qu'elle fait, et c'est pourtant l'action
          // principale de l'écran : sans elle, il n'y a rien à valider.
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
      body: Column(
        children: [
          // En-tête avec infos du cycle
          Container(
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
                  child: Text(
                    _slotDates.isEmpty
                        ? 'Chargement…'
                        : 'Cycle du ${DateFormat('d MMM', 'fr').format(_slotDates.first)}'
                              ' au ${DateFormat('d MMM', 'fr').format(_slotDates.last)}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  '$assignedCount / $totalSlots repas assignés',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: StylusPadTextField(
              controller: _globalConstraintsCtrl,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Contrainte locale du cycle',
                hintText:
                    'Ex: pas de dessert, varier protéines, utiliser les restes',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          // Liste des slots
          Expanded(
            child: _slotDates.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount:
                        _slotDates.length + 1, // +1 pour "Ajouter un jour"
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      if (index == _slotDates.length) {
                        return ListTile(
                          leading: const Icon(Icons.add_circle_outline),
                          title: const Text('Ajouter un jour'),
                          onTap: _addDay,
                        );
                      }
                      return BatchSlotTile(
                        index: index,
                        date: _slotDates[index],
                        recipe: _slots[index],
                        savedToPlanning: _slotSavedMealIds.containsKey(index),
                        constraintsReadOnly: _constraintsLocked,
                        isBatchDay:
                            effectivePrefs.batchCookingDay ==
                            _slotDates[index].weekday,
                        dayConstraint:
                            _slotConstraints[index] ?? const DayConstraint(),
                        slotTime: _slotTimes[index] ?? _defaultTime,
                        isGenerating: _generatingSlot == index,
                        justification: _slotJustifications[index],
                        prepDate: _slotPrepDates[index],
                        wasResized: _slotWasResized[index] ?? false,
                        resizeReason: _slotResizeReasons[index],
                        isGeneratedByAI: _slotIsGenerated[index] ?? false,
                        storageAdvice: _storageAdviceFor(index),
                        storageLoading: _storageLoadingSlots.contains(index),
                        // Offert dès qu'une recette est posée : la conservation
                        // se demande aussi pour un plat qu'on décide de garder
                        // après coup, et l'exiger d'un créneau « réchauffage »
                        // rendait la fonction introuvable sans jour de batch
                        // cooking configuré.
                        onGenerateStorageAdvice:
                            (_slots[index]?.id.isNotEmpty ?? false)
                            ? () => _generateStorageAdvice(index)
                            : null,
                        onAssign: () => _pickRecipeForSlot(index),
                        onRemove: () => setState(() {
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
                        }),
                        onDelete: () => _removeDay(index),
                        onTimeChanged: (t) =>
                            setState(() => _slotTimes[index] = t),
                        onMaxPrepChanged: (maxPrep) => setState(() {
                          final current =
                              _slotConstraints[index] ?? const DayConstraint();
                          _slotConstraints[index] = current.copyWith(
                            maxPrepMinutes: maxPrep,
                          );
                        }),
                        onTargetPortionsChanged: (targetPortions) =>
                            setState(() {
                              final current =
                                  _slotConstraints[index] ??
                                  const DayConstraint();
                              _slotConstraints[index] = current.copyWith(
                                targetPortions: targetPortions,
                              );
                            }),
                        onReheatChanged: (isReheat) => setState(() {
                          final current =
                              _slotConstraints[index] ?? const DayConstraint();
                          _slotConstraints[index] = current.copyWith(
                            isBatchCooking: isReheat,
                          );
                        }),
                        onNotesChanged: (notes) => setState(() {
                          final current =
                              _slotConstraints[index] ?? const DayConstraint();
                          _slotConstraints[index] = current.copyWith(
                            notes: notes,
                          );
                        }),
                        onGenerateWithAI: _recipesLoaded
                            ? () => _generateSlotWithAI(index)
                            : null,
                        onExportToCalendar: _slots[index] != null
                            ? () => _exportSlotToCalendar(index)
                            : null,
                        onRecipeTap: _slots[index] != null
                            ? () => _onRecipeTap(_slots[index]!, index)
                            : null,
                        side: _slotSides[index],
                        onChangeSide: _slots[index] != null
                            ? () => _changeSide(index)
                            : null,
                        onRemoveSide: _slotSides[index] != null
                            ? () => _removeSide(index)
                            : null,
                        starter: _slotStarters[index],
                        dessert: _slotDesserts[index],
                        onChangeStarter: _slots[index] != null
                            ? () =>
                                  _changeCourse(index, MealComponentRole.entree)
                            : null,
                        onRemoveStarter: _slotStarters[index] != null
                            ? () =>
                                  _removeCourse(index, MealComponentRole.entree)
                            : null,
                        onChangeDessert: _slots[index] != null
                            ? () => _changeCourse(
                                index,
                                MealComponentRole.dessert,
                              )
                            : null,
                        onRemoveDessert: _slotDesserts[index] != null
                            ? () => _removeCourse(
                                index,
                                MealComponentRole.dessert,
                              )
                            : null,
                        // Le plat seul est le défaut : le choisir remet le
                        // créneau à « pas réglé », il n'est jamais stocké.
                        onFormatChanged: (f) => setState(() {
                          final current =
                              _slotConstraints[index] ?? const DayConstraint();
                          _slotConstraints[index] =
                              f == MealFormat.defaultFormat
                              ? current.copyWith(clearMealFormat: true)
                              : current.copyWith(mealFormat: f);
                        }),
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            // Les deux boutons occupent la largeur, comme « Valider » le
            // faisait seul : une colonne les aurait sinon rétrécis au contenu.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWide) ...[
                PlanWithAiButton(
                  generating: _generating,
                  enabled: _recipesLoaded,
                  emptySlots: totalSlots - assignedCount,
                  itemBuilder: _aiMenuItems,
                  onSelected: (value) =>
                      _generateWithAI(replaceExisting: value == 1),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                onPressed: (assignedCount == 0 || _saving) ? null : _validate,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check_circle_outline),
                label: Text('Valider le planning ($assignedCount repas)'),
              ),
            ],
          ),
        ),
      ),
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
        title: Text('Tout regénérer'),
        // Dire « les créneaux de cet écran » et non « les choix » : rien n'est
        // touché dans le planning déjà enregistré, et le laisser entendre
        // serait un contresens.
        subtitle: Text('Vide les créneaux de cet écran'),
        contentPadding: EdgeInsets.zero,
      ),
    ),
  ];
}
