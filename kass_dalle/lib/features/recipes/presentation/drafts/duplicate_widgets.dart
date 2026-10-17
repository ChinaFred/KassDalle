import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_icon_size.dart';
import '../../domain/duplicate_reference.dart';
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
/// La référence est résolue à l'affichage ([duplicateReferenceProvider]) :
/// - recette lue (directement par [recipeId], ou créée depuis par l'import
///   plus ancien [jobId]) : [linkLabel] devient un lien qui l'ouvre ;
/// - import plus ancien encore en file ou en cours : [pendingLabel] ;
/// - recette refusée par les règles (livre privé ou brouillon d'un autre
///   membre) : [unreadableLabel], sans lien ;
/// - autre erreur de lecture (déjà signalée) : [plainLabel], sans lien ;
/// - plus rien (recette supprimée, import en erreur, rejeté, en doublon,
///   absent ou illisible) : « Recette supprimée », sans lien.
class DuplicateReferenceLink extends ConsumerWidget {
  const DuplicateReferenceLink({
    super.key,
    required this.recipeId,
    this.jobId,
    this.existingTitre = '',
    required this.linkLabel,
    required this.plainLabel,
    this.pendingLabel = '',
    this.unreadableLabel = 'Déjà dans le livre (page d\'un autre membre)',
    this.enabled = true,
  });

  final String? recipeId;
  final String? jobId;

  /// Le titre de la référence, qui départage les recettes d'un import
  /// terminé.
  final String existingTitre;
  final String Function(Recipe recipe) linkLabel;
  final String plainLabel;
  final String pendingLabel;
  final String unreadableLabel;

  /// Faux pendant une sélection : la ligne coche, elle ne navigue pas.
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    if (recipeId == null && jobId == null) {
      return Text(plainLabel, style: style);
    }
    final async = ref.watch(
      duplicateReferenceProvider((
        recipeId: recipeId,
        jobId: jobId,
        existingTitre: existingTitre,
      )),
    );
    final waiting = recipeId != null ? plainLabel : pendingLabel;
    return switch (async) {
      AsyncData(:final value) => switch (value) {
        DuplicateReferenceFound(:final recipe) => _DuplicateLinkButton(
          label: linkLabel(recipe),
          enabled: enabled,
          onPressed: () => openDuplicateReference(context, recipe),
        ),
        DuplicateReferencePending() => Text(pendingLabel, style: style),
        DuplicateReferenceUnreadable(:final denied) => Text(
          denied ? unreadableLabel : plainLabel,
          style: style,
        ),
        DuplicateReferenceGone() => Text(
          'Recette supprimée',
          style: style?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        ),
      },
      // Le provider rattrape et signale ses erreurs de lecture : celle-ci ne
      // peut venir que d'un défaut du code, que Riverpod remonte déjà.
      AsyncError() => Text(plainLabel, style: style),
      _ => Text(waiting, style: style),
    };
  }
}

/// Un lien dans une ligne de texte : souligné, annoncé comme lien aux
/// lecteurs d'écran, et une cible d'au moins [kMinInteractiveDimension].
///
/// [enabled] faux (mode sélection) : le texte garde l'apparence du lien et ne
/// réagit pas.
class _DuplicateLinkButton extends StatelessWidget {
  const _DuplicateLinkButton({
    required this.label,
    required this.onPressed,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.tertiary;
    final linkStyle = theme.textTheme.bodySmall?.copyWith(
      color: color,
      decoration: TextDecoration.underline,
      decorationColor: color,
    );
    if (!enabled) return Text(label, style: linkStyle);
    return Semantics(
      link: true,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: color,
          padding: EdgeInsets.zero,
          minimumSize: const Size(0, kMinInteractiveDimension),
          tapTargetSize: MaterialTapTargetSize.padded,
          alignment: Alignment.centerLeft,
          visualDensity: VisualDensity.standard,
        ),
        child: Text(label, style: linkStyle, textAlign: TextAlign.start),
      ),
    );
  }
}

/// Le bandeau d'un brouillon marqué « Doublon possible », sur l'écran de
/// relecture.
///
/// « Valider » reste offert : la validation efface la marque
/// (`RecipeRepository.validateDraft`). Le bandeau disparaît avec elle.
///
/// [initiallyExpanded] faux (téléphone) : le bandeau tient sur une ligne,
/// comme `FidelityBanner` au-dessus de lui, et le détail attend le chevron.
/// Deux bandeaux dépliés et fixes au-dessus de l'éditeur ne laissaient
/// presque rien de la recette à l'écran.
class DuplicateOfBanner extends StatefulWidget {
  const DuplicateOfBanner({
    super.key,
    required this.recipe,
    this.initiallyExpanded = true,
  });

  final Recipe recipe;
  final bool initiallyExpanded;

  @override
  State<DuplicateOfBanner> createState() => _DuplicateOfBannerState();
}

class _DuplicateOfBannerState extends State<DuplicateOfBanner> {
  late bool _ouvert = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final recipe = widget.recipe;
    final mark = recipe.duplicateOf;
    if (mark == null || recipe.reviewStatus == ReviewStatus.validated) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final couleur = theme.colorScheme.tertiary;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.35),
        border: Border.all(color: couleur.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            expanded: _ouvert,
            child: InkWell(
              onTap: () => setState(() => _ouvert = !_ouvert),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.content_copy_outlined,
                      color: couleur,
                      size: AppIconSize.small,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        mark.bannerLabel,
                        maxLines: _ouvert ? null : 1,
                        overflow: _ouvert ? null : TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: couleur,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      _ouvert ? Icons.expand_less : Icons.expand_more,
                      color: couleur,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_ouvert)
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (mark.recipeId != null || mark.jobId != null)
                    DuplicateReferenceLink(
                      recipeId: mark.recipeId,
                      jobId: mark.jobId,
                      existingTitre: mark.titre,
                      linkLabel: (_) => 'Ouvrir la recette existante',
                      plainLabel: 'Recette existante momentanément illisible',
                      pendingLabel:
                          'La référence est un import plus ancien, encore en '
                          'cours.',
                      unreadableLabel:
                          'Recette existante non consultable '
                          '(page d\'un autre membre)',
                    ),
                  const SizedBox(height: 2),
                  Text(
                    'Valider la publiera quand même et retirera cette marque.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
