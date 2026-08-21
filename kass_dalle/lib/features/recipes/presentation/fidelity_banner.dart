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
/// Il s'ouvre au clic, et REPLIÉ par défaut.
///
/// Il l'était ouvert, au motif qu'une réserve qu'il faut aller chercher n'est
/// pas une réserve. C'était juste tant qu'il tenait en trois lignes. Il porte
/// depuis le compte des photos, l'état de la donnée, cinq constats et leurs
/// puces : déplié, il occupe l'écran entier avant qu'on ait vu un ingrédient.
///
/// Le titre porte donc le signal — la nature de l'écart et son nombre de
/// points — et le détail attend le chevron. Une alerte qu'on doit faire défiler
/// pour atteindre la recette finit par se replier à la main, chaque fois.
class FidelityBanner extends StatefulWidget {
  const FidelityBanner({super.key, required this.recipe});

  final Recipe recipe;

  @override
  State<FidelityBanner> createState() => _FidelityBannerState();
}

class _FidelityBannerState extends State<FidelityBanner> {
  bool _ouvert = false;

  @override
  Widget build(BuildContext context) {
    final recipe = widget.recipe;
    final level = recipe.fidelityLevel;
    final illustrations = _messageIllustrations(recipe.illustrationReport);
    if ((level == null || level.isEmpty) && illustrations == null) {
      return const SizedBox.shrink();
    }

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
    final sansEcartDeTexte = level == null || level.isEmpty;

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
                    // Le nombre de points dans le titre : c'est lui qui dit
                    // s'il faut ouvrir. « Écart constaté » seul ne distingue
                    // pas un titre raccourci d'une recette amputée.
                    _titre(
                      sansEcartDeTexte: sansEcartDeTexte,
                      rupture: rupture,
                      points: recipe.fidelityFindings.length,
                    ),
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
            // Ce que la recette PORTE, lu sur elle et non déduit.
            //
            // Trois versions ont été passées à chercher pourquoi une note ne
            // s'affichait pas, sans jamais pouvoir dire si elle existait. Le
            // code écrit ce champ, mais personne ne pouvait le constater depuis
            // l'écran — et un raisonnement qu'on ne peut pas confronter à la
            // donnée finit par tourner en rond.
            //
            // Cette ligne le dit. Si elle annonce zéro, la chaîne d'import est
            // en cause ; si elle annonce deux et qu'on ne voit rien, c'est
            // l'affichage. Une question tranchée d'un coup d'œil.
            _LigneDonnee(
              avecNote: recipe.ingredients
                  .where((i) => (i.note ?? '').trim().isNotEmpty)
                  .length,
              avecSource: recipe.ingredients
                  .where((i) => (i.source ?? '').trim().isNotEmpty)
                  .length,
              total: recipe.ingredients.length,
            ),
            if (illustrations != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(illustrations, style: theme.textTheme.bodySmall),
              ),
            if (!sansEcartDeTexte)
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
            // Le conseil renvoyait vers « Raffiner », qui n'existe pas : la
            // fonction s'appelle « Améliorer » et ne fait que de la mise en
            // forme CookLang — elle ne relance ni la lecture de la page ni le
            // balisage. Envoyer quelqu'un vers un bouton qui ne répare pas ce
            // qu'on lui reproche, c'est lui faire perdre son temps deux fois.
            if (!sansEcartDeTexte)
              Text(
                'Corrigez à la main ci-dessous, en confrontant à la page du '
                'livre.',
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

/// Ce que la recherche de photos a donné, en une phrase actionnable.
///
/// `null` quand tout s'est bien passé — une photo publiée se voit, elle n'a pas
/// besoin d'être annoncée. Les trois cas restants demandent trois réactions
/// opposées, et l'écran ne disait rien qui permette de choisir.
String? _messageIllustrations(IllustrationReport? rapport) {
  if (rapport == null) return null;
  if (rapport.publiees > 0) return null;

  if (rapport.pagesEnEchec > 0) {
    return 'La recherche de photos a échoué sur ${rapport.pagesEnEchec} page(s). '
        'Ce n\'est pas la page qui est en cause : réessayez, ou ajoutez la '
        'photo à la main.';
  }
  if (rapport.detectees > 0) {
    // Le seul message qui compte désormais : il y en a, et c'est à vous.
    //
    // L'extraction automatique a été retirée — elle enchaînait découpage,
    // filtres, perspective et modération pour rendre des images que personne
    // ne gardait. Repérer, en revanche, vaut son appel : sans cette ligne, une
    // recette part sans image et rien ne dit qu'il y en avait une à prendre.
    final pluriel = rapport.detectees > 1;
    final s = pluriel ? 's' : '';
    return '${rapport.detectees} photo$s repérée$s sur cette page — '
        'à extraire à la main depuis l\'onglet Photos.';
  }
  return 'Aucune photo repérée sur cette page. Si le livre en porte une, '
      'ajoutez-la à la main depuis l\'onglet Photos.';
}

/// Combien d'ingrédients portent réellement une précision du livre.
///
/// Une ligne de constat, pas de diagnostic. Elle lit le document affiché et
/// rend trois nombres — c'est tout ce qu'il fallait pour trancher une question
/// qui a occupé trois versions : la note manque-t-elle parce qu'elle n'a pas
/// été écrite, ou parce qu'elle n'est pas montrée ?
class _LigneDonnee extends StatelessWidget {
  const _LigneDonnee({
    required this.avecNote,
    required this.avecSource,
    required this.total,
  });

  final int avecNote;
  final int avecSource;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (total == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        'Sur $total ingrédient${total > 1 ? "s" : ""} : '
        '$avecNote avec une précision du livre, '
        '$avecSource avec la ligne d\'origine.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Titre du bandeau : la nature de l'écart, et combien de points il faut voir.
///
/// « Écart constaté » seul ne distingue pas un titre de section raccourci —
/// qu'on peut ignorer — d'une recette amputée. Le nombre décide si l'on ouvre,
/// et permet de laisser le détail replié sans le perdre.
String _titre({
  required bool sansEcartDeTexte,
  required bool rupture,
  required int points,
}) {
  if (sansEcartDeTexte) return 'À propos des photos de cette page';
  final pluriel = points > 1 ? 's' : '';
  final suffixe = points > 0 ? ' · $points point$pluriel' : '';
  return rupture
      ? 'Texte du livre conservé, sans balise$suffixe'
      : 'Écart constaté avec la page du livre$suffixe';
}
