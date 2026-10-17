import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/recipe.dart';
import '../recipe_providers.dart';

// Ce que la file et la relecture affichent d'un doublon possible : le lien
// vers la recette existante, et le bandeau d'un brouillon marqué.

/// Ouvre une recette existante : la relecture tant qu'elle est un brouillon,
/// la fiche une fois validée.
void openDuplicateReference(BuildContext context, Recipe recipe) {
  context.push(
    recipe.reviewStatus == ReviewStatus.validated
        ? '/recipes/${recipe.id}'
        : '/drafts/${recipe.id}',
  );
}

/// La référence d'un doublon possible, cliquable quand la recette se lit.
///
/// La recette est relue à l'affichage, une fois :
/// - lue : [label] devient un lien qui l'ouvre ;
/// - absente : « Recette supprimée », sans lien ;
/// - illisible (livre privé ou brouillon non partagé d'un autre membre) :
///   [unreadableLabel], sans lien. Ce refus est attendu, il ne se signale pas.
///
/// Sans [recipeId] (la référence est un import plus ancien), [label] s'affiche
/// tel quel.
class DuplicateReferenceLink extends ConsumerWidget {
  const DuplicateReferenceLink({
    super.key,
    required this.recipeId,
    required this.label,
    this.unreadableLabel = 'Déjà dans le livre (page d\'un autre membre)',
    this.enabled = true,
  });

  final String? recipeId;
  final String label;
  final String unreadableLabel;

  /// Faux pendant une sélection : la ligne coche, elle ne navigue pas.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final id = recipeId;
    if (id == null) return Text(label, style: style);
    final async = ref.watch(recipeByIdProvider(id));
    return async.when(
      loading: () => Text(label, style: style),
      error: (_, _) => Text(unreadableLabel, style: style),
      data: (recipe) {
        if (recipe == null) {
          return Text(
            'Recette supprimée',
            style: style?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          );
        }
        final linkStyle = style?.copyWith(
          color: theme.colorScheme.tertiary,
          decoration: TextDecoration.underline,
          decorationColor: theme.colorScheme.tertiary,
        );
        if (!enabled) return Text(label, style: linkStyle);
        return InkWell(
          onTap: () => openDuplicateReference(context, recipe),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(label, style: linkStyle),
          ),
        );
      },
    );
  }
}

/// Le bandeau d'un brouillon marqué « Doublon possible », sur l'écran de
/// relecture.
///
/// « Valider » reste offert : la validation efface la marque
/// (`RecipeRepository.validateDraft`). Le bandeau disparaît avec elle.
class DuplicateOfBanner extends StatelessWidget {
  const DuplicateOfBanner({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final mark = recipe.duplicateOf;
    if (mark == null || recipe.reviewStatus == ReviewStatus.validated) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final couleur = theme.colorScheme.tertiary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35),
        border: Border.all(color: couleur.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.content_copy_outlined, color: couleur, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  mark.bannerLabel,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: couleur,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (mark.recipeId != null) ...[
                  const SizedBox(height: 2),
                  DuplicateReferenceLink(
                    recipeId: mark.recipeId,
                    label: 'Ouvrir la recette existante',
                    unreadableLabel:
                        'Recette existante non consultable '
                        '(page d\'un autre membre)',
                  ),
                ] else if (mark.jobId != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'La référence est un import plus ancien, encore en cours.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
