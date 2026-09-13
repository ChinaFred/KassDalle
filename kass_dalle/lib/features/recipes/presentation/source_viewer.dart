import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/utils/web_download.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/theme/app_icon_size.dart';

/// Bouton + visionneuse pour le fichier source (image ou PDF) d'une recette.
///
/// - Si c'est une image (jpg/png) : affiche une dialog plein écran zoomable.
/// - Sinon (PDF, DOCX, …) : ouvre dans le navigateur via url_launcher.
/// - Si [additionalSourceFileUrls] est fourni, un bouton par page supplémentaire.
class SourceViewerButton extends StatelessWidget {
  final String? sourceFileUrl;
  final String? sourceFileName;
  final List<String> additionalSourceFileUrls;

  const SourceViewerButton({
    super.key,
    required this.sourceFileUrl,
    required this.sourceFileName,
    this.additionalSourceFileUrls = const [],
  });

  @override
  Widget build(BuildContext context) {
    if (sourceFileUrl == null || sourceFileUrl!.isEmpty) {
      return const SizedBox.shrink();
    }
    final allUrls = [sourceFileUrl!, ...additionalSourceFileUrls];
    final isMultiPage = allUrls.length > 1;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isMultiPage)
          // Bouton unique qui ouvre un menu listant toutes les pages.
          // Le compteur est une information, pas une alerte : il prend la
          // couleur primaire et non le rouge par défaut de `Badge`, réservé
          // dans l'application aux éléments en attente d'une action.
          IconButton(
            icon: Badge(
              label: Text('${allUrls.length}'),
              backgroundColor: colorScheme.primary,
              textColor: colorScheme.onPrimary,
              child: const Icon(Icons.document_scanner_outlined),
            ),
            tooltip: 'Voir les ${allUrls.length} pages originales',
            onPressed: () => _showPagePicker(context, allUrls),
          )
        else ...[
          IconButton(
            icon: const Icon(Icons.document_scanner_outlined),
            tooltip: 'Voir le document original',
            onPressed: () => _open(context, sourceFileUrl!),
          ),
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: 'Télécharger le document original',
            onPressed: () => _download(context, sourceFileUrl!),
          ),
        ],
      ],
    );
  }

  void _showPagePicker(BuildContext context, List<String> urls) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Pages originales',
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
            ),
            for (var i = 0; i < urls.length; i++)
              ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(
                  i == 0 ? (sourceFileName ?? 'Page 1') : 'Page ${i + 1}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility_outlined),
                      tooltip: 'Voir cette page',
                      onPressed: () {
                        Navigator.pop(ctx);
                        _open(context, urls[i]);
                      },
                    ),
                    IconButton(
                      tooltip: 'Télécharger cette page',
                      icon: const Icon(Icons.download_outlined),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _download(context, urls[i]);
                      },
                    ),
                  ],
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _open(context, urls[i]);
                },
              ),
          ],
        ),
      ),
    );
  }

  bool _isImage(String url) {
    final lower = (sourceFileName ?? url).toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  void _open(BuildContext context, String url) {
    if (_isImage(url)) {
      _showImageDialog(context, url);
    } else {
      _launchUrl(context, url);
    }
  }

  void _showImageDialog(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(sourceFileName ?? 'Document original'),
            leading: const CloseButton(),
            actions: [
              IconButton(
                icon: const Icon(Icons.download_outlined),
                tooltip: 'Télécharger',
                onPressed: () => _download(context, url),
              ),
            ],
          ),
          body: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                placeholder: (_, _) =>
                    const Center(child: CircularProgressIndicator()),
                errorWidget: (_, _, _) => const Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    size: AppIconSize.hero,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.platformDefault)) {
      if (context.mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir le document.');
      }
    }
  }

  Future<void> _download(BuildContext context, String url) async {
    if (kIsWeb) {
      final filename = filenameFromStorageUrl(
        url,
        fallback: sourceFileName ?? 'document',
      );
      final ok = await triggerWebDownload(url, filename);
      if (ok) return;
    }
    // Fallback mobile/desktop ou si le blob a échoué
    if (!context.mounted) return;
    await _launchUrl(context, url);
  }
}
