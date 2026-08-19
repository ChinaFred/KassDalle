import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'image_enhancer_processing.dart';
import '../../core/services/error_reporting.dart';
import '../utils/context_extensions.dart';
import '../theme/app_icon_size.dart';

/// Mode de l'écran améliorateur :
/// - [crop]  : ajustement des coins + correction de perspective
/// - [color] : ajustement luminosité / netteté sans recadrage
/// - [studio] : atelier unifié (cadre + lumière + détails + presets)
enum EnhancerMode { crop, color, studio }

enum _EnhancerPanel { frame, light, details, presets }

class _EnhancerSnapshot {
  final Uint8List bytes;
  final List<Offset> corners;
  final double brightness;
  final double contrast;
  final double saturation;
  final bool sharpen;

  const _EnhancerSnapshot({
    required this.bytes,
    required this.corners,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.sharpen,
  });
}

/// Écran de correction de perspective et d'amélioration d'image.
///
/// L'utilisateur positionne les 4 coins blancs sur les 4 coins de la page,
/// puis l'app calcule l'homographie et restitue l'image aplanie.
///
/// Retourne via [Navigator.pop] les bytes JPEG résultants, ou `null` si annulation.
class ImageEnhancerScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final String title;
  final EnhancerMode mode;

  /// Callback alternatif à [Navigator.pop] pour les cas où l'écran
  /// est intégré en Stack (sans route). Appelé avec `null` en cas d'annulation.
  /// Peut être async : [ImageEnhancerScreen] attend la fin avant de fermer.
  final Future<void> Function(Uint8List?)? onResult;

  const ImageEnhancerScreen({
    super.key,
    required this.imageBytes,
    this.title = 'Recadrer / améliorer',
    this.mode = EnhancerMode.studio,
    this.onResult,
  });

  @override
  State<ImageEnhancerScreen> createState() => _ImageEnhancerScreenState();
}

class _ImageEnhancerScreenState extends State<ImageEnhancerScreen> {
  ui.Image? _uiImage;
  int _imgW = 1, _imgH = 1;

  // Bytes courants (peut différer de widget.imageBytes après rotation)
  late Uint8List _currentBytes;
  bool _rotating = false;

  // 4 coins normalisés [0..1] : TL, TR, BR, BL (sens horaire)
  final List<Offset> _corners = [
    const Offset(0.05, 0.05),
    const Offset(0.95, 0.05),
    const Offset(0.95, 0.95),
    const Offset(0.05, 0.95),
  ];

  int? _activeCorner;
  Offset? _loupePos;

  double _brightness = 1.0;
  double _contrast = 1.0;
  double _saturation = 1.0;
  bool _sharpen = false;
  bool _processing = false;
  String _processingMessage = 'Correction en cours…';
  bool _detecting = false;
  bool _showOriginalPreview = false;
  _EnhancerPanel _activePanel = _EnhancerPanel.frame;
  String? _suggestedPreset;
  bool _adjustingSlider = false;

  final List<_EnhancerSnapshot> _undoStack = [];
  final List<_EnhancerSnapshot> _redoStack = [];

  // Zoom / pan du canvas
  Matrix4 _viewTransform = Matrix4.identity();
  bool _panning = false;

  bool get _allowCrop =>
      widget.mode == EnhancerMode.crop || widget.mode == EnhancerMode.studio;

  bool get _allowColor =>
      widget.mode == EnhancerMode.color || widget.mode == EnhancerMode.studio;

  @override
  void initState() {
    super.initState();
    _currentBytes = widget.imageBytes;
    if (!_allowCrop) {
      // Mode couleur : coins fixes sur toute l'image, pas de recadrage
      _corners[0] = const Offset(0.0, 0.0);
      _corners[1] = const Offset(1.0, 0.0);
      _corners[2] = const Offset(1.0, 1.0);
      _corners[3] = const Offset(0.0, 1.0);
    }
    if (widget.mode == EnhancerMode.color) {
      _activePanel = _EnhancerPanel.light;
    } else if (widget.mode == EnhancerMode.studio) {
      // Le recadrage doit être visible immédiatement en mode studio.
      _activePanel = _EnhancerPanel.frame;
    }
    _loadUiImage();
  }

  Future<void> _loadUiImage() async {
    final codec = await ui.instantiateImageCodec(_currentBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _uiImage = frame.image;
      _imgW = frame.image.width;
      _imgH = frame.image.height;
    });
    _suggestPreset();
    _runAutoDetect();
  }

  Future<void> _runAutoDetect() async {
    if (!mounted || !_allowCrop) return;
    setState(() => _detecting = true);
    try {
      final corners = await compute(
        detectCornersIsolate,
        DetectParams(imageBytes: _currentBytes),
      );
      // Ne pas écraser les coins si l'utilisateur a déjà déclenché le recadrage.
      if (mounted && corners != null && !_processing) {
        // Validation : le quad doit couvrir ≥ 35 % de l'image.
        // Les vignettes déjà recadrées produisent des faux positifs
        // dont les intersections convergent vers le centre → ignorées.
        final detected = List.generate(
          4,
          (i) => Offset(corners[i * 2], corners[i * 2 + 1]),
        );
        if (_quadArea(detected) >= 0.35) {
          setState(() {
            for (var i = 0; i < 4; i++) {
              _corners[i] = Offset(
                corners[i * 2].clamp(0.01, 0.99),
                corners[i * 2 + 1].clamp(0.01, 0.99),
              );
            }
          });
        }
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'imageEnhancerScreen.runAutoDetect',
        error: error,
        stackTrace: stackTrace,
      );
      // Silently keep default corners
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
  }

  /// Aire du quadrilatère normalisée (formule de Gauss), [0 … 1].
  double _quadArea(List<Offset> pts) {
    double s = 0;
    for (int i = 0; i < 4; i++) {
      final j = (i + 1) % 4;
      s += pts[i].dx * pts[j].dy - pts[j].dx * pts[i].dy;
    }
    return s.abs() / 2;
  }

  // ── Geometry ───────────────────────────────────────────────────────────────

  Rect _fittedRect(Size container) {
    final scaleX = container.width / _imgW;
    final scaleY = container.height / _imgH;
    final scale = math.min(scaleX, scaleY);
    final w = _imgW * scale;
    final h = _imgH * scale;
    return Rect.fromLTWH(
      (container.width - w) / 2,
      (container.height - h) / 2,
      w,
      h,
    );
  }

  Offset _normToWidget(Offset norm, Rect fitted) => Offset(
    fitted.left + norm.dx * fitted.width,
    fitted.top + norm.dy * fitted.height,
  );

  Offset _widgetToNorm(Offset w, Rect fitted) => Offset(
    ((w.dx - fitted.left) / fitted.width).clamp(0.0, 1.0),
    ((w.dy - fitted.top) / fitted.height).clamp(0.0, 1.0),
  );

  // ── Gestures ───────────────────────────────────────────────────────────────

  void _onPanStart(DragStartDetails d, Rect fitted) {
    if (!_allowCrop) return;
    const hitRadius = 60.0;
    int? closest;
    double minDist = hitRadius;
    for (int i = 0; i < 4; i++) {
      final dist =
          (d.localPosition - _normToWidget(_corners[i], fitted)).distance;
      if (dist < minDist) {
        minDist = dist;
        closest = i;
      }
    }
    if (closest != null) {
      setState(() {
        _pushHistory();
        _activeCorner = closest;
        _loupePos = d.localPosition;
        _panning = false;
      });
    } else if (_viewTransform.getMaxScaleOnAxis() > 1.01) {
      setState(() => _panning = true);
    }
  }

  void _onPanUpdate(DragUpdateDetails d, Rect fitted) {
    if (_activeCorner != null) {
      setState(() {
        _corners[_activeCorner!] = _widgetToNorm(d.localPosition, fitted);
        _loupePos = d.localPosition;
      });
    } else if (_panning) {
      final scale = _viewTransform.getMaxScaleOnAxis();
      final t = Matrix4.identity()
        ..translateByDouble(d.delta.dx * scale, d.delta.dy * scale, 0, 1);
      setState(() => _viewTransform = t * _viewTransform);
    }
  }

  void _onPanEnd(DragEndDetails _) => setState(() {
    _activeCorner = null;
    _loupePos = null;
    _panning = false;
    _suggestedPreset = null;
  });

  _EnhancerSnapshot _snapshot() => _EnhancerSnapshot(
    bytes: Uint8List.fromList(_currentBytes),
    corners: _corners.map((c) => Offset(c.dx, c.dy)).toList(),
    brightness: _brightness,
    contrast: _contrast,
    saturation: _saturation,
    sharpen: _sharpen,
  );

  void _pushHistory() {
    _undoStack.add(_snapshot());
    if (_undoStack.length > 40) {
      _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  Future<void> _restoreSnapshot(_EnhancerSnapshot s) async {
    final codec = await ui.instantiateImageCodec(s.bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _currentBytes = s.bytes;
      _uiImage = frame.image;
      _imgW = frame.image.width;
      _imgH = frame.image.height;
      for (var i = 0; i < 4; i++) {
        _corners[i] = s.corners[i];
      }
      _brightness = s.brightness;
      _contrast = s.contrast;
      _saturation = s.saturation;
      _sharpen = s.sharpen;
    });
  }

  Future<void> _undo() async {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_snapshot());
    final prev = _undoStack.removeLast();
    await _restoreSnapshot(prev);
  }

  Future<void> _redo() async {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_snapshot());
    final next = _redoStack.removeLast();
    await _restoreSnapshot(next);
  }

  void _beginSliderAdjustment() {
    if (_adjustingSlider) return;
    _adjustingSlider = true;
    _pushHistory();
  }

  void _endSliderAdjustment(double _) {
    _adjustingSlider = false;
    setState(() => _suggestedPreset = null);
  }

  Future<void> _suggestPreset() async {
    if (!_allowColor) return;
    try {
      final stats = await compute(analyzeImageStatsIsolate, _currentBytes);
      if (!mounted) return;
      String suggested;
      if (stats.meanLuma < 0.45) {
        suggested = 'lisibilite';
      } else if (stats.lumaStdDev < 0.12) {
        suggested = 'pop';
      } else {
        suggested = 'naturel';
      }
      setState(() => _suggestedPreset = suggested);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'imageEnhancerScreen.suggestPreset',
        error: error,
        stackTrace: stackTrace,
      );
      // Keep presets manual when analysis fails.
    }
  }

  void _applyPreset(String id) {
    if (!_allowColor) return;
    _pushHistory();
    setState(() {
      switch (id) {
        case 'lisibilite':
          _brightness = 1.10;
          _contrast = 1.18;
          _saturation = 0.92;
          _sharpen = true;
          break;
        case 'pop':
          _brightness = 1.04;
          _contrast = 1.15;
          _saturation = 1.18;
          _sharpen = false;
          break;
        case 'doux':
          _brightness = 1.02;
          _contrast = 0.94;
          _saturation = 0.96;
          _sharpen = false;
          break;
        default:
          _brightness = 1.0;
          _contrast = 1.0;
          _saturation = 1.0;
          _sharpen = false;
      }
      _suggestedPreset = id;
    });
  }

  List<double> _previewColorMatrix() {
    final sat = _saturation;
    final invSat = 1 - sat;
    final ir = 0.213 * invSat;
    final ig = 0.715 * invSat;
    final ib = 0.072 * invSat;

    final c = _contrast;
    final t = (1 - c) * 128 + (_brightness - 1.0) * 255;

    return [
      (ir + sat) * c,
      ig * c,
      ib * c,
      0,
      t,
      ir * c,
      (ig + sat) * c,
      ib * c,
      0,
      t,
      ir * c,
      ig * c,
      (ib + sat) * c,
      0,
      t,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  void _handleCtrlScroll(PointerScrollEvent event) {
    final isCtrl =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!isCtrl) return;
    final scaleFactor = event.scrollDelta.dy < 0 ? 1.1 : 0.9;
    final currentScale = _viewTransform.getMaxScaleOnAxis();
    final newScale = (currentScale * scaleFactor).clamp(0.5, 5.0);
    final actualFactor = newScale / currentScale;
    if ((actualFactor - 1.0).abs() < 0.001) return;
    final focal = event.localPosition;
    final z = Matrix4.identity()
      ..translateByDouble(focal.dx, focal.dy, 0, 1)
      ..scaleByDouble(actualFactor, actualFactor, 1, 1)
      ..translateByDouble(-focal.dx, -focal.dy, 0, 1);
    setState(() => _viewTransform = z * _viewTransform);
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  void _cancel() {
    if (widget.onResult != null) {
      widget.onResult!(null);
    } else {
      Navigator.of(context).pop<Uint8List?>(null);
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _processing = true;
      _processingMessage = 'Correction en cours…';
    });

    Uint8List result;
    try {
      final params = WarpParams(
        imageBytes: _currentBytes,
        cornersFlat: _corners.expand((c) => [c.dx, c.dy]).toList(),
        brightness: _brightness,
        contrast: _contrast,
        saturation: _saturation,
        sharpen: _sharpen,
      );
      final warped = await compute(warpIsolate, params);
      result = await _nativeCompress(warped);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'imageEnhancerScreen.confirm',
        error: error,
        stackTrace: stackTrace,
      );
      // Fallback : utilise l'image actuelle sans correction de perspective
      result = _currentBytes;
    }

    if (!mounted) return;

    // Mise à jour du message pendant l'upload
    setState(() => _processingMessage = 'Envoi en cours…');

    if (widget.onResult != null) {
      await widget.onResult!(result);
    } else {
      Navigator.of(context).pop<Uint8List?>(result);
    }
  }

  // ── Compression native (flutter_image_compress) ────────────────────────────

  /// Recompresse les bytes JPEG avec le codec natif de la plateforme (qualité
  /// supérieure à la même taille que le codec Dart pur). Si le codec natif n'est
  /// pas disponible (plateforme non supportée), retourne les bytes inchangés.
  static Future<Uint8List> _nativeCompress(
    Uint8List bytes, {
    int quality = 88,
  }) async {
    try {
      final out = await FlutterImageCompress.compressWithList(
        bytes,
        quality: quality,
        format: CompressFormat.jpeg,
      );
      if (out.isNotEmpty) return out;
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'imageEnhancerScreen.nativeCompress',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return bytes;
  }

  // ── Rotation ───────────────────────────────────────────────────────────────

  Future<void> _rotate(bool clockwise) async {
    if (_rotating || _processing) return;
    setState(() => _rotating = true);
    try {
      final rotatedRaw = await compute(
        rotateIsolate,
        RotateParams(
          imageBytes: _currentBytes,
          angle: clockwise ? 90.0 : -90.0,
        ),
      );
      final rotated = await _nativeCompress(rotatedRaw, quality: 90);
      if (!mounted) return;
      final codec = await ui.instantiateImageCodec(rotated);
      final frame = await codec.getNextFrame();
      if (!mounted) return;
      _pushHistory();
      // Remapper les coins si mode recadrage
      if (_allowCrop) {
        final old = List<Offset>.from(_corners);
        if (clockwise) {
          // rotCW(x,y) = (1-y, x)  /  new[TL,TR,BR,BL] = [rotCW(BL), rotCW(TL), rotCW(TR), rotCW(BR)]
          _corners[0] = Offset(1 - old[3].dy, old[3].dx);
          _corners[1] = Offset(1 - old[0].dy, old[0].dx);
          _corners[2] = Offset(1 - old[1].dy, old[1].dx);
          _corners[3] = Offset(1 - old[2].dy, old[2].dx);
        } else {
          // rotCCW(x,y) = (y, 1-x)  /  new[TL,TR,BR,BL] = [rotCCW(TR), rotCCW(BR), rotCCW(BL), rotCCW(TL)]
          _corners[0] = Offset(old[1].dy, 1 - old[1].dx);
          _corners[1] = Offset(old[2].dy, 1 - old[2].dx);
          _corners[2] = Offset(old[3].dy, 1 - old[3].dx);
          _corners[3] = Offset(old[0].dy, 1 - old[0].dx);
        }
      }
      setState(() {
        _currentBytes = rotated;
        _uiImage = frame.image;
        _imgW = frame.image.width;
        _imgH = frame.image.height;
        _viewTransform = Matrix4.identity();
      });
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'imageEnhancerScreen.rotate',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur rotation : $e');
      }
    } finally {
      if (mounted) setState(() => _rotating = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title),
        leadingWidth: 90,
        leading: TextButton(
          onPressed: _processing ? null : _cancel,
          child: const Text('Annuler', style: TextStyle(color: Colors.white70)),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _processing ? null : _confirm,
              child: Text(
                widget.mode == EnhancerMode.crop
                    ? 'Recadrer'
                    : widget.mode == EnhancerMode.color
                    ? 'Enregistrer'
                    : 'Appliquer',
              ),
            ),
          ),
        ],
      ),
      body: _processing
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    _processingMessage,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            )
          : Column(
              children: [
                Expanded(child: _buildEditor()),
                _buildControls(theme),
              ],
            ),
    );
  }

  Widget _buildEditor() {
    if (_uiImage == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final fitted = _fittedRect(size);
        return Listener(
          onPointerSignal: (e) {
            if (e is PointerScrollEvent) _handleCtrlScroll(e);
          },
          child: Transform(
            transform: _viewTransform,
            child: GestureDetector(
              onPanStart: (d) => _onPanStart(d, fitted),
              onPanUpdate: (d) => _onPanUpdate(d, fitted),
              onPanEnd: _onPanEnd,
              onDoubleTap: () =>
                  setState(() => _viewTransform = Matrix4.identity()),
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _showOriginalPreview
                          ? Image.memory(_currentBytes, fit: BoxFit.contain)
                          : ColorFiltered(
                              colorFilter: ColorFilter.matrix(
                                _previewColorMatrix(),
                              ),
                              child: Image.memory(
                                _currentBytes,
                                fit: BoxFit.contain,
                              ),
                            ),
                    ),
                    if (_allowCrop &&
                        (widget.mode == EnhancerMode.crop ||
                            _activePanel == _EnhancerPanel.frame))
                      Positioned.fill(
                        child: CustomPaint(
                          painter: QuadOverlayPainter(
                            corners: List.unmodifiable(_corners),
                            fitted: fitted,
                            activeCorner: _activeCorner,
                          ),
                        ),
                      ),
                    if (_activeCorner != null &&
                        _loupePos != null &&
                        _uiImage != null)
                      _buildLoupe(fitted, size),
                    if (_detecting)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(
                          backgroundColor: Colors.white24,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Colors.orangeAccent,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLoupe(Rect fitted, Size containerSize) {
    const loupeSize = 140.0;
    final pos = _loupePos!;
    final isLeft = pos.dx < containerSize.width / 2;
    final isTop = pos.dy < containerSize.height / 2;
    return Positioned(
      left: isLeft ? containerSize.width - loupeSize - 16 : 16,
      top: isTop ? containerSize.height - loupeSize - 16 : 16,
      width: loupeSize,
      height: loupeSize,
      child: CustomPaint(
        painter: LoupePainter(
          uiImage: _uiImage!,
          imgW: _imgW,
          imgH: _imgH,
          focalWidget: pos,
          fitted: fitted,
          zoom: 2.0,
        ),
      ),
    );
  }

  Widget _buildControls(ThemeData theme) {
    final isCropOnly = widget.mode == EnhancerMode.crop;
    final isStudio = widget.mode == EnhancerMode.studio;
    final pct = ((_brightness - 1.0) * 100).round();
    final pctLabel = '${pct >= 0 ? '+' : ''}$pct%';
    final canInteract = !_processing && !_rotating;
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Annuler la dernière modification',
                onPressed: _undoStack.isNotEmpty ? _undo : null,
                icon: const Icon(Icons.undo, color: Colors.white70),
              ),
              IconButton(
                tooltip: 'Refaire',
                onPressed: _redoStack.isNotEmpty ? _redo : null,
                icon: const Icon(Icons.redo, color: Colors.white70),
              ),
              const Spacer(),
              GestureDetector(
                onLongPressStart: (_) =>
                    setState(() => _showOriginalPreview = true),
                onLongPressEnd: (_) =>
                    setState(() => _showOriginalPreview = false),
                child: TextButton.icon(
                  onPressed: () => setState(() {
                    _showOriginalPreview = !_showOriginalPreview;
                  }),
                  icon: Icon(
                    _showOriginalPreview
                        ? Icons.visibility_off
                        : Icons.visibility_outlined,
                    color: Colors.white70,
                    size: AppIconSize.small,
                  ),
                  label: Text(
                    _showOriginalPreview ? 'Original' : 'Avant / Après',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ],
          ),
          if (isStudio)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Cadre'),
                  selected: _activePanel == _EnhancerPanel.frame,
                  onSelected: (_) =>
                      setState(() => _activePanel = _EnhancerPanel.frame),
                ),
                ChoiceChip(
                  label: const Text('Lumière'),
                  selected: _activePanel == _EnhancerPanel.light,
                  onSelected: (_) =>
                      setState(() => _activePanel = _EnhancerPanel.light),
                ),
                ChoiceChip(
                  label: const Text('Détails'),
                  selected: _activePanel == _EnhancerPanel.details,
                  onSelected: (_) =>
                      setState(() => _activePanel = _EnhancerPanel.details),
                ),
                ChoiceChip(
                  label: const Text('Presets'),
                  selected: _activePanel == _EnhancerPanel.presets,
                  onSelected: (_) =>
                      setState(() => _activePanel = _EnhancerPanel.presets),
                ),
              ],
            ),
          if (isStudio) const SizedBox(height: 6),
          // Boutons de rotation — disponibles dans les deux modes
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Tooltip(
                message: 'Rotation 90° anti-horaire',
                child: IconButton(
                  tooltip: 'Pivoter vers la gauche',
                  icon: _rotating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white70,
                          ),
                        )
                      : const Icon(Icons.rotate_left, color: Colors.white70),
                  onPressed: canInteract ? () => _rotate(false) : null,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Pivoter',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Rotation 90° horaire',
                child: IconButton(
                  tooltip: 'Pivoter vers la droite',
                  icon: const Icon(Icons.rotate_right, color: Colors.white70),
                  onPressed: canInteract ? () => _rotate(true) : null,
                ),
              ),
            ],
          ),
          if (_allowCrop &&
              (isCropOnly || _activePanel == _EnhancerPanel.frame))
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'Glissez les coins  •  Ctrl+molette = zoom  •  double-tap = réinit',
                style: TextStyle(color: Colors.white54, fontSize: 11),
                textAlign: TextAlign.center,
              ),
            ),
          if (_allowColor &&
              (!isStudio || _activePanel == _EnhancerPanel.light)) ...[
            Row(
              children: [
                const Icon(
                  Icons.brightness_6_outlined,
                  color: Colors.white70,
                  size: AppIconSize.small,
                ),
                const SizedBox(width: 8),
                Text(
                  'Luminosité',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _brightness,
                    min: 0.5,
                    max: 1.5,
                    divisions: 20,
                    onChangeStart: (_) => _beginSliderAdjustment(),
                    onChangeEnd: _endSliderAdjustment,
                    onChanged: (v) => setState(() => _brightness = v),
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    pctLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white54,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(
                  Icons.contrast_outlined,
                  color: Colors.white70,
                  size: AppIconSize.small,
                ),
                const SizedBox(width: 8),
                Text(
                  'Contraste',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _contrast,
                    min: 0.75,
                    max: 1.35,
                    divisions: 24,
                    onChangeStart: (_) => _beginSliderAdjustment(),
                    onChangeEnd: _endSliderAdjustment,
                    onChanged: (v) => setState(() => _contrast = v),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                const Icon(
                  Icons.palette_outlined,
                  color: Colors.white70,
                  size: AppIconSize.small,
                ),
                const SizedBox(width: 8),
                Text(
                  'Saturation',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                Expanded(
                  child: Slider(
                    value: _saturation,
                    min: 0.70,
                    max: 1.35,
                    divisions: 26,
                    onChangeStart: (_) => _beginSliderAdjustment(),
                    onChangeEnd: _endSliderAdjustment,
                    onChanged: (v) => setState(() => _saturation = v),
                  ),
                ),
              ],
            ),
          ],
          if (_allowColor &&
              (!isStudio || _activePanel == _EnhancerPanel.details)) ...[
            Row(
              children: [
                const Icon(
                  Icons.lens_blur_outlined,
                  color: Colors.white70,
                  size: AppIconSize.small,
                ),
                const SizedBox(width: 8),
                Text(
                  'Netteté',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                  ),
                ),
                const Spacer(),
                Switch(
                  value: _sharpen,
                  onChanged: (v) {
                    _pushHistory();
                    setState(() {
                      _sharpen = v;
                      _suggestedPreset = null;
                    });
                  },
                ),
              ],
            ),
          ],
          if (_allowColor &&
              isStudio &&
              _activePanel == _EnhancerPanel.presets) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Presets rapides',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilterChip(
                  selected: _suggestedPreset == 'naturel',
                  onSelected: (_) => _applyPreset('naturel'),
                  label: const Text('Naturel'),
                ),
                FilterChip(
                  selected: _suggestedPreset == 'lisibilite',
                  onSelected: (_) => _applyPreset('lisibilite'),
                  label: const Text('Lisibilité'),
                ),
                FilterChip(
                  selected: _suggestedPreset == 'pop',
                  onSelected: (_) => _applyPreset('pop'),
                  label: const Text('Couleurs pop'),
                ),
                FilterChip(
                  selected: _suggestedPreset == 'doux',
                  onSelected: (_) => _applyPreset('doux'),
                  label: const Text('Doux'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _suggestedPreset == null
                  ? 'Ajustements manuels actifs'
                  : 'Preset recommandé ou actif: $_suggestedPreset',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
