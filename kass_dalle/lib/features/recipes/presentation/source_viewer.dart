import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Bouton + visionneuse pour le fichier source (image ou PDF) d'une recette.
///
/// - Si c'est une image (jpg/png) : affiche une dialog plein écran zoomable.
/// - Sinon (PDF, DOCX, …) : ouvre dans le navigateur via url_launcher.
class SourceViewerButton extends StatelessWidget {
  final String? sourceFileUrl;
  final String? sourceFileName;

  const SourceViewerButton({
    super.key,
    required this.sourceFileUrl,
    required this.sourceFileName,
  });

  @override
  Widget build(BuildContext context) {
    if (sourceFileUrl == null || sourceFileUrl!.isEmpty) {
      return const SizedBox.shrink();
    }
    return IconButton(
      icon: const Icon(Icons.document_scanner_outlined),
      tooltip: 'Voir le document original',
      onPressed: () => _open(context),
    );
  }

  bool get _isImage {
    final lower = (sourceFileName ?? sourceFileUrl ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  void _open(BuildContext context) {
    if (_isImage) {
      _showImageDialog(context);
    } else {
      _launchUrl(context);
    }
  }

  void _showImageDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog.fullscreen(
        child: Scaffold(
          appBar: AppBar(
            title: Text(sourceFileName ?? 'Document original'),
            leading: const CloseButton(),
          ),
          body: InteractiveViewer(
            minScale: 0.5,
            maxScale: 5,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: sourceFileUrl!,
                fit: BoxFit.contain,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator()),
                errorWidget: (_, __, ___) =>
                    const Center(child: Icon(Icons.broken_image, size: 64)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _launchUrl(BuildContext context) async {
    final uri = Uri.parse(sourceFileUrl!);
    if (!await launchUrl(uri, mode: LaunchMode.platformDefault)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d\'ouvrir le document.')),
        );
      }
    }
  }
}
