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
///
/// Il se replie, et c'est un besoin réel : il occupe le haut de l'écran de
/// relecture, et l'on vient d'abord y relire la recette. Ouvert au premier
/// affichage — une réserve qu'il faut aller chercher n'est pas une réserve.
class FidelityBanner extends StatefulWidget {
  const FidelityBanner({super.key, required this.recipe});

  final Recipe recipe;

  @override
  State<FidelityBanner> createState() => _FidelityBannerState();
}

class _FidelityBannerState extends State<FidelityBanner> {
  bool _ouvert = true;

  @override
  Widget build(BuildContext context) {
    final recipe = widget.recipe;
    final level = recipe.fidelityLevel;
    if (level == null || level.isEmpty) return const SizedBox.shrink();

    // Une recette validée a été relue. La réserve a fait son office : elle a
    // dit où regarder, quelqu'un a regardé et a tranché. La rappeler ensuite
    // reviendrait à contester cette décision indéfiniment — et une alerte qui
    // ne s'éteint jamais cesse d'être lue, y compris sur les brouillons où
    // elle compte.
    if (recipe.reviewStatus == ReviewStatus.validated) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final rupture = recipe.fidelityRejected;
    final couleur = rupture ? theme.colorScheme.error : Colors.orange;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: couleur.withValues(alpha: 0.08),
        border: Border.all(color: couleur.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _ouvert = !_ouvert),
            child: Row(
              children: [
                Icon(
                  rupture
                      ? Icons.report_outlined
                      : Icons.warning_amber_outlined,
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
                Icon(
                  _ouvert ? Icons.expand_less : Icons.expand_more,
                  color: couleur,
                ),
              ],
            ),
          ),
          if (_ouvert) ...[
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
            for (final finding in recipe.fidelityFindings) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  finding.message,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // Une puce par élément. Sept mots mal lus concaténés dans une
              // phrase formaient un pavé qu'on ne relisait pas.
              for (final item in finding.items)
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 12),
                  child: Text('• $item', style: theme.textTheme.bodySmall),
                ),
            ],
            const SizedBox(height: 8),
            Text(
              'Relancez « Raffiner » depuis l\'éditeur pour retenter le balisage, '
              'ou corrigez à la main.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
