import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/recipe_rating_widget.dart';
import '../domain/search_models.dart';

// ── Tuile résultat de recherche ───────────────────────────────────────────────

class SearchResultTile extends StatelessWidget {
  final RecipeSearchResult result;

  const SearchResultTile({super.key, required this.result});

  @override
  Widget build(BuildContext context) {
    final recipe = result.recipe;
    final theme = Theme.of(context);
    final isDraft = recipe.reviewStatus != ReviewStatus.validated;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (isDraft) {
            context.push('${AppRoutes.drafts}/${recipe.id}');
          } else {
            context.push('${AppRoutes.recipes}/${recipe.id}');
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icône statut
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isDraft
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isDraft ? Icons.edit_note : Icons.restaurant_menu,
                  size: 20,
                  color: isDraft
                      ? theme.colorScheme.onTertiaryContainer
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              // Contenu
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            recipe.titre,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        RecipeRatingBadge(recipeId: recipe.id),
                        if (isDraft)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Chip(
                              label: const Text('Brouillon'),
                              labelStyle: theme.textTheme.labelSmall,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                      ],
                    ),
                    if ((recipe.bookTitre ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        recipe.bookTitre!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    // Raison
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            result.reason,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Tags
                    if (recipe.tags.themes.isNotEmpty ||
                        recipe.tags.cuisines.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          ...recipe.tags.themes
                              .take(3)
                              .map((t) => _TagChip(label: t)),
                          ...recipe.tags.cuisines
                              .take(2)
                              .map((c) => _TagChip(label: c)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
