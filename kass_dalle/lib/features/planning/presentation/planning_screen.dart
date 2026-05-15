import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/planned_meal.dart';
import 'planning_providers.dart';

class PlanningScreen extends ConsumerStatefulWidget {
  const PlanningScreen({super.key});

  @override
  ConsumerState<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends ConsumerState<PlanningScreen> {
  List<Recipe> _availableRecipes = [];
  bool _recipesLoaded = false;

  Future<void> _loadRecipesIfNeeded() async {
    if (_recipesLoaded) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    final recipes = await repo.getValidatedRecipes();
    if (mounted) setState(() { _availableRecipes = recipes; _recipesLoaded = true; });
  }

  Future<void> _changeRecipe(BuildContext context, PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PlanningRecipePickerSheet(recipes: _availableRecipes),
    );
    if (recipe == null || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    final duration = (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
    await repo?.updateMealRecipe(
      meal.id,
      recipeId: recipe.id.isEmpty ? null : recipe.id,
      recipeTitre: recipe.titre,
      durationMinutes: duration,
    );
  }

  Future<void> _clearRecipe(PlannedMeal meal) async {
    final repo = ref.read(planningRepositoryProvider);
    await repo?.updateMealRecipe(
      meal.id,
      recipeId: null,
      recipeTitre: 'Repas libre',
      durationMinutes: 0,
    );
  }

  Future<void> _deleteMeal(BuildContext context, PlannedMeal meal) async {
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Planning des repas'),
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Paramètres du planning',
            onPressed: () => context.push('/planning/config'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/planning/batch'),
        icon: const Icon(Icons.auto_awesome_outlined),
        label: const Text('Nouveau planning'),
      ),
      body: mealsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
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
                  _DayHeader(
                    day: day,
                    isToday: isToday,
                    isPast: isPast,
                  ),
                  ...dayMeals.map(
                    (meal) => _MealTile(
                      meal: meal,
                      isPast: isPast,
                      onDelete: () => _deleteMeal(context, meal),
                      onChangeRecipe: () => _changeRecipe(context, meal),
                      onClearRecipe: () => _clearRecipe(meal),
                      onTap: meal.recipeId != null
                          ? () => context.push('/recipes/${meal.recipeId}')
                          : null,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  bool _isToday(DateTime day) {
    final now = DateTime.now();
    return day.year == now.year &&
        day.month == now.month &&
        day.day == now.day;
  }
}

// ── Widgets ────────────────────────────────────────────────────────────────────

class _DayHeader extends StatelessWidget {
  final DateTime day;
  final bool isToday;
  final bool isPast;

  const _DayHeader({
    required this.day,
    required this.isToday,
    required this.isPast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = isToday
        ? "Aujourd'hui"
        : DateFormat('EEEE d MMMM', 'fr').format(day);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: isToday
              ? theme.colorScheme.primary
              : isPast
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onSurface,
          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class _MealTile extends StatelessWidget {
  final PlannedMeal meal;
  final bool isPast;
  final VoidCallback? onTap;
  final VoidCallback onDelete;
  final VoidCallback onChangeRecipe;
  final VoidCallback onClearRecipe;

  const _MealTile({
    required this.meal,
    required this.isPast,
    required this.onDelete,
    required this.onChangeRecipe,
    required this.onClearRecipe,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = DateFormat('HH:mm').format(meal.plannedAt);
    final durationStr = meal.durationMinutes > 0
        ? '${meal.durationMinutes} min'
        : null;

    return Opacity(
      opacity: isPast ? 0.6 : 1.0,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: isPast
                ? theme.colorScheme.surfaceContainerHighest
                : theme.colorScheme.primaryContainer,
            child: Text(
              timeStr,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: isPast
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          title: Text(
            meal.recipeTitre,
            style: isPast
                ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          subtitle: durationStr != null ? Text(durationStr) : null,
          trailing: PopupMenuButton<_MealAction>(
            iconSize: 20,
            onSelected: (action) {
              switch (action) {
                case _MealAction.changeRecipe:
                  onChangeRecipe();
                case _MealAction.clearRecipe:
                  onClearRecipe();
                case _MealAction.delete:
                  onDelete();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _MealAction.changeRecipe,
                child: ListTile(
                  leading: Icon(Icons.swap_horiz_outlined),
                  title: Text('Changer la recette'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuItem(
                value: _MealAction.clearRecipe,
                child: ListTile(
                  leading: Icon(Icons.radio_button_unchecked_outlined),
                  title: Text('Remettre à blanc'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _MealAction.delete,
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Supprimer'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

enum _MealAction { changeRecipe, clearRecipe, delete }

// ── Recipe picker ─────────────────────────────────────────────────────────────

class _PlanningRecipePickerSheet extends StatefulWidget {
  final List<Recipe> recipes;

  const _PlanningRecipePickerSheet({required this.recipes});

  @override
  State<_PlanningRecipePickerSheet> createState() =>
      _PlanningRecipePickerSheetState();
}

class _PlanningRecipePickerSheetState
    extends State<_PlanningRecipePickerSheet> {
  String _query = '';

  List<Recipe> get _filtered {
    if (_query.isEmpty) return widget.recipes;
    final q = _query.toLowerCase();
    return widget.recipes
        .where((r) => r.titre.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Rechercher une recette…',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: _filtered.length + (_query.trim().isNotEmpty ? 1 : 0),
                itemBuilder: (_, i) {
                  if (_query.trim().isNotEmpty && i == 0) {
                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.edit_outlined, size: 18),
                      ),
                      title: Text('« ${_query.trim()} »'),
                      subtitle: const Text('Repas libre (sans recette liée)'),
                      onTap: () {
                        final freeRecipe = Recipe(
                          id: '',
                          titre: _query.trim(),
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
                        Navigator.pop(ctx, freeRecipe);
                      },
                    );
                  }
                  final ri = i - (_query.trim().isNotEmpty ? 1 : 0);
                  if (_filtered.isEmpty) return const SizedBox.shrink();
                  final r = _filtered[ri];
                  final prep = r.tags.prepTime;
                  final cook = r.tags.cookTime;
                  final times = [
                    if (prep != null) '${prep}min prép',
                    if (cook != null) '${cook}min cuisson',
                  ].join(' + ');
                  return ListTile(
                    title: Text(r.titre),
                    subtitle: times.isNotEmpty ? Text(times) : null,
                    onTap: () => Navigator.pop(ctx, r),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
