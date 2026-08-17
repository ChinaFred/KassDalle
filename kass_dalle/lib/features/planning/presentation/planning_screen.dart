import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/detail/shopping_list_sheet.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/meal_prep_context.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import 'planning_providers.dart';
import 'planning_widgets.dart';
import 'storage_advice_sheet.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';

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

  Future<void> _changeRecipe(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => PlanningRecipePickerSheet(recipes: _availableRecipes),
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
    );
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
          description: 'Repas planifié avec Kass\'Dalle',
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
        description: 'Repas planifié avec Kass\'Dalle',
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

  Future<void> _showIngredientsList(List<PlannedMeal> meals) async {
    final today = DateTime.now();
    // Les courses ne concernent que ce qui reste à cuisiner.
    final upcoming = meals
        .where(
          (m) => !m.plannedAt.isBefore(
            DateTime(today.year, today.month, today.day),
          ),
        )
        .toList();
    if (upcoming.isEmpty) {
      if (mounted) {
        context.showSnackBar('Aucun repas à venir dans le planning.');
      }
      return;
    }
    // Résoudre par identifiant : un repas peut pointer sur un brouillon ou une
    // recette de la famille, absente des recettes validées de l'utilisateur.
    final repo = ref.read(planningRepositoryProvider);
    final ids = upcoming.map((m) => m.recipeId).whereType<String>().toList();
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
    for (final meal in upcoming) {
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
    if (planningRecipes.isEmpty) {
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
    final aggregated = planningAggregateProducts(planningRecipes);
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
    );
  }

  Future<void> _suggestRecipeWithAI(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    if (_availableRecipes.isEmpty) {
      context.showSnackBar('Aucune recette disponible pour l\'IA.');
      return;
    }
    setState(() => _aiLoadingIds.add(meal.id));
    try {
      final prefs =
          ref.read(planningPreferencesProvider).value ??
          const PlanningPreferences();
      final suggestions = await ref
          .read(planningAiServiceProvider)
          .suggestMealPlan(
            recipes: _availableRecipes,
            slotDates: [meal.plannedAt],
            dailyConstraints: prefs.dailyConstraints,
            globalConstraints: prefs.globalConstraints,
            batchCookingDay: prefs.batchCookingDay,
          );
      if (!mounted) return;
      if (suggestions.isNotEmpty && suggestions[0].recipe != null) {
        final suggestion = suggestions[0];
        final recipe = suggestion.recipe!;
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
        );
        if (mounted) {
          final why = (suggestion.justification ?? '').trim();
          final resized = suggestion.wasResized
              ? ' · redimensionnée'
              : ' · non redimensionnée';
          final explain = why.isNotEmpty ? ' — $why' : '';
          context.showSnackBar(
            '\'${recipe.titre}\' suggéré par l\'IA$resized$explain ✓',
          );
        }
      } else if (mounted) {
        context.showSnackBar('L\'IA n\'a pas trouvé de suggestion.');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.suggestRecipeWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur IA : $e');
      }
    } finally {
      if (mounted) setState(() => _aiLoadingIds.remove(meal.id));
    }
  }

  /// Affiche le conseil de conservation d'un repas, en le produisant s'il
  /// manque.
  ///
  /// Un conseil déjà produit ne se repaie pas : il appartient au plat, pas au
  /// repas, et sert donc à toutes ses planifications.
  Future<void> _showStorageAdvice(PlannedMeal meal) async {
    final recipeId = meal.recipeId;
    if (recipeId == null || recipeId.isEmpty) return;
    setState(() => _storageLoadingIds.add(meal.id));
    try {
      final advice = await ref
          .read(storageRepositoryProvider)
          .ensure(recipeId: recipeId);
      if (!mounted) return;
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
    final theme = Theme.of(context);
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Planning des repas'),
        centerTitle: false,
        actions: [
          if (isWide) ...[
            if (mealsAsync.value?.isNotEmpty == true) ...[
              IconButton(
                icon: const Icon(Icons.shopping_cart_outlined),
                tooltip: 'Liste des ingrédients',
                onPressed: () => _showIngredientsList(mealsAsync.value!),
              ),
              IconButton(
                icon: const Icon(Icons.calendar_month_outlined),
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
                if (value == 1 && mealsAsync.value?.isNotEmpty == true) {
                  _showIngredientsList(mealsAsync.value!);
                }
                if (value == 2 && mealsAsync.value?.isNotEmpty == true) {
                  _exportAllToCalendar(mealsAsync.value!);
                }
              },
              itemBuilder: (_) => [
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
                      leading: Icon(Icons.calendar_month_outlined),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/planning/batch'),
        icon: const Icon(Icons.auto_awesome_outlined),
        label: const Text('Nouveau planning'),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshMeals,
        child: mealsAsync.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(error: e, onRetry: _refreshMeals),
          data: (meals) {
            if (meals.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 64,
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

            // Regrouper par date (sans heure)
            final grouped = <DateTime, List<PlannedMeal>>{};
            for (final meal in meals) {
              final day = DateTime(
                meal.plannedAt.year,
                meal.plannedAt.month,
                meal.plannedAt.day,
              );
              (grouped[day] ??= []).add(meal);
            }
            final days = grouped.keys.toList()..sort();

            return ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: days.length,
              itemBuilder: (context, index) {
                final day = days[index];
                final dayMeals = grouped[day]!;
                final isToday = _isToday(day);
                final isPast = day.isBefore(
                  DateTime(
                    DateTime.now().year,
                    DateTime.now().month,
                    DateTime.now().day,
                  ),
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PlanningDayHeader(
                      day: day,
                      isToday: isToday,
                      isPast: isPast,
                    ),
                    ...dayMeals.map(
                      (meal) => PlanningMealTile(
                        meal: meal,
                        isPast: isPast,
                        aiLoading:
                            _aiLoadingIds.contains(meal.id) ||
                            _storageLoadingIds.contains(meal.id),
                        isWide: isWide,
                        onDelete: () => _deleteMeal(meal),
                        onChangeRecipe: () => _changeRecipe(meal),
                        onClearRecipe: () => _clearRecipe(meal),
                        onSuggestWithAI: () => _suggestRecipeWithAI(meal),
                        onStorageAdvice: () => _showStorageAdvice(meal),
                        onTimeChanged: () => _changeTime(meal),
                        onExportToCalendar: () => _exportMealToCalendar(meal),
                        onTap: meal.recipeId != null
                            ? () => context.push(_recipeLocationFor(meal))
                            : null,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Recharge le planning : geste de rafraîchissement et bouton Réessayer.
  Future<void> _refreshMeals() async {
    ref.invalidate(plannedMealsProvider);
    await ref.read(plannedMealsProvider.future);
  }

  /// Adresse de la fiche recette pour un repas planifié.
  ///
  /// Le contexte du repas voyage en paramètre, sans jamais être écrit sur la
  /// recette : les parts, pour préparer la quantité prévue au planning et non
  /// celle du texte, et le couple de dates quand le plat se cuisine à l'avance,
  /// pour que la fiche parle de conservation et de réchauffage.
  String _recipeLocationFor(PlannedMeal meal) {
    final params = <String, String>{};

    final target = meal.targetPortions;
    final base = meal.basePortions;
    if (target != null && target > 0 && target != base) {
      params['portions'] = '$target';
    }

    final prepDate = meal.prepDate;
    if (prepDate != null) {
      params.addAll(
        MealPrepContext(
          prepDate: prepDate,
          mealDate: meal.plannedAt,
        ).toQueryParameters(),
      );
    }

    return Uri(
      path: '/recipes/${meal.recipeId}',
      queryParameters: params.isEmpty ? null : params,
    ).toString();
  }

  bool _isToday(DateTime day) {
    final now = DateTime.now();
    return day.year == now.year && day.month == now.month && day.day == now.day;
  }
}
