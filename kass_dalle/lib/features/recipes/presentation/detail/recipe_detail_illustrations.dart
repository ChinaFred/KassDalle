import 'package:flutter/material.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/widgets/app_network_image.dart';

// ── Visionneuse illustrations plein écran ─────────────────────────────────

class IllustrationGallery extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;

  const IllustrationGallery({
    super.key,
    required this.urls,
    required this.initialIndex,
  });

  @override
  State<IllustrationGallery> createState() => _IllustrationGalleryState();
}

class _IllustrationGalleryState extends State<IllustrationGallery> {
  late PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 0.5,
              maxScale: 6,
              child: AppNetworkImage(
                imageUrl: widget.urls[i],
                fit: BoxFit.contain,
                placeholder: (_, _) => const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
                errorWidget: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  size: AppIconSize.hero,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
          // Compteur
          if (widget.urls.length > 1)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${_current + 1} / ${widget.urls.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          // Flèches.
          //
          // Elles restent en place aux extrémités, désactivées, au lieu de
          // disparaître : sinon la première image n'a pas de flèche gauche, la
          // droite s'efface sur la dernière, et la cible se déplace sous le
          // doigt pendant qu'on feuillette. C'est déjà ainsi que le lecteur de
          // livre traite « Début du livre » et « Fin du livre ».
          if (widget.urls.length > 1) ...[
            Positioned(
              left: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filled(
                  icon: const Icon(Icons.chevron_left),
                  tooltip: 'Illustration précédente',
                  onPressed: _current > 0
                      ? () => _pageCtrl.previousPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        )
                      : null,
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 0,
              bottom: 0,
              child: Center(
                child: IconButton.filled(
                  icon: const Icon(Icons.chevron_right),
                  tooltip: 'Illustration suivante',
                  onPressed: _current < widget.urls.length - 1
                      ? () => _pageCtrl.nextPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOut,
                        )
                      : null,
                ),
              ),
            ),
          ],
          // Fermer
          Positioned(
            top: 16,
            right: 16,
            child: IconButton.filled(
              tooltip: 'Fermer',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
