import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import '../services/planning_ai_service.dart';
import 'batch_planning_widgets.dart';
import 'planning_providers.dart';

const _geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

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
  bool _generating = false;
  bool _saving = false;
  List<Recipe> _availableRecipes = [];
  bool _recipesLoaded = false;
  PlanningPreferences? _prefs;
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

  Future<void> _init() async {
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
  }

  Future<void> _generateWithAI() async {
    if (_geminiApiKey.isEmpty) {
      _showError('Clé Gemini non configurée.');
      return;
    }
    if (_availableRecipes.isEmpty) {
      _showError('Aucune recette validée disponible pour la génération.');
      return;
    }
    setState(() => _generating = true);
    try {
      final prefs = _prefs ?? const PlanningPreferences();
      final suggestions = await PlanningAiService.suggestMealPlan(
        apiKey: _geminiApiKey,
        recipes: _availableRecipes,
        slotDates: _slotDates,
        dailyConstraints: prefs.dailyConstraints,
        globalConstraints: prefs.globalConstraints,
      );
      if (mounted) {
        setState(() {
          for (int i = 0; i < suggestions.length; i++) {
            if (suggestions[i] != null) _slots[i] = suggestions[i];
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Planning généré par l\'IA ✓')),
        );
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
      setState(() => _slots[slotIndex] = recipe);
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${mealsToAdd.length} repas planifiés avec succès !'),
          ),
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
        for (int i = 0; i < newDates.length; i++) {
          if (i < gapIdx) {
            newSlots[i] = _slots[i];
            newTimes[i] = _slotTimes[i] ?? _defaultTime;
          } else if (i == gapIdx) {
            newSlots[i] = null;
            newTimes[i] = _defaultTime;
          } else {
            newSlots[i] = _slots[i - 1];
            newTimes[i] = _slotTimes[i - 1] ?? _defaultTime;
          }
        }
        _slotDates = newDates;
        _slots = newSlots;
        _slotTimes = newTimes;
      } else {
        // Pas de trou : étendre d'un jour après le dernier
        final newDate = _slotDates.last.add(const Duration(days: 1));
        _slotDates = [..._slotDates, newDate];
        _slots[_slotDates.length - 1] = null;
        _slotTimes[_slotDates.length - 1] = _defaultTime;
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
      for (int i = 0; i < newDates.length; i++) {
        newSlots[i] = i < index ? _slots[i] : _slots[i + 1];
        newTimes[i] = i < index
            ? (_slotTimes[i] ?? _defaultTime)
            : (_slotTimes[i + 1] ?? _defaultTime);
      }
      _slotDates = newDates;
      _slots = newSlots;
      _slotTimes = newTimes;
    });
  }

  /// Génère une suggestion IA pour un slot individuel.
  Future<void> _generateSlotWithAI(int slotIndex) async {
    if (_geminiApiKey.isEmpty) {
      _showError('Clé Gemini non configurée.');
      return;
    }
    if (_availableRecipes.isEmpty) {
      _showError('Aucune recette validée disponible.');
      return;
    }
    setState(() => _generatingSlot = slotIndex);
    try {
      final prefs = _prefs ?? const PlanningPreferences();
      final suggestions = await PlanningAiService.suggestMealPlan(
        apiKey: _geminiApiKey,
        recipes: _availableRecipes,
        slotDates: [_slotDates[slotIndex]],
        dailyConstraints: prefs.dailyConstraints,
        globalConstraints: prefs.globalConstraints,
      );
      if (mounted && suggestions.isNotEmpty && suggestions[0] != null) {
        setState(() => _slots[slotIndex] = suggestions[0]);
      }
    } catch (e) {
      _showError('Erreur IA : $e');
    } finally {
      if (mounted) setState(() => _generatingSlot = null);
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('« ${recipe.titre} » ajouté au calendrier ✓')),
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
              icon: const Icon(Icons.auto_awesome_outlined),
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
                        prefs: prefs,
                        slotTime: _slotTimes[index] ?? _defaultTime,
                        isGenerating: _generatingSlot == index,
                        onAssign: () => _pickRecipeForSlot(index),
                        onRemove: () => setState(() => _slots[index] = null),
                        onDelete: () => _removeDay(index),
                        onTimeChanged: (t) =>
                            setState(() => _slotTimes[index] = t),
                        onGenerateWithAI:
                            (_recipesLoaded && _geminiApiKey.isNotEmpty)
                            ? () => _generateSlotWithAI(index)
                            : null,
                        onExportToCalendar: _slots[index] != null
                            ? () => _exportSlotToCalendar(index)
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
