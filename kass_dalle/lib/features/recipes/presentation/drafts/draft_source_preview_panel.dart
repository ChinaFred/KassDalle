
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../source_viewer.dart';

/// Panneau d'aperçu du fichier source d'un brouillon.
///
/// Extrait de draft_review_widgets.dart.

class DraftSourcePreviewPanel extends StatefulWidget {
  final String? sourceFileUrl;
  final String? sourceFileName;
  final List<String> additionalSourceFileUrls;

  const DraftSourcePreviewPanel({
    super.key,
    required this.sourceFileUrl,
    required this.sourceFileName,
    this.additionalSourceFileUrls = const [],
  });

  @override
  State<DraftSourcePreviewPanel> createState() =>
      _DraftSourcePreviewPanelState();
}

class _DraftSourcePreviewPanelState extends State<DraftSourcePreviewPanel> {
  final _pageCtrl = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  bool _isImageUrl(String url, {String? fileName}) {
    final lower = (fileName ?? url).toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sourceFileUrl == null) return const SizedBox.shrink();

    final allUrls = [widget.sourceFileUrl!, ...widget.additionalSourceFileUrls];

    // ── Single page ──────────────────────────────────────────────────────────
    if (allUrls.length == 1) {
      if (_isImageUrl(widget.sourceFileUrl!, fileName: widget.sourceFileName)) {
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Center(
            child: CachedNetworkImage(
              imageUrl: widget.sourceFileUrl!,
              fit: BoxFit.contain,
              placeholder: (_, _) =>
                  const Center(child: CircularProgressIndicator()),
              errorWidget: (_, _, _) =>
                  const Center(child: Icon(Icons.broken_image, size: 64)),
            ),
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.picture_as_pdf, size: 64),
            const SizedBox(height: 16),
            Text(widget.sourceFileName ?? 'Document source'),
            const SizedBox(height: 16),
            SourceViewerButton(
              sourceFileUrl: widget.sourceFileUrl,
              sourceFileName: widget.sourceFileName,
            ),
          ],
        ),
      );
    }

    // ── Multi-page : PageView avec indicateur ────────────────────────────────
    return Stack(
      children: [
        PageView.builder(
          controller: _pageCtrl,
          onPageChanged: (i) => setState(() => _currentPage = i),
          itemCount: allUrls.length,
          itemBuilder: (ctx, i) {
            final url = allUrls[i];
            final fileName = i == 0 ? widget.sourceFileName : null;
            if (_isImageUrl(url, fileName: fileName)) {
              return InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: url,
                    fit: BoxFit.contain,
                    placeholder: (_, _) =>
                        const Center(child: CircularProgressIndicator()),
                    errorWidget: (_, _, _) =>
                        const Center(child: Icon(Icons.broken_image, size: 64)),
                  ),
                ),
              );
            }
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.picture_as_pdf, size: 64),
                  const SizedBox(height: 16),
                  Text(fileName ?? 'Page ${i + 1}'),
                  const SizedBox(height: 16),
                  SourceViewerButton(
                    sourceFileUrl: url,
                    sourceFileName: fileName,
                  ),
                ],
              ),
            );
          },
        ),
        // Indicateur de page
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_left,
                      color: Colors.white,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _currentPage > 0
                        ? () => _pageCtrl.previousPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                          )
                        : null,
                  ),
                  Text(
                    'Page ${_currentPage + 1} / ${allUrls.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_right,
                      color: Colors.white,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _currentPage < allUrls.length - 1
                        ? () => _pageCtrl.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

