import 'package:flutter/material.dart';

import '../domain/recipe_filter.dart';

/// Un groupe de puces de filtre : un titre et une puce par valeur, avec son
/// nombre de recettes (« Plat (40) »). Commun au sélecteur du planning et à
/// l'écran Explorer.
///
/// Rien ne s'affiche quand le corpus n'offre aucune valeur.
class RecipeFacetChipGroup extends StatelessWidget {
  final String title;
  final List<RecipeFacet> facets;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  /// Ligne d'aide sous le titre, facultative.
  final String? help;

  const RecipeFacetChipGroup({
    super.key,
    required this.title,
    required this.facets,
    required this.selected,
    required this.onToggle,
    this.help,
  });

  @override
  Widget build(BuildContext context) {
    if (facets.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          if (help != null) ...[
            const SizedBox(height: 2),
            Text(
              help!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final facet in facets)
                FilterChip(
                  label: Text('${facet.label} (${facet.count})'),
                  selected: selected.contains(facet.key),
                  onSelected: (_) => onToggle(facet.key),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
