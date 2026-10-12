import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/services/error_reporting.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../domain/url_import.dart';

/// Ouvre une page web dans le navigateur, ou le dit si c'est impossible.
///
/// Commun au lien « Source » de la fiche et à l'action « Ouvrir la page » de
/// la file de travail. Une exception est rapportée (`reportUnexpectedError`).
Future<void> openExternalPage(
  BuildContext context,
  String url, {
  required String feature,
}) async {
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } catch (error, stackTrace) {
    reportUnexpectedError(
      feature: feature,
      error: error,
      stackTrace: stackTrace,
      context: {'url': url},
    );
  }
  if (!opened && context.mounted) {
    context.showErrorSnackBar('Impossible d\'ouvrir la page.');
  }
}

/// La page web d'où vient une recette : le nom du site en lien, et l'adresse
/// complète, sélectionnable et copiable.
///
/// Sur la fiche d'une recette importée depuis un lien (« Source : »), et en
/// rappel en haut de la saisie quand un import par lien a échoué (« Page à
/// recopier : »). Rien n'est affiché si l'adresse n'est pas un lien web.
///
/// [site] est le nom écrit par le serveur (`source_site`). Sans lui — le rappel
/// de la saisie n'a que l'adresse —, le lien porte l'hôte de l'adresse.
///
/// [author] est l'auteur annoncé par la page (`source_author`). Présent, il
/// s'affiche sur une ligne « Par … » au-dessus du lien, sauf quand il répète
/// le nom du site (un site qui se déclare lui-même auteur).
class RecipeSourceLink extends StatelessWidget {
  const RecipeSourceLink({
    super.key,
    required this.url,
    this.site,
    this.author,
    this.prefix = 'Source : ',
    this.compact = false,
  });

  final String url;
  final String? site;
  final String? author;
  final String prefix;

  /// Une seule ligne (lien + copier), sans l'adresse complète : pour les
  /// écrans étroits où la place manque, comme la saisie manuelle.
  final bool compact;

  /// « Marmiton » face à « marmiton.org » : le même nom, sans casse, sans
  /// `www.` et sans l'extension du domaine.
  static bool _sameAsSite(String author, String site) {
    String key(String s) => s
        .toLowerCase()
        .replaceFirst(RegExp(r'^www\.'), '')
        .replaceFirst(RegExp(r'\.[a-z]{2,}$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]'), '');
    return key(author) == key(site);
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) context.showSuccessSnackBar('Adresse copiée');
  }

  @override
  Widget build(BuildContext context) {
    if (!looksLikeWebLink(url)) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final label = (site ?? '').isNotEmpty ? site! : Uri.parse(url.trim()).host;
    final authorName = (author ?? '').trim();
    final showAuthor = authorName.isNotEmpty && !_sameAsSite(authorName, label);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Pas de coupe : le serveur borne déjà le nom à 120 caractères.
          if (showAuthor)
            Text('Par $authorName', style: theme.textTheme.bodyMedium),
          Row(
            children: [
              Text(prefix, style: theme.textTheme.bodyMedium),
              Flexible(
                child: Semantics(
                  link: true,
                  label: 'Ouvrir la page d\'origine : $label',
                  excludeSemantics: true,
                  child: Tooltip(
                    message: 'Ouvrir la page d\'origine',
                    child: InkWell(
                      onTap: () => openExternalPage(
                        context,
                        url,
                        feature: 'recipeSourceLink.open',
                      ),
                      child: ConstrainedBox(
                        // Cible tactile de 48 px de haut, comme un bouton.
                        constraints: const BoxConstraints(minHeight: 48),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                label,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.primary,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              Icons.open_in_new,
                              size: AppIconSize.inline,
                              color: theme.colorScheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (compact)
                IconButton(
                  tooltip: 'Copier l\'adresse',
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_outlined),
                ),
            ],
          ),
          if (!compact)
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    url,
                    maxLines: 2,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copier l\'adresse',
                  onPressed: () => _copy(context),
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
