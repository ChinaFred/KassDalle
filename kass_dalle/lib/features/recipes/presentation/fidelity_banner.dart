import 'package:flutter/material.dart';

import '../domain/recipe.dart';

/// Ce que le contrôle de fidélité a constaté entre la page du livre et le
/// balisage de la recette.
///
/// Le verdict est produit à l'import, sans appel de modèle : autant
/// d'ingrédients que de lignes dans le livre ? autant d'étapes qu'à la
/// transcription ? titres de section entiers ? Il était jusqu'ici écrit sur la
/// recette et lu par personne — exactement le défaut que ce projet traque
/// ailleurs : une donnée que l'on produit et que rien n'affiche finit par
/// mentir sans que quiconque s'en aperçoive.
///
/// Deux niveaux, et la différence se voit :
///
/// - **Rupture** : le balisage a été ÉCARTÉ. Le texte affiché est la
///   transcription verbatim de la page — exacte, mais sans balise : pas de
///   puces d'ingrédients, pas d'ustensiles, pas de minuteurs. C'est un choix
///   assumé : mieux vaut une recette exacte et nue qu'une recette balisée et
///   fausse.
/// - **Avertissement** : un détail a bougé (un titre de section raccourci, un
///   ingrédient de trop). Le balisage est conservé.
///
/// Dans les deux cas, la réponse est la même : relancer le raffinage depuis
/// l'éditeur, ou corriger à la main. Le bandeau le dit, plutôt que de laisser
/// deviner.
class FidelityBanner extends StatelessWidget {
  const FidelityBanner({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final level = recipe.fidelityLevel;
    if (level == null || level.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final rupture = recipe.fidelityRejected;
    final couleur = rupture ? theme.colorScheme.error : Colors.orange;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.08),
        border: Border.all(color: couleur.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                rupture ? Icons.report_outlined : Icons.warning_amber_outlined,
                color: couleur,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  rupture
                      ? 'Texte du livre conservé, sans balise'
                      : 'Écart constaté avec la page du livre',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: couleur,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            rupture
                ? 'Le balisage rendu par l\'IA ne correspondait pas à la page : '
                      'il a été écarté au profit du texte transcrit tel quel. La '
                      'recette est exacte, mais ses ingrédients et ustensiles ne '
                      'sont pas mis en évidence.'
                : 'La recette est enregistrée, avec cette réserve :',
            style: theme.textTheme.bodySmall,
          ),
          for (final finding in recipe.fidelityFindings)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Text(
                '• $finding',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            'Relancez « Raffiner » depuis l\'éditeur pour retenter le balisage, '
            'ou corrigez à la main.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
