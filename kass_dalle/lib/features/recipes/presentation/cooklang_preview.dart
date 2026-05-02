import 'package:flutter/material.dart';

/// Widget d'aperçu CookLang — partagé entre DraftReviewScreen et RecipeDetailScreen.
class CooklangPreview extends StatelessWidget {
  final TextEditingController ctrl;
  const CooklangPreview({super.key, required this.ctrl});

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
    final ingredients = ingredientMap.values.toList();

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
          if (ingredients.isNotEmpty) ...[
            const Divider(height: 32),
            Text('Ingrédients', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: ingredients.map((ing) {
                final parts = [
                  if (ing.qty.isNotEmpty) ing.qty,
                  if (ing.unit.isNotEmpty) ing.unit,
                  ing.name,
                ];
                return Chip(
                  label: Text(parts.join(' ')),
                  backgroundColor: theme.colorScheme.secondaryContainer,
                );
              }).toList(),
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
        display = [
          if (qty.isNotEmpty) qty,
          if (unit.isNotEmpty) unit,
          name,
        ].join(' ');
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
