import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/storage_advice.dart';
import '../domain/meal_storage_rules.dart';
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

/// Éditeur des contraintes d'un slot : prépa max, parts, réchauffage, note.
///
/// Chaque frappe est remontée au parent. Une validation clavier ne suffisait
/// pas : le champ de note est multiligne, donc `onFieldSubmitted` n'y est
/// jamais appelé — la contrainte saisie n'atteignait jamais l'IA.
class SlotConstraintsEditor extends StatefulWidget {
  final DayConstraint constraint;
  final ValueChanged<int> onMaxPrepChanged;
  final ValueChanged<int> onTargetPortionsChanged;
  final ValueChanged<bool> onReheatChanged;
  final ValueChanged<String> onNotesChanged;

  const SlotConstraintsEditor({
    super.key,
    required this.constraint,
    required this.onMaxPrepChanged,
    required this.onTargetPortionsChanged,
    required this.onReheatChanged,
    required this.onNotesChanged,
  });

  @override
  State<SlotConstraintsEditor> createState() => _SlotConstraintsEditorState();
}

class _SlotConstraintsEditorState extends State<SlotConstraintsEditor> {
  late final TextEditingController _prepCtrl;
  late final TextEditingController _portionsCtrl;
  late final TextEditingController _notesCtrl;

  static String _numText(int value) => value > 0 ? '$value' : '';

  @override
  void initState() {
    super.initState();
    _prepCtrl = TextEditingController(
      text: _numText(widget.constraint.maxPrepMinutes),
    );
    _portionsCtrl = TextEditingController(
      text: _numText(widget.constraint.targetPortions),
    );
    _notesCtrl = TextEditingController(text: widget.constraint.notes);
  }

  @override
  void didUpdateWidget(SlotConstraintsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Ne réécrire que si la valeur vient d'ailleurs que du champ lui-même,
    // sinon le curseur saute à chaque frappe.
    _syncController(_prepCtrl, _numText(widget.constraint.maxPrepMinutes));
    _syncController(_portionsCtrl, _numText(widget.constraint.targetPortions));
    _syncController(_notesCtrl, widget.constraint.notes);
  }

  void _syncController(TextEditingController ctrl, String value) {
    if (ctrl.text != value) ctrl.text = value;
  }

  @override
  void dispose() {
    _prepCtrl.dispose();
    _portionsCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 150,
          child: TextField(
            controller: _prepCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Prépa max (min)',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                widget.onMaxPrepChanged(int.tryParse(value.trim()) ?? 0),
          ),
        ),
        SizedBox(
          width: 150,
          child: TextField(
            controller: _portionsCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Parts à préparer',
              hintText: '0 = portions recette',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                widget.onTargetPortionsChanged(int.tryParse(value.trim()) ?? 0),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Réchauffage'),
            Switch.adaptive(
              value: widget.constraint.isBatchCooking,
              onChanged: widget.onReheatChanged,
            ),
          ],
        ),
        SizedBox(
          width: 340,
          child: TextField(
            controller: _notesCtrl,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Contrainte spécifique',
              hintText: 'Ex: sport le soir, street food…',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onNotesChanged,
          ),
        ),
      ],
    );
  }
}

/// Tuile représentant un slot de planning dans BatchPlanningScreen.
class BatchSlotTile extends StatelessWidget {
  final int index;
  final DateTime date;
  final Recipe? recipe;
  final TimeOfDay slotTime;
  final bool isGenerating;
  final DayConstraint dayConstraint;
  final bool isBatchDay;
  final bool constraintsReadOnly;

  /// Justification IA de la suggestion (critères respectés/enfreints).
  final String? justification;

  /// Jour de préparation à l'avance (calculé depuis le batch cooking day).
  final DateTime? prepDate;

  /// True si la proposition associée au slot a été redimensionnée/ajustée.
  final bool wasResized;

  /// Détail du redimensionnement quand [wasResized] est true.
  final String? resizeReason;

  final bool isGeneratedByAI;

  /// Conseil de conservation de la recette, s'il en existe un.
  final StorageAdvice? storageAdvice;

  /// Vrai pendant la production du conseil de conservation de ce créneau.
  final bool storageLoading;

  /// Demande le conseil de conservation — null tant qu'aucune recette
  /// enregistrée n'est posée sur le créneau.
  final VoidCallback? onGenerateStorageAdvice;

  final VoidCallback onAssign;
  final VoidCallback onRemove;
  final VoidCallback onDelete;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final ValueChanged<int> onMaxPrepChanged;
  final ValueChanged<int> onTargetPortionsChanged;
  final ValueChanged<bool> onReheatChanged;
  final ValueChanged<String> onNotesChanged;
  final VoidCallback? onGenerateWithAI;
  final VoidCallback? onExportToCalendar;

  /// Callback appelé quand l'utilisateur tape sur le titre de la recette.
  final VoidCallback? onRecipeTap;

  const BatchSlotTile({
    super.key,
    required this.index,
    required this.date,
    required this.recipe,
    required this.slotTime,
    required this.isGenerating,
    required this.dayConstraint,
    required this.isBatchDay,
    this.constraintsReadOnly = false,
    this.justification,
    this.prepDate,
    this.wasResized = false,
    this.resizeReason,
    this.isGeneratedByAI = false,
    this.storageAdvice,
    this.storageLoading = false,
    this.onGenerateStorageAdvice,
    required this.onAssign,
    required this.onRemove,
    required this.onDelete,
    required this.onTimeChanged,
    required this.onMaxPrepChanged,
    required this.onTargetPortionsChanged,
    required this.onReheatChanged,
    required this.onNotesChanged,
    this.onGenerateWithAI,
    this.onExportToCalendar,
    this.onRecipeTap,
  });

  /// Consigne calculée : jour de préparation et mode imposé par le délai.
  ///
  /// Aucun appel d'IA n'a lieu ici — ces règles se calculent, et doivent
  /// s'afficher même sur une recette qui n'a jamais reçu de conseil.
  Widget _buildComputedStorage(ThemeData theme, DateTime prep) {
    final daysAhead = mealStorageDaysAhead(prepDate: prep, mealDate: date);
    final mode = mealStorageMode(daysAhead);
    final color = mode == MealStorageMode.freezer
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;

    return Row(
      children: [
        Icon(
          mode == MealStorageMode.freezer
              ? Icons.ac_unit_outlined
              : Icons.kitchen_outlined,
          size: 13,
          color: color,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            'À préparer le ${DateFormat('EEEE d MMM', 'fr').format(prep)} · '
            '${mealStorageInstruction(daysAhead)}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Ligne de conservation : consigne calculée quand le jour de préparation est
  /// connu, puis le conseil propre au plat ou le bouton qui le demande.
  Widget _buildStorageLine(ThemeData theme) {
    final prep = prepDate;
    final reheat = storageAdvice?.rechauffage;

    return Padding(
      padding: const EdgeInsets.only(left: 72, right: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // La consigne calculée n'a de sens que si l'on sait quel jour le plat
          // est préparé. Sans jour de préparation, seul le conseil reste utile.
          if (prep != null) _buildComputedStorage(theme, prep),
          if (reheat != null && !reheat.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 17),
              child: Text(
                'Réchauffage : ${reheat.summary}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else if (onGenerateStorageAdvice != null)
            Padding(
              padding: const EdgeInsets.only(left: 9),
              child: TextButton.icon(
                onPressed: storageLoading ? null : onGenerateStorageAdvice,
                icon: storageLoading
                    ? const SizedBox.square(
                        dimension: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.kitchen_outlined, size: 14),
                label: const Text('Conservation et réchauffage'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: theme.textTheme.labelSmall,
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final isToday = date == today;

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
                            decoration:
                                (recipe!.id.isNotEmpty && onRecipeTap != null)
                                ? TextDecoration.underline
                                : null,
                          ),
                        ),
                      ),
                      if (isGeneratedByAI) ...[
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
        Padding(
          padding: const EdgeInsets.only(left: 72, right: 16, bottom: 8),
          child: constraintsReadOnly
              ? _buildConstraintSummary(theme, dayConstraint)
              : SlotConstraintsEditor(
                  key: ValueKey('constraints-$index'),
                  constraint: dayConstraint,
                  onMaxPrepChanged: onMaxPrepChanged,
                  onTargetPortionsChanged: onTargetPortionsChanged,
                  onReheatChanged: onReheatChanged,
                  onNotesChanged: onNotesChanged,
                ),
        ),
        // Jour de préparation à l'avance, et ce que le plat devra supporter.
        if (prepDate != null || onGenerateStorageAdvice != null)
          _buildStorageLine(theme),
        // Explicabilité (pourquoi + statut redimensionnement)
        if (recipe != null)
          Padding(
            padding: const EdgeInsets.only(left: 72, right: 16, bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                        'Pourquoi : $_explainWhy',
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
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.open_in_full_outlined,
                      size: 13,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _resizeExplainability,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  String get _explainWhy {
    final value = justification?.trim() ?? '';
    if (value.isNotEmpty) return value;
    return 'Sélection validée sans justification détaillée.';
  }

  String get _resizeExplainability {
    if (!wasResized) return 'Redimensionnée : non';
    final detail = (resizeReason ?? '').trim();
    if (detail.isEmpty) return 'Redimensionnée : oui';
    return 'Redimensionnée : oui ($detail)';
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
    if (isBatchDay) parts.add('jour de batch cooking (repas normal)');
    if (constraint != null && !constraint.isEmpty) {
      if (constraint.maxPrepMinutes > 0) {
        parts.add('max ${constraint.maxPrepMinutes}min');
      }
      if (constraint.targetPortions > 0) {
        parts.add('${constraint.targetPortions} parts');
      }
      if (constraint.isBatchCooking && !isBatchDay) {
        parts.add('réchauffage');
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

  Widget _buildConstraintSummary(ThemeData theme, DayConstraint constraint) {
    final chips = <Widget>[];
    if (constraint.maxPrepMinutes > 0) {
      chips.add(
        _constraintChip(theme, 'Prépa max ${constraint.maxPrepMinutes} min'),
      );
    }
    if (constraint.targetPortions > 0) {
      chips.add(_constraintChip(theme, '${constraint.targetPortions} parts'));
    }
    chips.add(
      _constraintChip(
        theme,
        constraint.isBatchCooking ? 'Réchauffage: oui' : 'Réchauffage: non',
      ),
    );

    final notes = constraint.notes.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(spacing: 8, runSpacing: 8, children: chips),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            notes,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _constraintChip(ThemeData theme, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
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
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
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
