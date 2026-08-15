import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/storage_advice.dart';
import '../../groups/presentation/group_providers.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import '../services/planning_ai_service.dart';
import 'batch_planning_widgets.dart';
import 'planning_providers.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';

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
  // Sources sélectionnées (persistées pendant la session)
  Set<RecipeSource> _selectedSources = {RecipeSource.myRecipes};
  // Marque les slots générés par IA (conception)
  Map<int, bool> _slotIsGenerated = {};
  Map<int, DayConstraint> _slotConstraints = {};
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
    final defaultTime = TimeOfDay(
      hour: prefs.defaultMealHour,
      minute: prefs.defaultMealMinute,
    );
    _slotDates = dates;
    _slots = {for (int i = 0; i < dates.length; i++) i: null};
    _slotTimes = {for (int i = 0; i < dates.length; i++) i: defaultTime};
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

  /// Génère un planning. [replaceExisting] efface d'abord les créneaux remplis ;
  /// sinon les choix déjà faits (manuels ou IA) sont conservés.
  Future<void> _generateWithAI({bool replaceExisting = false}) async {
    if (_availableRecipes.isEmpty) {
      _showError('Aucune recette validée disponible pour la génération.');
      return;
    }
    if (replaceExisting) {
      setState(() {
        _slots = {for (int i = 0; i < _slotDates.length; i++) i: null};
        _slotJustifications.clear();
        _slotPrepDates.clear();
        _slotWasResized.clear();
        _slotResizeReasons.clear();
        _slotIsGenerated.clear();
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
      final suggestions = await ref
          .read(planningAiServiceProvider)
          .suggestMealPlan(
            recipes: _availableRecipes,
            slotDates: _slotDates,
            dailyConstraints: dailyConstraints,
            slotConstraints: _slotConstraintsForAI(),
            globalConstraints: _globalConstraintsCtrl.text.trim(),
            batchCookingDay: prefs.batchCookingDay,
            alreadyAssigned: alreadyAssigned,
          );
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
            }
          }
        });
        context.showSuccessSnackBar('Planning généré par l\'IA ✓');
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
      builder: (ctx) => BatchRecipePickerSheet(recipes: _allRecipes),
    );
    if (recipe != null && mounted) {
      setState(() {
        _slots[slotIndex] = recipe;
        _slotJustifications[slotIndex] =
            'Sélection manuelle : recette choisie par l\'utilisateur.';
        _slotWasResized[slotIndex] = false;
        _slotResizeReasons.remove(slotIndex);
        _slotPrepDates.remove(slotIndex);
        _slotIsGenerated.remove(slotIndex);
      });
    }
  }

  Future<void> _validate() async {
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;

    final mealsToAdd = <PlannedMeal>[];
    final myUid = repo.uid;
    for (int i = 0; i < _slotDates.length; i++) {
      final recipe = _slots[i];
      if (recipe == null) continue;
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
      final duration =
          (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
      mealsToAdd.add(
        PlannedMeal(
          id: '',
          uid: myUid,
          recipeId: recipe.id.isEmpty ? null : recipe.id,
          recipeTitre: recipe.titre,
          plannedAt: plannedAt,
          durationMinutes: duration > 0 ? duration : 30,
          prepMinutes: recipe.tags.prepTime,
          cookMinutes: recipe.tags.cookTime,
          basePortions: recipe.portions,
          targetPortions: targetPortions,
          prepDate: _slotPrepDates[i],
          createdAt: DateTime.now(),
        ),
      );
    }

    if (mealsToAdd.isEmpty) {
      _showError('Aucun repas assigné à valider.');
      return;
    }

    // Ce que le cycle recouvre déjà : enregistrer sans le savoir empilait deux
    // repas sur le même créneau, et le planning affichait les deux.
    List<PlannedMeal> existing;
    try {
      existing = await repo.getMealsBetween(
        from: _slotDates.first,
        to: _slotDates.last,
      );
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
          existing.isEmpty
              ? '${mealsToAdd.length} repas seront ajoutés à votre planning.'
              : '${mealsToAdd.length} repas sont prêts. Votre planning contient '
                    'déjà ${existing.length} repas sur cette période : voulez-vous '
                    'les remplacer, ou ajouter les nouveaux à côté ?',
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
      await repo.addMeals(mealsToAdd);
      if (mounted) {
        final replaced = choice == _ValidateChoice.replace
            ? ' (${existing.length} remplacés)'
            : '';
        context.showSuccessSnackBar(
          '${mealsToAdd.length} repas planifiés$replaced ✓',
        );
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
          } else if (i == gapIdx) {
            newSlots[i] = null;
            newTimes[i] = _defaultTime;
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
      } else {
        // Pas de trou : étendre d'un jour après le dernier
        final newDate = _slotDates.last.add(const Duration(days: 1));
        _slotDates = [..._slotDates, newDate];
        _slots[_slotDates.length - 1] = null;
        _slotTimes[_slotDates.length - 1] = _defaultTime;
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
    });
  }

  /// Génère une suggestion IA pour un slot individuel.
  /// Affiche d'abord une sheet pour sélectionner les sources.
  Future<void> _generateSlotWithAI(int slotIndex) async {
    // Sélection des sources
    final sources = await showModalBottomSheet<Set<RecipeSource>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => RecipeSourceSheet(initialSources: _selectedSources),
    );
    if (sources == null || sources.isEmpty || !mounted) return;
    _selectedSources = sources;

    // Construire le pool de recettes selon les sources
    final pool = <Recipe>[
      if (sources.contains(RecipeSource.myRecipes)) ..._availableRecipes,
      if (sources.contains(RecipeSource.myDrafts)) ..._draftRecipes,
      if (sources.contains(RecipeSource.familyRecipes)) ..._familyRecipes,
    ];

    if (pool.isEmpty && !sources.contains(RecipeSource.aiCreation)) {
      _showError('Aucune recette disponible dans les sources sélectionnées.');
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

      if (pool.isNotEmpty) {
        final suggestions = await ref
            .read(planningAiServiceProvider)
            .suggestMealPlan(
              recipes: pool,
              slotDates: [_slotDates[slotIndex]],
              dailyConstraints: {_slotDates[slotIndex].weekday: slotConstraint},
              slotConstraints: [slotConstraint.isEmpty ? null : slotConstraint],
              globalConstraints: _globalConstraintsCtrl.text.trim(),
              batchCookingDay: prefs.batchCookingDay,
              alreadyAssigned: alreadyAssigned,
            );
        if (suggestions.isNotEmpty && suggestions[0].recipe != null) {
          suggestion = suggestions[0];
        }
      }

      // Fallback : conception IA si aucun résultat et source cochée
      if (suggestion == null && sources.contains(RecipeSource.aiCreation)) {
        suggestion = await ref
            .read(planningAiServiceProvider)
            .generateRecipeConcept(
              slotDate: _slotDates[slotIndex],
              globalConstraints: _globalConstraintsCtrl.text.trim(),
              dayConstraint: slotConstraint.isEmpty ? null : slotConstraint,
            );
      }

      if (!mounted || suggestion == null) return;
      if (suggestion.recipe == null) {
        // Conception IA revenue vide : ne pas effacer le créneau en silence.
        _showError(
          suggestion.justification ??
              'L\'IA n\'a rien proposé pour ce créneau.',
        );
        return;
      }

      // Si la recette est générée par IA, la sauvegarder en brouillon
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
              feature: 'batchPlanningScreen.generateSlotWithAI',
              error: error,
              stackTrace: stackTrace,
            );
            // Sauvegarde échouée : on utilise quand même la recette sans id
          }
        }
      }

      setState(() {
        _constraintsLocked = true;
        _slots[slotIndex] = finalRecipe;
        _slotIsGenerated[slotIndex] = suggestion!.isGenerated;
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
      });
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

  /// Produit le conseil de conservation d'un créneau et l'écrit en fin de
  /// recette, sous sa section dédiée.
  ///
  /// Le conseil appartient au plat, pas au repas : une fois produit, tous les
  /// créneaux portant cette recette l'affichent sans repayer d'appel.
  Future<void> _generateStorageAdvice(int slotIndex) async {
    final recipe = _slots[slotIndex];
    if (recipe == null || recipe.id.isEmpty) {
      _showError('Assignez d\'abord une recette à ce créneau.');
      return;
    }
    setState(() => _storageLoadingSlots.add(slotIndex));
    try {
      final repo = ref.read(storageRepositoryProvider);
      // Un conseil déjà produit ne se repaie pas : il décrit le plat, et vaut
      // pour toutes ses planifications.
      final advice =
          await repo.read(recipe.id) ??
          await repo.generate(recipeId: recipe.id);
      if (!mounted) return;
      setState(() => _storageAdviceByRecipe[recipe.id] = advice);

      // L'écriture de la section est tentée à part : sur une recette de la
      // famille, un lecteur n'a pas le droit d'écrire. Le conseil, lui, est
      // déjà produit et stocké — le perdre pour cette raison serait absurde.
      String? updated;
      try {
        updated = await repo.applyToRecipe(
          recipeId: recipe.id,
          rawCooklang: recipe.rawCooklang,
          advice: advice,
        );
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'batchPlanningScreen.applyStorageAdvice',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!mounted) return;
      if (updated != null) {
        setState(() {
          // Garder le CookLang local à jour : une seconde intégration doit
          // remplacer la section, pas l'empiler.
          final refreshed = recipe.copyWith(rawCooklang: updated);
          for (final entry in _slots.entries.toList()) {
            if (entry.value?.id == recipe.id) _slots[entry.key] = refreshed;
          }
        });
        context.showSuccessSnackBar(
          'Conservation ajoutée à « ${recipe.titre} » ✓',
        );
      } else {
        context.showSnackBar(
          'Conseil de conservation disponible, mais la recette n\'a pas pu '
          'être modifiée.',
        );
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

  void _showError(String msg) {
    if (!mounted) return;
    context.showErrorSnackBar(msg);
  }

  String _buildSlotWhy(String? raw, {required String fallback}) {
    final value = (raw ?? '').trim();
    return value.isNotEmpty ? value : fallback;
  }

  /// Exporte le repas du slot [index] vers Google Calendar.
  Future<void> _exportSlotToCalendar(int index) async {
    final recipe = _slots[index];
    if (recipe == null) return;
    final date = _slotDates[index];
    final time = _slotTimes[index] ?? _defaultTime;
    final startTime = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    final prefs = _prefs ?? const PlanningPreferences();
    final dur = (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
    try {
      await CalendarService.createEvent(
        titre: recipe.titre,
        startTime: startTime,
        duration: Duration(
          minutes: dur > 0 ? dur : prefs.defaultCalendarDurationMinutes,
        ),
        description: 'Repas planifié avec Kass\'Dalle',
        reminderMinutes: recipe.tags.prepTime ?? 30,
        calendarId: prefs.calendarId,
      );
      if (mounted) {
        context.showSuccessSnackBar(
          '« ${recipe.titre} » ajouté au calendrier ✓',
        );
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'batchPlanningScreen.exportSlotToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      _showError('Erreur Calendar : $e');
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
              icon: const Icon(Icons.auto_fix_high),
              tooltip: 'Suggérer avec l\'IA',
              enabled: _recipesLoaded,
              onSelected: (value) =>
                  _generateWithAI(replaceExisting: value == 1),
              itemBuilder: (_) => const [
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
                    leading: Icon(Icons.refresh_outlined),
                    title: Text('Tout regénérer'),
                    // Dire « les créneaux de cet écran » et non « les choix » :
                    // rien n'est touché dans le planning déjà enregistré, et
                    // le laisser entendre serait un contresens.
                    subtitle: Text('Vide les créneaux de cet écran'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
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
                  size: 18,
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
            child: TextField(
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
                      );
                    },
                  ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
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
        ),
      ),
    );
  }
}
