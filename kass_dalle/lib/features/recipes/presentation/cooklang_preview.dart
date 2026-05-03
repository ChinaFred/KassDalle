import 'package:flutter/material.dart';
import '../domain/recipe.dart';

/// Widget d'aperçu CookLang — partagé entre DraftReviewScreen et RecipeDetailScreen.
///
/// Quand [overrideIngredients] est fourni et non vide, la section "Ingrédients"
/// utilise ces données structurées plutôt que celles extraites du texte CookLang.
/// Cela permet de refléter immédiatement les modifications faites dans l'éditeur
/// structuré sans avoir à modifier le texte CookLang.
class CooklangPreview extends StatelessWidget {
  final TextEditingController ctrl;

  /// Liste d'ingrédients structurés à utiliser pour l'affichage.
  /// Quand null ou vide, les ingrédients sont extraits du texte CookLang.
  final List<RecipeIngredient>? overrideIngredients;

  const CooklangPreview({
    super.key,
    required this.ctrl,
    this.overrideIngredients,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ctrl,
      builder: (context, _) => _buildPreview(context, ctrl.text),
    );
  }

  Widget _buildPreview(BuildContext context, String text) {
    if (text.trim().isEmpty) {
      return const Center(child: Text('Aucun contenu à afficher'));
    }

    final lines = text.split('\n');
    final Map<String, String> meta = {};
    final List<String> steps = [];
    // Clé : nom en minuscules — déduplique les ingrédients répétés entre étapes.
    final Map<String, _CookIngredient> ingredientMap = {};

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
      } else {
        steps.add(trimmed);
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
          if (meta.containsKey('titre') || meta.containsKey('title'))
            Text(
              meta['titre'] ?? meta['title'] ?? '',
              style: theme.textTheme.headlineSmall,
            ),
          if (meta.containsKey('portions') || meta.containsKey('servings'))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Chip(
                label: Text('${meta['portions'] ?? meta['servings']} portions'),
                avatar: const Icon(Icons.people_outline, size: 16),
              ),
            ),
          if (meta.containsKey('prep_time') || meta.containsKey('cook_time'))
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                children: [
                  if (meta.containsKey('prep_time'))
                    Chip(
                      label: Text('Prép. ${meta['prep_time']} min'),
                      avatar: const Icon(Icons.timer_outlined, size: 16),
                    ),
                  if (meta.containsKey('cook_time'))
                    Chip(
                      label: Text('Cuisson ${meta['cook_time']} min'),
                      avatar: const Icon(
                        Icons.local_fire_department_outlined,
                        size: 16,
                      ),
                    ),
                ],
              ),
            ),
          if (meta.isNotEmpty) const SizedBox(height: 16),
          if (ingredients.isNotEmpty) ...[
            Text('Ingrédients', style: theme.textTheme.titleMedium),
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
            const Divider(height: 32),
          ],
          if (steps.isNotEmpty) ...[
            Text('Préparation', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...steps.asMap().entries.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Text(
                        '${e.key + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _buildStepText(context, e.value)),
                  ],
                ),
              ),
            ),
          ],
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
        display = content.replaceAll('%', ' ');
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
