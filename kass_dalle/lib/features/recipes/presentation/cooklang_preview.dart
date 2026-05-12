import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../domain/recipe.dart';

/// Widget d'aperçu CookLang — partagé entre DraftReviewScreen et RecipeDetailScreen.
///
/// Quand [overrideIngredients] est fourni et non vide, la section "Ingrédients"
/// utilise ces données structurées plutôt que celles extraites du texte CookLang.
/// Cela permet de refléter immédiatement les modifications faites dans l'éditeur
/// structuré sans avoir à modifier le texte CookLang.
///
/// [illustrationUrls] : URLs des illustrations de la recette.
/// [onAddIllustration] : callback pour ajouter une illustration (null → bouton masqué).
/// [onTapIllustration] : callback appelé avec l'index cliqué pour la visionneuse.
class CooklangPreview extends StatefulWidget {
  final TextEditingController ctrl;

  /// Liste d'ingrédients structurés à utiliser pour l'affichage.
  /// Quand null ou vide, les ingrédients sont extraits du texte CookLang.
  final List<RecipeIngredient>? overrideIngredients;

  /// URLs des illustrations attachées à la recette.
  final List<String>? illustrationUrls;

  /// Callback pour déclencher l'ajout d'une illustration.
  final VoidCallback? onAddIllustration;

  /// Callback appelé avec l'index de la miniature cliquée.
  final void Function(int index)? onTapIllustration;

  /// Callback appelé avec l'URL de la miniature à supprimer.
  final void Function(String url)? onDeleteIllustration;

  /// Callback optionnel pour déclencher la création de la liste de courses.
  /// Si null, le bouton n'est pas affiché dans la section ingrédients.
  final VoidCallback? onCreateShoppingList;

  /// Types de plat à afficher (viande, dessert, etc.)
  /// Optionnel — si null ou vide, la section n'est pas affichée.
  final List<String>? dishTypes;

  const CooklangPreview({
    super.key,
    required this.ctrl,
    this.overrideIngredients,
    this.illustrationUrls,
    this.onAddIllustration,
    this.onTapIllustration,
    this.onDeleteIllustration,
    this.onCreateShoppingList,
    this.dishTypes,
  });

  @override
  State<CooklangPreview> createState() => _CooklangPreviewState();
}

class _CooklangPreviewState extends State<CooklangPreview> {
  bool _dishTypesExpanded = true;
  bool _ingredientsExpanded = true;
  bool _preparationExpanded = true;

  Widget _buildSectionHeader(
    BuildContext context, {
    required IconData icon,
    required String title,
    required bool expanded,
    required VoidCallback onTap,
    Widget? action,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: theme.textTheme.titleMedium),
            const Spacer(),
            if (action != null) action,
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) => _buildPreview(context, widget.ctrl.text),
    );
  }

  Widget _buildPreview(BuildContext context, String text) {
    if (text.trim().isEmpty) {
      return const Center(child: Text('Aucun contenu à afficher'));
    }

    final overrideIngredients = widget.overrideIngredients;
    final illustrationUrls = widget.illustrationUrls;
    final onAddIllustration = widget.onAddIllustration;
    final onTapIllustration = widget.onTapIllustration;
    final onDeleteIllustration = widget.onDeleteIllustration;
    final onCreateShoppingList = widget.onCreateShoppingList;
    final dishTypes = widget.dishTypes;

    final lines = text.split('\n');
    final Map<String, String> meta = {};
    // Clé : nom en minuscules — déduplique les ingrédients répétés entre étapes.
    final Map<String, _CookIngredient> ingredientMap = {};

    // Groupes de préparation (sections)
    final List<_StepGroup> stepGroups = [];
    _StepGroup currentGroup = _StepGroup(null, []);

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('--')) continue;
      if (trimmed.startsWith('>>')) {
        final rest = trimmed.substring(2).trim();
        final idx = rest.indexOf(':');
        if (idx >= 0) {
          meta[rest.substring(0, idx).trim().toLowerCase()] = rest
              .substring(idx + 1)
              .trim();
        }
      } else if (trimmed.startsWith('==')) {
        // Nouvelle section
        final sectionName = trimmed
            .replaceAll('==', '')
            .trim();
        if (currentGroup.steps.isNotEmpty || currentGroup.name != null) {
          stepGroups.add(currentGroup);
        }
        currentGroup = _StepGroup(sectionName.isEmpty ? null : sectionName, []);
      } else {
        currentGroup.steps.add(trimmed);
        // Les lignes notes (> texte) ne contiennent pas d'ingrédients structurés
        if (trimmed.startsWith('>')) continue;
        final re = RegExp(r'@([^{@#~]+)\{([^}]*)\}');
        for (final m in re.allMatches(trimmed)) {
          final name = m.group(1)!.trim();
          final key = name.toLowerCase();
          if (!ingredientMap.containsKey(key)) {
            final parts = (m.group(2) ?? '').split('%');
            ingredientMap[key] = _CookIngredient(
              name: name,
              qty: parts.isNotEmpty ? parts[0] : '',
              unit: parts.length > 1 ? parts[1] : '',
            );
          }
        }
      }
    }
    if (currentGroup.steps.isNotEmpty || currentGroup.name != null) {
      stepGroups.add(currentGroup);
    }

    // Compatibilité avec l'existant : liste plate des étapes
    final List<String> steps = stepGroups.expand((g) => g.steps).toList();
    final hasSections = stepGroups.length > 1 ||
        (stepGroups.length == 1 && stepGroups.first.name != null);
    final ingredients =
        (overrideIngredients != null && overrideIngredients!.isNotEmpty)
        ? overrideIngredients!
              .map(
                (i) => _CookIngredient(name: i.name, qty: i.qty, unit: i.unit),
              )
              .toList()
        : ingredientMap.values.toList();

    // Groupement par catégorie (uniquement si overrideIngredients fourni)
    final bool hasCategoryData =
        overrideIngredients != null &&
        overrideIngredients!.isNotEmpty &&
        overrideIngredients!.any(
          (i) => i.category != null && i.category!.isNotEmpty,
        );

    // Ordre des catégories tel qu'elles apparaissent dans la liste
    final List<String?> categoryOrder = [];
    if (hasCategoryData) {
      for (final ing in overrideIngredients!) {
        final cat = (ing.category?.isEmpty ?? true) ? null : ing.category;
        if (!categoryOrder.contains(cat)) categoryOrder.add(cat);
      }
    }

    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Chips méta + illustrations ────────────────────────────────────
          Builder(
            builder: (context) {
              final hasPortions =
                  meta.containsKey('portions') || meta.containsKey('servings');
              final hasPrepTime = meta.containsKey('prep_time');
              final hasCookTime = meta.containsKey('cook_time');
              final illus = illustrationUrls ?? const <String>[];
              final hasIllus = illus.isNotEmpty;
              final hasAdd = onAddIllustration != null;
              if (!hasPortions &&
                  !hasPrepTime &&
                  !hasCookTime &&
                  !hasIllus &&
                  !hasAdd) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (hasPortions)
                      Chip(
                        label: Text(
                          '${meta['portions'] ?? meta['servings']} portions',
                        ),
                        avatar: const Icon(Icons.people_outline, size: 16),
                      ),
                    if (hasPrepTime)
                      Chip(
                        label: Text('Prép. ${meta['prep_time']} min'),
                        avatar: const Icon(Icons.timer_outlined, size: 16),
                      ),
                    if (hasCookTime)
                      Chip(
                        label: Text('Cuisson ${meta['cook_time']} min'),
                        avatar: const Icon(
                          Icons.local_fire_department_outlined,
                          size: 16,
                        ),
                      ),
                    // Miniatures illustrations
                    for (int i = 0; i < illus.length; i++)
                      _IllustrationThumb(
                        url: illus[i],
                        onTap: () => onTapIllustration?.call(i),
                        onDelete: onDeleteIllustration != null
                            ? () => onDeleteIllustration!(illus[i])
                            : null,
                      ),
                    // Bouton ajout
                    if (hasAdd)
                      InkWell(
                        onTap: onAddIllustration,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.outline.withAlpha(80),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.add_a_photo_outlined,
                            size: 20,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          if (meta.isNotEmpty) const SizedBox(height: 8),
          if (dishTypes != null && dishTypes!.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              icon: Icons.restaurant_outlined,
              title: 'Type de plat',
              expanded: _dishTypesExpanded,
              onTap: () =>
                  setState(() => _dishTypesExpanded = !_dishTypesExpanded),
            ),
            if (_dishTypesExpanded)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: dishTypes!
                      .map(
                        (t) => Chip(
                          label: Text(t),
                          avatar: const Icon(
                            Icons.local_dining_outlined,
                            size: 14,
                          ),
                          backgroundColor: theme.colorScheme.tertiaryContainer,
                          labelStyle: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      )
                      .toList(),
                ),
              ),
            const Divider(height: 16),
          ],
          if (ingredients.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              icon: Icons.format_list_bulleted,
              title: 'Ingrédients',
              expanded: _ingredientsExpanded,
              onTap: () =>
                  setState(() => _ingredientsExpanded = !_ingredientsExpanded),
              action: onCreateShoppingList != null
                  ? IconButton(
                      onPressed: onCreateShoppingList,
                      icon: const Icon(Icons.shopping_cart_outlined),
                      tooltip: 'Liste de courses',
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      color: theme.colorScheme.primary,
                    )
                  : null,
            ),
            if (_ingredientsExpanded) ...[
            const SizedBox(height: 8),
            if (hasCategoryData) ...[
              // Affichage groupé par catégorie
              ...categoryOrder.map((cat) {
                final group = overrideIngredients!
                    .where(
                      (i) => cat == null
                          ? (i.category == null || i.category!.isEmpty)
                          : i.category == cat,
                    )
                    .toList();
                if (group.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (cat != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        cat,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: group.map((ing) {
                        return Chip(
                          label: Text(
                            _formatIngredient(ing.qty, ing.unit, ing.name),
                          ),
                          backgroundColor: theme.colorScheme.secondaryContainer,
                        );
                      }).toList(),
                    ),
                  ],
                );
              }),
            ] else ...[
              // Affichage plat (CookLang parsé ou pas de catégories)
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: ingredients.map((ing) {
                  return Chip(
                    label: Text(_formatIngredient(ing.qty, ing.unit, ing.name)),
                    backgroundColor: theme.colorScheme.secondaryContainer,
                  );
                }).toList(),
              ),
            ],
            ], // _ingredientsExpanded
            const Divider(height: 16),
          ],
          if (steps.isNotEmpty) ...[
            _buildSectionHeader(
              context,
              icon: Icons.menu_book_outlined,
              title: 'Préparation',
              expanded: _preparationExpanded,
              onTap: () =>
                  setState(() => _preparationExpanded = !_preparationExpanded),
            ),
            if (_preparationExpanded) ...[
              const SizedBox(height: 8),
              if (hasSections)
                ..._buildSectionedSteps(context, stepGroups)
              else
                ..._buildFlatSteps(context, steps),
            ], // _preparationExpanded
          ],
        ],
      ),
    );
  }

  List<Widget> _buildFlatSteps(BuildContext context, List<String> steps) {
    final theme = Theme.of(context);
    int stepCounter = 0;
    return steps.map((step) {
      if (step.startsWith('>')) {
        return _buildNoteWidget(context, step.substring(1).trim());
      }
      stepCounter++;
      final rawStep = step.replaceFirst(RegExp(r'^\d+[\.)\-]\s*'), '');
      return Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 13,
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                '$stepCounter',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _buildStepText(context, rawStep)),
          ],
        ),
      );
    }).toList();
  }

  List<Widget> _buildSectionedSteps(
    BuildContext context,
    List<_StepGroup> groups,
  ) {
    final theme = Theme.of(context);
    int globalStepIndex = 0;
    final widgets = <Widget>[];

    for (final group in groups) {
      if (group.steps.isEmpty) continue;

      if (group.name != null) {
        // Carte avec titre de section
        widgets.add(
          Card(
            margin: const EdgeInsets.only(bottom: 12),
            color: theme.colorScheme.surfaceContainerLow,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                color: theme.colorScheme.outlineVariant,
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.label_outline,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        group.name!,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ...group.steps.map((step) {
                    if (step.startsWith('>')) {
                      return _buildNoteWidget(
                        context,
                        step.substring(1).trim(),
                      );
                    }
                    final idx = globalStepIndex++;
                    final rawStep =
                        step.replaceFirst(RegExp(r'^\d+[\.)\-]\s*'), '');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              '${idx + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: _buildStepText(context, rawStep)),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        );
      } else {
        // Étapes sans section (avant la 1ère section)
        for (final step in group.steps) {
          if (step.startsWith('>')) {
            widgets.add(_buildNoteWidget(context, step.substring(1).trim()));
            continue;
          }
          final idx = globalStepIndex++;
          final rawStep = step.replaceFirst(RegExp(r'^\d+[\.)\-]\s*'), '');
          widgets.add(
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 13,
                    backgroundColor: theme.colorScheme.primaryContainer,
                    child: Text(
                      '${idx + 1}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: _buildStepText(context, rawStep)),
                ],
              ),
            ),
          );
        }
      }
    }
    return widgets;
  }

  Widget _buildNoteWidget(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withAlpha(120),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.secondary.withAlpha(80),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.tips_and_updates_outlined,
            size: 16,
            color: theme.colorScheme.secondary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepText(BuildContext context, String step) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    final re = RegExp(r'(@[^{@#~]+\{[^}]*\}|#[^{@#~]+\{[^}]*\}|~\{[^}]*\})');
    int lastEnd = 0;

    for (final match in re.allMatches(step)) {
      if (match.start > lastEnd) {
        spans.add(TextSpan(text: step.substring(lastEnd, match.start)));
      }
      final token = match.group(0)!;
      String display;
      Color bgColor;

      if (token.startsWith('@')) {
        final name = token.substring(1, token.indexOf('{')).trim();
        final content = token.substring(
          token.indexOf('{') + 1,
          token.length - 1,
        );
        final parts = content.split('%');
        final qty = parts.isNotEmpty ? parts[0] : '';
        final unit = parts.length > 1 ? parts[1] : '';
        display = _formatIngredient(qty, unit, name);
        bgColor = theme.colorScheme.primaryContainer;
      } else if (token.startsWith('#')) {
        display = token.substring(1, token.indexOf('{')).trim();
        bgColor = theme.colorScheme.tertiaryContainer;
      } else {
        final content = token.substring(2, token.length - 1);
        display = _formatTimer(content);
        bgColor = theme.colorScheme.secondaryContainer;
      }

      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              display,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
            ),
          ),
        ),
      );

      lastEnd = match.end;
    }

    if (lastEnd < step.length) {
      spans.add(TextSpan(text: step.substring(lastEnd)));
    }

    return RichText(
      text: TextSpan(style: theme.textTheme.bodyMedium, children: spans),
    );
  }
}

/// Miniature d'illustration (48×48) avec long-press pour supprimer.
class _IllustrationThumb extends StatelessWidget {
  final String url;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _IllustrationThumb({
    required this.url,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onDelete != null
          ? () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Supprimer cette illustration ?'),
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
              if (confirmed == true) onDelete!();
            }
          : null,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: url,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          placeholder: (_, _) => Container(
            width: 48,
            height: 48,
            color: Colors.grey.shade200,
            child: const Icon(Icons.image_outlined, size: 20),
          ),
          errorWidget: (_, _, _) => Container(
            width: 48,
            height: 48,
            color: Colors.grey.shade200,
            child: const Icon(Icons.broken_image_outlined, size: 20),
          ),
        ),
      ),
    );
  }
}

/// Formate un timer CookLang hh:mm:ss en texte lisible.
/// Ex : "0:30:00" → "30 minutes", "1:30:00" → "1h30", "0:02:00" → "2 minutes"
String _formatTimer(String raw) {
  final parts = raw.trim().split(':');
  if (parts.length != 3) return raw;
  final h = int.tryParse(parts[0]) ?? 0;
  final m = int.tryParse(parts[1]) ?? 0;
  final s = int.tryParse(parts[2]) ?? 0;
  if (h == 0 && m == 0 && s == 0) return raw;
  if (h == 0 && s == 0) return m == 1 ? '1 minute' : '$m minutes';
  if (h > 0 && m == 0 && s == 0) return h == 1 ? '1 heure' : '$h heures';
  if (h > 0 && m > 0 && s == 0) {
    return '${h}h${m.toString().padLeft(2, '0')}';
  }
  if (h == 0 && m > 0 && s > 0) return '$m min $s s';
  return '${h}h${m.toString().padLeft(2, '0')} $s s';
}

/// Formate l'affichage d'un ingrédient en évitant la répétition unité/nom.
/// Ex : qty="1", unit="brin", name="brin de romarin" → "1 brin de romarin"
///      qty="2", unit="pièces", name="côtes de veau"  → "2 pièces côtes de veau"
String _formatIngredient(String qty, String unit, String name) {
  // Supprimer l'unité si le nom commence déjà par ce mot (insensible à la casse)
  final showUnit =
      unit.isNotEmpty && !name.toLowerCase().startsWith(unit.toLowerCase());
  return [if (qty.isNotEmpty) qty, if (showUnit) unit, name].join(' ');
}

class _CookIngredient {
  final String name;
  final String qty;
  final String unit;
  const _CookIngredient({
    required this.name,
    required this.qty,
    required this.unit,
  });
}

class _StepGroup {
  final String? name; // null = étapes sans section
  final List<String> steps;
  _StepGroup(this.name, this.steps);
}
