import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../recipes/presentation/recipe_rating_widget.dart';
import '../domain/explore_facets.dart';
import '../domain/search_models.dart';
import '../../../core/theme/app_icon_size.dart';

// ── Tuile résultat de recherche ───────────────────────────────────────────────

/// Une recette de la bibliothèque. Avec une raison, c'est une recette choisie
/// par l'IA ; sans, une recette retenue par le filtre local.
class SearchResultTile extends StatelessWidget {
  final RecipeSearchResult result;

  /// Section « Dans les ingrédients principaux » : les ingrédients qui ont
  /// fait retenir la recette, cités sur une ligne « Avec : … ».
  final List<String> matchedIngredients;

  const SearchResultTile({
    super.key,
    required this.result,
    this.matchedIngredients = const [],
  });

  @override
  Widget build(BuildContext context) {
    final recipe = result.recipe;
    final reason = result.reason;
    final theme = Theme.of(context);
    final isDraft = recipe.reviewStatus != ReviewStatus.validated;
    // Temps total affiché : durées lues, et l'estimation de l'IA pour une
    // durée absente, signalée « ≈ …, estimé ». La tuile l'affiche quel que
    // soit l'interrupteur du filtre : c'est une information, pas un choix.
    final times = recipeTimes(recipe);

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
                  isDraft ? Icons.edit_note : Icons.restaurant_menu_outlined,
                  size: AppIconSize.small,
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
                              avatar: const Icon(
                                Icons.edit_note,
                                size: AppIconSize.inline,
                              ),
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
                    if (matchedIngredients.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        matchedIngredientsLine(matchedIngredients),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (times.total case final minutes?) ...[
                      const SizedBox(height: 4),
                      _DurationLine(
                        minutes: minutes,
                        estimated: times.isEstimated,
                      ),
                    ],
                    // Raison : seulement pour une recette choisie par l'IA.
                    if (reason != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Ce qui vient d'une machine porte l'icône de la
                          // machine : cette raison est écrite par l'IA.
                          Icon(
                            Icons.smart_toy_outlined,
                            size: AppIconSize.inline,
                            color: theme.colorScheme.primary,
                            semanticLabel: 'Raison donnée par l\'IA',
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              reason,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
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
              const Icon(Icons.chevron_right, size: AppIconSize.small),
            ],
          ),
        ),
      ),
    );
  }
}

/// En-tête repliable d'une section de la recherche par texte : « Dans le
/// titre (12) » et un chevron. Toute la ligne bascule la section, au doigt,
/// à la souris ou au clavier (Entrée, Espace).
class QuerySectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool open;
  final VoidCallback onToggle;

  const QuerySectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      button: true,
      expanded: open,
      child: Tooltip(
        message: open ? 'Masquer' : 'Afficher',
        child: InkWell(
          onTap: onToggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '$title ($count)',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    open ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SearchSectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;

  const SearchSectionHeader({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class GeneratedRecipeSuggestionTile extends StatelessWidget {
  final GeneratedRecipeSuggestion suggestion;
  final VoidCallback onTap;

  /// Vrai une fois l'idée enregistrée en brouillon.
  final bool saved;

  const GeneratedRecipeSuggestionTile({
    super.key,
    required this.suggestion,
    required this.onTap,
    this.saved = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final recipe = suggestion.recipe;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.auto_awesome,
                  size: AppIconSize.small,
                  color: theme.colorScheme.onSecondaryContainer,
                  semanticLabel: 'Créée par l\'IA',
                ),
              ),
              const SizedBox(width: 12),
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
                        _TagChip(label: suggestion.variantLabel),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 2,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Chip(
                          avatar: Icon(
                            saved ? Icons.edit_note : Icons.auto_awesome,
                            size: AppIconSize.inline,
                          ),
                          label: Text(
                            saved
                                ? 'Brouillon enregistré'
                                : 'Pas encore enregistrée',
                          ),
                          labelStyle: theme.textTheme.labelSmall,
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        if (recipeTotalMinutes(recipe) case final m?)
                          _DurationLine(minutes: m),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      suggestion.justification,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (recipe.tags.themes.isNotEmpty ||
                        recipe.tags.cuisines.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          ...recipe.tags.themes
                              .take(3)
                              .map((themeName) => _TagChip(label: themeName)),
                          ...recipe.tags.cuisines
                              .take(2)
                              .map((cuisine) => _TagChip(label: cuisine)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: AppIconSize.small),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tuile d'attente d'une idée en cours de rédaction.
class GeneratedRecipePlaceholderTile extends StatelessWidget {
  const GeneratedRecipePlaceholderTile({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget bar(double widthFactor) => FractionallySizedBox(
      widthFactor: widthFactor,
      alignment: Alignment.centerLeft,
      child: Container(
        height: 12,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
    // Les barres grises ne disent rien à qui écoute l'écran : une phrase.
    return Semantics(
      label: 'Recette en cours de rédaction',
      excludeSemantics: true,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.auto_awesome,
                  size: AppIconSize.small,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [bar(0.6), const SizedBox(height: 8), bar(0.9)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// « ⏱ 45 min » : le temps total d'une recette. « ⏱ ≈ 45 min, estimé »
/// quand une composante vient de l'estimation de l'IA.
class _DurationLine extends StatelessWidget {
  final int minutes;
  final bool estimated;
  const _DurationLine({required this.minutes, this.estimated = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.timer_outlined, size: AppIconSize.inline, color: color),
        const SizedBox(width: 4),
        Text(
          exploreDurationText(minutes, estimated: estimated),
          style: theme.textTheme.bodySmall?.copyWith(color: color),
          semanticsLabel: exploreDurationSpoken(minutes, estimated: estimated),
        ),
      ],
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
