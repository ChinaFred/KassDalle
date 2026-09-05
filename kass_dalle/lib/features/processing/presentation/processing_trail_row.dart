import 'package:flutter/material.dart';

import '../domain/processing_job.dart';
import '../domain/processing_step_labels.dart';
import '../domain/processing_trail.dart';

/// Le fil des étapes d'un traitement, en icônes.
///
/// Il remplace la phrase « Lecture de la page par l'IA… » affichée sous le
/// titre. Sur un téléphone étroit — et dès que la police du système est
/// agrandie — cette phrase se coupait une lettre par ligne et poussait la tuile
/// sur une demi-page.
///
/// Les icônes disent davantage que la phrase : elles montrent **où l'on en est
/// dans la suite**, et combien il reste. La phrase ne disait que l'instant.
///
/// Deux lignes, et pas une seule. Les jalons occupaient la première moitié de
/// la ligne et le mot de l'étape courante la seconde : trop de choses côte à
/// côte pour être lues d'un coup d'œil. Les icônes ont donc leur ligne, et
/// l'étape courante la sienne — son icône, puis son libellé complet.
class ProcessingTrailRow extends StatelessWidget {
  final ProcessingJobType type;
  final String? currentStep;

  /// Vrai quand le traitement est fini : tous les jalons s'éteignent en
  /// « fait », aucun n'est en cours.
  final bool termine;

  const ProcessingTrailRow({
    super.key,
    required this.type,
    required this.currentStep,
    this.termine = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trail = trailFor(type);
    final courant = stepIndexIn(trail, currentStep);

    // Étape hors du fil : c'est un libellé écrit en clair par le client. On
    // rend le texte plutôt qu'un fil qui désignerait la mauvaise case.
    if (courant == null && !termine) {
      final texte = formatProcessingStep(currentStep);
      if (texte.isEmpty) return const SizedBox.shrink();
      return Text(
        texte,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.secondary,
          fontStyle: FontStyle.italic,
        ),
      );
    }

    final atteint = termine ? trail.length : courant!;
    final fait = theme.colorScheme.primary;
    final aVenir = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Première ligne : les jalons, et rien d'autre.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < trail.length; i++) ...[
              if (i > 0)
                Container(
                  width: 6,
                  height: 1.5,
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  color: i <= atteint ? fait : aVenir,
                ),
              Tooltip(
                message: formatProcessingStep(trail[i].code),
                child: Icon(
                  trail[i].icon,
                  size: 15,
                  color: i <= atteint ? fait : aVenir,
                ),
              ),
            ],
          ],
        ),
        // Seconde ligne : l'étape courante, son icône et son libellé complet.
        if (!termine) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                trail[atteint].icon,
                size: 13,
                color: theme.colorScheme.secondary,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  formatProcessingStep(trail[atteint].code),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
