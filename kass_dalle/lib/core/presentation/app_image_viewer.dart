import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/error_reporting.dart';
import '../theme/app_theme.dart';
import '../utils/app_image_url.dart';
import '../widgets/app_network_image.dart';
import '../widgets/app_states.dart';

/// Une image montrée par [showAppImageViewer] : une URL de Kass'Dalle, ou des
/// octets déjà lus (la capture d'un ticket, lue par son chemin Storage).
@immutable
class AppViewerImage {
  /// URL de l'image. Une URL refusée par `isAppImageUrl` n'est jamais
  /// chargée : la visionneuse affiche « Image indisponible. ».
  final String? url;

  /// Octets de l'image.
  final Uint8List? bytes;

  /// Ce que lit le lecteur d'écran sur l'image.
  final String? semanticLabel;

  const AppViewerImage.network(String this.url, {this.semanticLabel})
    : bytes = null;

  const AppViewerImage.memory(Uint8List this.bytes, {this.semanticLabel})
    : url = null;
}

/// Titre de l'état d'erreur d'une image.
const kAppImageViewerErrorTitle = 'Image indisponible.';

/// Libellé de l'attente d'une image.
const kAppImageViewerLoadingLabel = 'Chargement de l\'image…';

/// Zoom d'un double appui.
const double kAppImageViewerDoubleTapScale = 2.5;

/// Bornes du zoom.
const double kAppImageViewerMinScale = 1;
const double kAppImageViewerMaxScale = 6;

/// La visionneuse plein écran commune à toute l'application.
///
/// Toujours en thème sombre, quel que soit le thème choisi : une image se lit
/// mieux sur un fond sombre. « Fermer » à gauche de la barre, le [title] au
/// centre avec « 2 / 5 » quand il y a plusieurs images, les [actions] à
/// droite (Télécharger pour le document original).
///
/// Zoom de 1 à 6 : pincement, molette (web et desktop), double appui
/// (1× ↔ 2,5× sur le point touché). Plusieurs images : glissement, flèches à
/// l'écran (désactivées aux extrémités), touches ← et →. Tant que l'image est
/// zoomée, le glissement déplace l'image au lieu de changer de page ; le zoom
/// revient à 1 à chaque changement d'image. Échap ferme.
///
/// [itemLabel] est un nom féminin : « Illustration précédente »,
/// « Illustration 2 sur 5 ».
Future<void> showAppImageViewer(
  BuildContext context, {
  required List<AppViewerImage> images,
  int initialIndex = 0,
  String? title,
  String itemLabel = 'Image',
  List<Widget> actions = const [],
}) {
  assert(images.isNotEmpty, 'showAppImageViewer sans image');
  if (images.isEmpty) return Future<void>.value();
  final start = initialIndex.clamp(0, images.length - 1);
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => Theme(
      data: AppTheme.dark,
      child: AppImageViewer(
        images: images,
        initialIndex: start,
        title: title,
        itemLabel: itemLabel,
        actions: actions,
      ),
    ),
  );
}

/// Le contenu de la visionneuse. Ouvrir par [showAppImageViewer], qui pose le
/// thème sombre et la route du dialogue.
class AppImageViewer extends StatefulWidget {
  final List<AppViewerImage> images;
  final int initialIndex;
  final String? title;
  final String itemLabel;
  final List<Widget> actions;

  const AppImageViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.title,
    this.itemLabel = 'Image',
    this.actions = const [],
  });

  @override
  State<AppImageViewer> createState() => _AppImageViewerState();
}

class _AppImageViewerState extends State<AppImageViewer> {
  static const _pageDuration = Duration(milliseconds: 250);

  late final PageController _pageCtrl;
  late final List<TransformationController> _zoomCtrls;
  late int _current;
  bool _zoomed = false;

  int get _count => widget.images.length;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
    _zoomCtrls = List.generate(_count, (_) {
      final ctrl = TransformationController();
      ctrl.addListener(_onZoomChanged);
      return ctrl;
    });
  }

  @override
  void dispose() {
    for (final ctrl in _zoomCtrls) {
      ctrl.removeListener(_onZoomChanged);
      ctrl.dispose();
    }
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onZoomChanged() {
    final zoomed = _zoomCtrls[_current].value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onPageChanged(int index) {
    // Le zoom revient à 1 sur toutes les images : celle qu'on quitte comme
    // celle qu'on retrouve.
    for (final ctrl in _zoomCtrls) {
      if (ctrl.value != Matrix4.identity()) ctrl.value = Matrix4.identity();
    }
    setState(() {
      _current = index;
      _zoomed = false;
    });
  }

  void _previous() {
    if (_current <= 0) return;
    _pageCtrl.previousPage(duration: _pageDuration, curve: Curves.easeInOut);
  }

  void _next() {
    if (_current >= _count - 1) return;
    _pageCtrl.nextPage(duration: _pageDuration, curve: Curves.easeInOut);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final multiple = _count > 1;
    final title = widget.title;
    final position = '${_current + 1} / $_count';

    final Widget? titleWidget = (title == null && !multiple)
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              if (multiple)
                Semantics(
                  container: true,
                  label: '${widget.itemLabel} ${_current + 1} sur $_count',
                  liveRegion: true,
                  child: ExcludeSemantics(
                    child: Text(
                      position,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          );

    return Dialog.fullscreen(
      backgroundColor: cs.surfaceContainerLowest,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _previous,
          const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: cs.surfaceContainerLowest,
            appBar: AppBar(
              leading: const CloseButton(),
              centerTitle: true,
              title: titleWidget,
              actions: widget.actions,
            ),
            body: SafeArea(
              top: false,
              child: Stack(
                children: [
                  PageView.builder(
                    controller: _pageCtrl,
                    itemCount: _count,
                    // Zoomée, l'image se déplace sous le doigt : le
                    // glissement ne change pas de page.
                    physics: _zoomed
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    onPageChanged: _onPageChanged,
                    itemBuilder: (_, i) => _ViewerPage(
                      image: widget.images[i],
                      controller: _zoomCtrls[i],
                      index: i,
                    ),
                  ),
                  // Les flèches restent en place aux extrémités, désactivées :
                  // la cible ne se déplace pas sous le doigt pendant qu'on
                  // feuillette.
                  if (multiple) ...[
                    Positioned(
                      left: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: IconButton.filledTonal(
                          icon: const Icon(Icons.chevron_left),
                          tooltip: '${widget.itemLabel} précédente',
                          onPressed: _current > 0 ? _previous : null,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 8,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: IconButton.filledTonal(
                          icon: const Icon(Icons.chevron_right),
                          tooltip: '${widget.itemLabel} suivante',
                          onPressed: _current < _count - 1 ? _next : null,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Une image de la visionneuse : zoom, double appui, chargement et erreur.
class _ViewerPage extends StatefulWidget {
  final AppViewerImage image;
  final TransformationController controller;
  final int index;

  const _ViewerPage({
    required this.image,
    required this.controller,
    required this.index,
  });

  @override
  State<_ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<_ViewerPage> {
  Offset _doubleTapAt = Offset.zero;

  /// Incrémenté par « Réessayer » : la clé change, l'image se recharge.
  int _attempt = 0;

  void _toggleZoom() {
    final ctrl = widget.controller;
    if (ctrl.value.getMaxScaleOnAxis() > 1.01) {
      ctrl.value = Matrix4.identity();
      return;
    }
    const s = kAppImageViewerDoubleTapScale;
    // Le point touché reste sous le doigt : translation de -p × (s - 1).
    ctrl.value = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(
        -_doubleTapAt.dx * (s - 1),
        -_doubleTapAt.dy * (s - 1),
        0,
      );
  }

  Future<void> _retry(String url) async {
    try {
      await CachedNetworkImage.evictFromCache(url);
    } catch (e, stackTrace) {
      // Le cache n'a pas été vidé : on recharge quand même, l'image peut
      // revenir du réseau.
      reportUnexpectedError(
        feature: 'appImageViewer.retry',
        error: e,
        stackTrace: stackTrace,
        context: {'index': widget.index},
      );
    }
    if (!mounted) return;
    setState(() => _attempt++);
  }

  Widget _unavailable(Object error, String advice) => AppErrorState(
    error: error,
    title: kAppImageViewerErrorTitle,
    advice: advice,
  );

  Widget _buildImage() {
    final image = widget.image;
    final bytes = image.bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: BoxFit.contain,
        semanticLabel: image.semanticLabel,
        // Des octets illisibles ne se rechargent pas : aucun bouton.
        errorBuilder: (_, error, _) =>
            _unavailable(error, 'Le fichier de l\'image est illisible.'),
      );
    }
    final url = image.url ?? '';
    if (!isAppImageUrl(url)) {
      return _unavailable(
        ForeignImageUrl(url),
        'Cette image ne vient pas de Kass\'Dalle : elle n\'est pas affichée.',
      );
    }
    return Semantics(
      image: true,
      label: image.semanticLabel,
      child: AppNetworkImage(
        key: ValueKey('$url#$_attempt'),
        imageUrl: url,
        fit: BoxFit.contain,
        placeholder: (_, _) =>
            const AppLoadingState(label: kAppImageViewerLoadingLabel),
        errorWidget: (_, _, error) => AppErrorState(
          error: error,
          title: kAppImageViewerErrorTitle,
          onRetry: () => _retry(url),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: widget.controller,
        minScale: kAppImageViewerMinScale,
        maxScale: kAppImageViewerMaxScale,
        child: SizedBox.expand(child: Center(child: _buildImage())),
      ),
    );
  }
}
