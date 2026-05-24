import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/planning_preferences.dart';

/// Sources disponibles pour la sélection de recettes dans la génération par slot.
enum RecipeSource {
  myRecipes,
  myDrafts,
  familyRecipes,
  aiCreation;

  String get label => switch (this) {
    RecipeSource.myRecipes => 'Mes recettes validées',
    RecipeSource.myDrafts => 'Mes brouillons',
    RecipeSource.familyRecipes => 'Recettes famille',
    RecipeSource.aiCreation => 'Conception IA (si aucun résultat)',
  };
}

/// Tuile représentant un slot de planning dans BatchPlanningScreen.
class BatchSlotTile extends StatelessWidget {
  final int index;
  final DateTime date;
  final Recipe? recipe;
  final PlanningPreferences prefs;
  final TimeOfDay slotTime;
  final bool isGenerating;

  /// Justification IA de la suggestion (critères respectés/enfreints).
  final String? justification;

  /// Jour de préparation à l'avance (calculé depuis le batch cooking day).
  final DateTime? prepDate;
  final bool isGeneratedByAI;
  final VoidCallback onAssign;
  final VoidCallback onRemove;
  final VoidCallback onDelete;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final VoidCallback? onGenerateWithAI;
  final VoidCallback? onExportToCalendar;
  /// Callback appelé quand l'utilisateur tape sur le titre de la recette.
  final VoidCallback? onRecipeTap;

  const BatchSlotTile({
    super.key,
    required this.index,
    required this.date,
    required this.recipe,
    required this.prefs,
    required this.slotTime,
    required this.isGenerating,
    this.justification,
    this.prepDate,
    this.isGeneratedByAI = false,
    required this.onAssign,
    required this.onRemove,
    required this.onDelete,
    required this.onTimeChanged,
    this.onGenerateWithAI,
    this.onExportToCalendar,
    this.onRecipeTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isToday = date == today;
    final isBatchDay = prefs.batchCookingDay == date.weekday;
    final dayConstraint = prefs.dailyConstraints[date.weekday];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: GestureDetector(
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: slotTime,
                helpText: 'Heure du repas',
              );
              if (context.mounted && t != null) onTimeChanged(t);
            },
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  DateFormat('EEE', 'fr').format(date).toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: isToday
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  DateFormat('d', 'fr').format(date),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: isToday ? theme.colorScheme.primary : null,
                    fontWeight: isToday ? FontWeight.w700 : null,
                  ),
                ),
              ],
            ),
          ),
          title: recipe != null
              ? InkWell(
                  onTap: (recipe!.id.isNotEmpty && onRecipeTap != null)
                      ? onRecipeTap
                      : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          recipe!.titre,
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            decoration: (recipe!.id.isNotEmpty && onRecipeTap != null)
                                ? TextDecoration.underline
                                : null,
                          ),
                        ),
                      ),
                      if (isGeneratedByAI) ...
                        [
                          const SizedBox(width: 4),
                          Tooltip(
                            message: 'Générée par l\'IA',
                            child: Icon(
                              Icons.smart_toy_outlined,
                              size: 14,
                              color: Theme.of(context).colorScheme.tertiary,
                            ),
                          ),
                        ],
                    ],
                  ),
                )
              : Text(
                  'À assigner',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
          subtitle: _buildSubtitle(theme, dayConstraint, isBatchDay, slotTime),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isGenerating)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (onGenerateWithAI != null)
                IconButton(
                  icon: const Icon(Icons.auto_awesome_outlined, size: 20),
                  tooltip: 'Suggérer avec l\'IA',
                  onPressed: onGenerateWithAI,
                ),
              if (recipe != null) ...[
                IconButton(
                  icon: const Icon(Icons.event_outlined, size: 20),
                  tooltip: 'Ajouter au calendrier',
                  onPressed: onExportToCalendar,
                ),
                IconButton(
                  icon: const Icon(Icons.swap_horiz_outlined),
                  tooltip: 'Changer',
                  onPressed: onAssign,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Retirer',
                  onPressed: onRemove,
                ),
              ] else
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: 'Choisir une recette',
                  onPressed: onAssign,
                ),
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: Theme.of(context).colorScheme.error,
                ),
                tooltip: 'Supprimer ce jour',
                onPressed: onDelete,
              ),
            ],
          ),
          onTap: recipe == null ? onAssign : null,
        ),
        // Jour de préparation à l'avance (batch cooking)
        if (prepDate != null)
          Padding(
            padding: const EdgeInsets.only(left: 72, right: 16, bottom: 4),
            child: Row(
              children: [
                Icon(
                  Icons.schedule_outlined,
                  size: 13,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: 4),
                Text(
                  'À préparer le ${DateFormat('EEEE d MMM', 'fr').format(prepDate!)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.tertiary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        // Justification IA
        if (justification != null && justification!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 72, right: 16, bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 13,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    justification!,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildSubtitle(
    ThemeData theme,
    DayConstraint? constraint,
    bool isBatchDay,
    TimeOfDay time,
  ) {
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    final parts = <String>[];
    if (isBatchDay) parts.add('Batch cooking');
    if (constraint != null && !constraint.isEmpty) {
      if (constraint.maxPrepMinutes > 0) {
        parts.add('max ${constraint.maxPrepMinutes}min');
      }
      if (constraint.notes.trim().isNotEmpty) {
        parts.add(constraint.notes.trim());
      }
    }
    if (recipe != null) {
      final prep = recipe!.tags.prepTime;
      final cook = recipe!.tags.cookTime;
      if (prep != null || cook != null) {
        final times = <String>[];
        if (prep != null) times.add('${prep}min prép');
        if (cook != null) times.add('${cook}min cuisson');
        parts.add(times.join(' + '));
      }
    }

    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        children: [
          TextSpan(
            text: timeStr,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (parts.isNotEmpty)
            TextSpan(
              text: '  ·  ${parts.join(' · ')}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// Sheet de sélection de recette avec champ de recherche.
class BatchRecipePickerSheet extends StatefulWidget {
  final List<Recipe> recipes;

  const BatchRecipePickerSheet({super.key, required this.recipes});

  @override
  State<BatchRecipePickerSheet> createState() => _BatchRecipePickerSheetState();
}

class _BatchRecipePickerSheetState extends State<BatchRecipePickerSheet> {
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
            // Handle
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
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
                itemCount:
                    _filtered.length + (_query.trim().isNotEmpty ? 1 : 0),
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

/// Sheet de sélection des sources de recettes pour la génération IA par slot.
class RecipeSourceSheet extends StatefulWidget {
  final Set<RecipeSource> initialSources;

  const RecipeSourceSheet({super.key, required this.initialSources});

  @override
  State<RecipeSourceSheet> createState() => _RecipeSourceSheetState();
}

class _RecipeSourceSheetState extends State<RecipeSourceSheet> {
  late Set<RecipeSource> _selected;

  @override
  void initState() {
    super.initState();
    _selected = Set.of(widget.initialSources);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Handle
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Où chercher des recettes ?',
              style: theme.textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 4),
          for (final source in RecipeSource.values)
            CheckboxListTile(
              value: _selected.contains(source),
              title: Text(source.label),
              secondary: Icon(switch (source) {
                RecipeSource.myRecipes => Icons.check_circle_outline,
                RecipeSource.myDrafts => Icons.edit_outlined,
                RecipeSource.familyRecipes => Icons.group_outlined,
                RecipeSource.aiCreation => Icons.smart_toy_outlined,
              }),
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _selected.add(source);
                  } else {
                    _selected.remove(source);
                  }
                });
              },
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              onPressed: _selected.isEmpty
                  ? null
                  : () => Navigator.pop(context, _selected),
              icon: const Icon(Icons.auto_fix_high),
              label: const Text('Générer'),
            ),
          ),
        ],
      ),
    );
  }
}
