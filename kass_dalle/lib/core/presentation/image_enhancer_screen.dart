import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'image_enhancer_processing.dart';

/// Écran de correction de perspective et d'amélioration d'image.
///
/// L'utilisateur positionne les 4 coins blancs sur les 4 coins de la page,
/// puis l'app calcule l'homographie et restitue l'image aplanie.
///
/// Retourne via [Navigator.pop] les bytes JPEG résultants, ou `null` si annulation.
class ImageEnhancerScreen extends StatefulWidget {
  final Uint8List imageBytes;
  final String title;

  /// Callback alternatif à [Navigator.pop] pour les cas où l'écran
  /// est intégré en Stack (sans route). Appelé avec `null` en cas d'annulation.
  final void Function(Uint8List?)? onResult;

  const ImageEnhancerScreen({
    super.key,
    required this.imageBytes,
    this.title = 'Recadrer / améliorer',
    this.onResult,
  });

  @override
  State<ImageEnhancerScreen> createState() => _ImageEnhancerScreenState();
}

class _ImageEnhancerScreenState extends State<ImageEnhancerScreen> {
  ui.Image? _uiImage;
  int _imgW = 1, _imgH = 1;

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
  bool _sharpen = false;
  bool _processing = false;
  bool _detecting = false;

  // Zoom / pan du canvas
  Matrix4 _viewTransform = Matrix4.identity();
  bool _panning = false;

  @override
  void initState() {
    super.initState();
    _loadUiImage();
  }

  Future<void> _loadUiImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _uiImage = frame.image;
      _imgW = frame.image.width;
      _imgH = frame.image.height;
    });
    _runAutoDetect();
  }

  Future<void> _runAutoDetect() async {
    if (!mounted) return;
    setState(() => _detecting = true);
    try {
      final corners = await compute(
        detectCornersIsolate,
        DetectParams(imageBytes: widget.imageBytes),
      );
      if (mounted && corners != null) {
        setState(() {
          for (var i = 0; i < 4; i++) {
            _corners[i] = Offset(
              corners[i * 2].clamp(0.01, 0.99),
              corners[i * 2 + 1].clamp(0.01, 0.99),
            );
          }
        });
      }
    } catch (_) {
      // Silently keep default corners
    } finally {
      if (mounted) setState(() => _detecting = false);
    }
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
        ..translate(d.delta.dx * scale, d.delta.dy * scale);
      setState(() => _viewTransform = t * _viewTransform);
    }
  }

  void _onPanEnd(DragEndDetails _) => setState(() {
    _activeCorner = null;
    _loupePos = null;
    _panning = false;
  });

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
      ..translate(focal.dx, focal.dy)
      ..scale(actualFactor, actualFactor)
      ..translate(-focal.dx, -focal.dy);
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
    setState(() => _processing = true);
    try {
      final params = WarpParams(
        imageBytes: widget.imageBytes,
        cornersFlat: _corners.expand((c) => [c.dx, c.dy]).toList(),
        brightness: _brightness,
        sharpen: _sharpen,
      );
      final result = await compute(warpIsolate, params);
      if (mounted) {
        if (widget.onResult != null) {
          widget.onResult!(result);
        } else {
          Navigator.of(context).pop<Uint8List?>(result);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _processing = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur traitement : $e')));
      }
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
          if (!_processing)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: _confirm,
                child: const Text('Confirmer'),
              ),
            ),
        ],
      ),
      body: _processing
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'Correction en cours…',
                    style: TextStyle(color: Colors.white70),
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
                      child: ColorFiltered(
                        colorFilter: ColorFilter.matrix([
                          _brightness,
                          0,
                          0,
                          0,
                          0,
                          0,
                          _brightness,
                          0,
                          0,
                          0,
                          0,
                          0,
                          _brightness,
                          0,
                          0,
                          0,
                          0,
                          0,
                          1,
                          0,
                        ]),
                        child: Image.memory(
                          widget.imageBytes,
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
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
    final pct = ((_brightness - 1.0) * 100).round();
    final pctLabel = '${pct >= 0 ? '+' : ''}$pct%';
    return Container(
      color: Colors.black87,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text(
              'Glissez les coins  •  Ctrl+molette = zoom  •  double-tap = réinit',
              style: TextStyle(color: Colors.white54, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
          Row(
            children: [
              const Icon(
                Icons.brightness_6_outlined,
                color: Colors.white70,
                size: 20,
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
                Icons.lens_blur_outlined,
                color: Colors.white70,
                size: 20,
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
                onChanged: (v) => setState(() => _sharpen = v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
