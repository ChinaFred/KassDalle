import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../../groups/presentation/group_providers.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import '../services/planning_ai_service.dart';
import 'batch_planning_widgets.dart';
import 'planning_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/router/app_router.dart';

/// Ã‰cran de génération de planning en masse (Axe B).
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
    } catch (e) {
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

  Future<void> _generateWithAI() async {
    if (_availableRecipes.isEmpty) {
      _showError('Aucune recette validée disponible pour la génération.');
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
            globalConstraints: _globalConstraintsCtrl.text.trim(),
            batchCookingDay: prefs.batchCookingDay,
            alreadyAssigned: alreadyAssigned,
          );
      if (mounted) {
        setState(() {
          for (int i = 0; i < suggestions.length; i++) {
            final s = suggestions[i];
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
    } catch (e) {
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
      builder: (ctx) => BatchRecipePickerSheet(recipes: _availableRecipes),
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
          createdAt: DateTime.now(),
        ),
      );
    }

    if (mealsToAdd.isEmpty) {
      _showError('Aucun repas assigné à valider.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Valider le planning ?'),
        content: Text(
          '${mealsToAdd.length} repas seront ajoutés à votre planning.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _saving = true);
    try {
      await repo.addMeals(mealsToAdd);
      if (mounted) {
        context.showSuccessSnackBar(
          '${mealsToAdd.length} repas planifiés avec succès !',
        );
        context.pop();
      }
    } catch (e) {
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
          } catch (_) {
            // Sauvegarde échouée : on utilise quand même la recette sans id
          }
        }
      }

      setState(() {
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
    } catch (e) {
      _showError('Erreur IA : $e');
    } finally {
      if (mounted) setState(() => _generatingSlot = null);
    }
  }

  /// Navigation vers la recette (detail ou draft).
  void _onRecipeTap(Recipe recipe) {
    if (recipe.id.isEmpty) return;
    if (recipe.reviewStatus == ReviewStatus.validated) {
      context.push('${AppRoutes.recipes}/${recipe.id}');
    } else {
      context.push('${AppRoutes.drafts}/${recipe.id}');
    }
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
    final dur = (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
    try {
      await CalendarService.createEvent(
        titre: recipe.titre,
        startTime: startTime,
        duration: Duration(minutes: dur > 0 ? dur : 30),
        description: 'Repas planifié avec Kass\'Dalle',
        reminderMinutes: 30,
      );
      if (mounted) {
        context.showSuccessSnackBar(
          '« ${recipe.titre} » ajouté au calendrier ✓',
        );
      }
    } catch (e) {
      _showError('Erreur Calendar : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(planningPreferencesProvider);

    return prefsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Nouveau planning')),
        body: Center(child: Text('Erreur : $e')),
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
          if (_generating)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.auto_fix_high),
              tooltip: 'Suggérer avec l\'IA',
              onPressed: _recipesLoaded ? _generateWithAI : null,
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
                        ? 'Chargementâ€¦'
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
                            ? () => _onRecipeTap(_slots[index]!)
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
