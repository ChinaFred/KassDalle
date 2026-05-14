import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

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
        _detectCornersIsolate,
        _DetectParams(imageBytes: widget.imageBytes),
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
      });
    }
  }

  void _onPanUpdate(DragUpdateDetails d, Rect fitted) {
    if (_activeCorner == null) return;
    setState(() {
      _corners[_activeCorner!] = _widgetToNorm(d.localPosition, fitted);
      _loupePos = d.localPosition;
    });
  }

  void _onPanEnd(DragEndDetails _) => setState(() {
    _activeCorner = null;
    _loupePos = null;
  });

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
      final params = _WarpParams(
        imageBytes: widget.imageBytes,
        cornersFlat: _corners.expand((c) => [c.dx, c.dy]).toList(),
        brightness: _brightness,
        sharpen: _sharpen,
      );
      final result = await compute(_warpIsolate, params);
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
        return GestureDetector(
          onPanStart: (d) => _onPanStart(d, fitted),
          onPanUpdate: (d) => _onPanUpdate(d, fitted),
          onPanEnd: _onPanEnd,
          child: SizedBox.expand(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix([
                      _brightness, 0, 0, 0, 0,
                      0, _brightness, 0, 0, 0,
                      0, 0, _brightness, 0, 0,
                      0, 0, 0, 1, 0,
                    ]),
                    child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _QuadPainter(
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
        painter: _LoupePainter(
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
              'Glissez les coins  •  blanc = inactif  •  orange = actif',
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

// ── Quad overlay painter ───────────────────────────────────────────────────────

class _QuadPainter extends CustomPainter {
  final List<Offset> corners;
  final Rect fitted;
  final int? activeCorner;

  const _QuadPainter({
    required this.corners,
    required this.fitted,
    this.activeCorner,
  });

  Offset _tw(Offset n) => Offset(
    fitted.left + n.dx * fitted.width,
    fitted.top + n.dy * fitted.height,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final pts = corners.map(_tw).toList();

    final quadPath = Path()
      ..moveTo(pts[0].dx, pts[0].dy)
      ..lineTo(pts[1].dx, pts[1].dy)
      ..lineTo(pts[2].dx, pts[2].dy)
      ..lineTo(pts[3].dx, pts[3].dy)
      ..close();

    // Mask outside quad
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
      quadPath,
    );
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.5));

    // Quad border
    canvas.drawPath(
      quadPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );

    // Edge midpoint dots
    final dotPaint = Paint()
      ..color = Colors.white54
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    for (int i = 0; i < 4; i++) {
      final mid = Offset(
        (pts[i].dx + pts[(i + 1) % 4].dx) / 2,
        (pts[i].dy + pts[(i + 1) % 4].dy) / 2,
      );
      canvas.drawCircle(mid, 4, dotPaint);
    }

    // Corner handles
    for (int i = 0; i < 4; i++) {
      final active = i == activeCorner;
      if (active) {
        canvas.drawCircle(
          pts[i],
          22,
          Paint()..color = Colors.orangeAccent.withValues(alpha: 0.3),
        );
      }
      canvas.drawCircle(
        pts[i],
        active ? 13 : 10,
        Paint()
          ..color = active ? Colors.orangeAccent : Colors.white
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        pts[i],
        active ? 13 : 10,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.4)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
      final r = active ? 7.0 : 5.0;
      final cross = Paint()
        ..color = Colors.black54
        ..strokeWidth = 1.2;
      canvas.drawLine(
        Offset(pts[i].dx - r, pts[i].dy),
        Offset(pts[i].dx + r, pts[i].dy),
        cross,
      );
      canvas.drawLine(
        Offset(pts[i].dx, pts[i].dy - r),
        Offset(pts[i].dx, pts[i].dy + r),
        cross,
      );
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) =>
      old.corners != corners ||
      old.activeCorner != activeCorner ||
      old.fitted != fitted;
}

// ── Magnifier loupe painter ────────────────────────────────────────────────────

class _LoupePainter extends CustomPainter {
  final ui.Image uiImage;
  final int imgW, imgH;
  final Offset focalWidget;
  final Rect fitted;
  final double zoom;

  const _LoupePainter({
    required this.uiImage,
    required this.imgW,
    required this.imgH,
    required this.focalWidget,
    required this.fitted,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2;
    final center = Offset(r, r);

    final normX = (focalWidget.dx - fitted.left) / fitted.width;
    final normY = (focalWidget.dy - fitted.top) / fitted.height;
    final imgFX = normX * imgW;
    final imgFY = normY * imgH;
    final halfSpan = r / zoom;

    final srcRect = Rect.fromCenter(
      center: Offset(imgFX, imgFY),
      width: halfSpan * 2,
      height: halfSpan * 2,
    );

    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: r)),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = Colors.black,
    );
    canvas.drawImageRect(
      uiImage,
      srcRect,
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..filterQuality = FilterQuality.high,
    );
    // Crosshair
    final cp = Paint()
      ..color = Colors.orangeAccent
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(r - 14, r), Offset(r + 14, r), cp);
    canvas.drawLine(Offset(r, r - 14), Offset(r, r + 14), cp);
    canvas.drawCircle(
      center,
      4,
      Paint()
        ..color = Colors.orangeAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    canvas.restore();

    // Border
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_LoupePainter old) => old.focalWidget != focalWidget;
}

// ── Isolate warp ───────────────────────────────────────────────────────────────

class _WarpParams {
  final Uint8List imageBytes;
  final List<double> cornersFlat; // [x0,y0, x1,y1, x2,y2, x3,y3] normalized
  final double brightness;
  final bool sharpen;

  const _WarpParams({
    required this.imageBytes,
    required this.cornersFlat,
    required this.brightness,
    required this.sharpen,
  });
}

Uint8List _warpIsolate(_WarpParams p) {
  final src = img.decodeImage(p.imageBytes);
  if (src == null) throw Exception('Impossible de décoder l\'image');

  // Downsample large images for performance
  final maxDim = math.max(src.width, src.height);
  final img.Image work;
  if (maxDim > 2048) {
    final s = 2048 / maxDim;
    work = img.copyResize(
      src,
      width: (src.width * s).round(),
      height: (src.height * s).round(),
      interpolation: img.Interpolation.linear,
    );
  } else {
    work = src;
  }

  final W = work.width.toDouble();
  final H = work.height.toDouble();

  final corners = List.generate(
    4,
    (i) => Offset(p.cornersFlat[i * 2] * W, p.cornersFlat[i * 2 + 1] * H),
  );

  final topW = (corners[1] - corners[0]).distance;
  final botW = (corners[2] - corners[3]).distance;
  final leftH = (corners[3] - corners[0]).distance;
  final rightH = (corners[2] - corners[1]).distance;
  // Moyenne géométrique : meilleure estimation de la vraie dimension du document
  // en présence de perspective (évite l'écrasement causé par max()).
  final outW = math.sqrt(topW * botW).round();
  final outH = math.sqrt(leftH * rightH).round();

  if (outW < 4 || outH < 4) throw Exception('Zone de sélection trop petite');

  final dst = [
    const Offset(0, 0),
    Offset(outW.toDouble(), 0),
    Offset(outW.toDouble(), outH.toDouble()),
    Offset(0, outH.toDouble()),
  ];

  final hFwd = _computeHomography(corners, dst);
  final hInv = _invertMatrix3(hFwd);

  final out = img.Image(width: outW, height: outH);
  for (int y = 0; y < outH; y++) {
    for (int x = 0; x < outW; x++) {
      final denom = hInv[6] * x + hInv[7] * y + hInv[8];
      final sx = (hInv[0] * x + hInv[1] * y + hInv[2]) / denom;
      final sy = (hInv[3] * x + hInv[4] * y + hInv[5]) / denom;
      _bilinear(out, x, y, work, sx, sy);
    }
  }

  img.Image result = out;
  if (p.brightness != 1.0) {
    result = img.adjustColor(result, brightness: p.brightness);
  }
  if (p.sharpen) {
    result = img.convolution(
      result,
      filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
      div: 1,
    );
  }
  return Uint8List.fromList(img.encodeJpg(result, quality: 92));
}

void _bilinear(
  img.Image dst,
  int dx,
  int dy,
  img.Image src,
  double sx,
  double sy,
) {
  if (sx < 0 || sy < 0 || sx >= src.width || sy >= src.height) {
    dst.setPixelRgba(dx, dy, 0, 0, 0, 255);
    return;
  }
  final x0 = sx.floor().clamp(0, src.width - 1);
  final x1 = (x0 + 1).clamp(0, src.width - 1);
  final y0 = sy.floor().clamp(0, src.height - 1);
  final y1 = (y0 + 1).clamp(0, src.height - 1);
  final fx = sx - x0;
  final fy = sy - y0;
  final p00 = src.getPixel(x0, y0);
  final p10 = src.getPixel(x1, y0);
  final p01 = src.getPixel(x0, y1);
  final p11 = src.getPixel(x1, y1);
  double lerp(num a, num b, double t) => a + (b - a) * t;
  final r = lerp(
    lerp(p00.r, p10.r, fx),
    lerp(p01.r, p11.r, fx),
    fy,
  ).round().clamp(0, 255);
  final g = lerp(
    lerp(p00.g, p10.g, fx),
    lerp(p01.g, p11.g, fx),
    fy,
  ).round().clamp(0, 255);
  final b = lerp(
    lerp(p00.b, p10.b, fx),
    lerp(p01.b, p11.b, fx),
    fy,
  ).round().clamp(0, 255);
  dst.setPixelRgba(dx, dy, r, g, b, 255);
}

// ── Homography (DLT) ──────────────────────────────────────────────────────────

List<double> _computeHomography(List<Offset> src, List<Offset> dst) {
  // Hartley normalization: centre + mise à l'échelle avant DLT
  // → améliore massivement la stabilité numérique
  final tSrc = _hartleyNormMatrix(src);
  final tDst = _hartleyNormMatrix(dst);
  final srcN = _applyNormMatrix(tSrc, src);
  final dstN = _applyNormMatrix(tDst, dst);

  // DLT sur les points normalisés
  // [xi, yi, 1, 0, 0, 0, -xp*xi, -xp*yi] * h = xp
  // [0,  0,  0, xi, yi, 1, -yp*xi, -yp*yi] * h = yp
  final A = <List<double>>[];
  final b = <double>[];
  for (int i = 0; i < 4; i++) {
    final xi = srcN[i].dx, yi = srcN[i].dy;
    final xp = dstN[i].dx, yp = dstN[i].dy;
    A.add([xi, yi, 1, 0, 0, 0, -xp * xi, -xp * yi]);
    b.add(xp);
    A.add([0, 0, 0, xi, yi, 1, -yp * xi, -yp * yi]);
    b.add(yp);
  }
  final hN = [..._gaussianElim(A, b), 1.0];

  // Dénormalisation : H = T_dst⁻¹ · H_norm · T_src
  final tDstInv = _invertMatrix3(tDst);
  return _mulMat3(_mulMat3(tDstInv, hN), tSrc);
}

/// Matrice de normalisation de Hartley 3×3 (row-major, 9 éléments).
/// Translate au centroïde et met à l'échelle pour que la distance moyenne = √2.
List<double> _hartleyNormMatrix(List<Offset> pts) {
  final cx = (pts[0].dx + pts[1].dx + pts[2].dx + pts[3].dx) / 4;
  final cy = (pts[0].dy + pts[1].dy + pts[2].dy + pts[3].dy) / 4;
  double dSum = 0;
  for (final p in pts) {
    final dx = p.dx - cx, dy = p.dy - cy;
    dSum += math.sqrt(dx * dx + dy * dy);
  }
  final dMean = dSum / 4;
  final s = dMean > 1e-8 ? math.sqrt(2.0) / dMean : 1.0;
  return [s, 0.0, -s * cx, 0.0, s, -s * cy, 0.0, 0.0, 1.0];
}

/// Applique la matrice de normalisation T (3×3 row-major) à une liste de points 2-D.
List<Offset> _applyNormMatrix(List<double> T, List<Offset> pts) {
  return pts
      .map((p) => Offset(T[0] * p.dx + T[2], T[4] * p.dy + T[5]))
      .toList();
}

/// Multiplie deux matrices 3×3 row-major.
List<double> _mulMat3(List<double> A, List<double> B) {
  final C = List.filled(9, 0.0);
  for (int r = 0; r < 3; r++) {
    for (int c = 0; c < 3; c++) {
      for (int k = 0; k < 3; k++) {
        C[r * 3 + c] += A[r * 3 + k] * B[k * 3 + c];
      }
    }
  }
  return C;
}

List<double> _gaussianElim(List<List<double>> A, List<double> b) {
  const n = 8;
  final M = List.generate(n, (i) => [...A[i], b[i]]);
  for (int col = 0; col < n; col++) {
    int maxRow = col;
    for (int row = col + 1; row < n; row++) {
      if (M[row][col].abs() > M[maxRow][col].abs()) maxRow = row;
    }
    final tmp = M[col];
    M[col] = M[maxRow];
    M[maxRow] = tmp;
    if (M[col][col].abs() < 1e-12) continue;
    for (int row = col + 1; row < n; row++) {
      final f = M[row][col] / M[col][col];
      for (int k = col; k <= n; k++) {
        M[row][k] -= f * M[col][k];
      }
    }
  }
  final x = List.filled(n, 0.0);
  for (int i = n - 1; i >= 0; i--) {
    x[i] = M[i][n];
    for (int j = i + 1; j < n; j++) {
      x[i] -= M[i][j] * x[j];
    }
    if (M[i][i].abs() > 1e-12) {
      x[i] /= M[i][i];
    }
  }
  return x;
}

List<double> _invertMatrix3(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], k = m[8];
  final det = a * (e * k - f * h) - b * (d * k - f * g) + c * (d * h - e * g);
  if (det.abs() < 1e-10) return List.filled(9, 0.0);
  final inv = 1.0 / det;
  return [
    (e * k - f * h) * inv,
    (c * h - b * k) * inv,
    (b * f - c * e) * inv,
    (f * g - d * k) * inv,
    (a * k - c * g) * inv,
    (c * d - a * f) * inv,
    (d * h - e * g) * inv,
    (b * g - a * h) * inv,
    (a * e - b * d) * inv,
  ];
}

// ── Détection automatique des coins ───────────────────────────────────────────────────────

class _DetectParams {
  final Uint8List imageBytes;
  const _DetectParams({required this.imageBytes});
}

/// Détecte automatiquement les 4 coins d'un document dans une image.
/// Analyse le gradient (Sobel), scanne depuis les 4 bords, ajuste 4 droites
/// par régression PCA et retourne leurs intersections.
///
/// Retourne \[x0,y0, x1,y1, x2,y2, x3,y3\] normalisés \[0..1\] (TL, TR, BR, BL)
/// ou null si la détection échoue (fond trop homogène, pas de bord net).
List<double>? _detectCornersIsolate(_DetectParams p) {
  final src = img.decodeImage(p.imageBytes);
  if (src == null) return null;

  // 1. Réduire à max 512px pour la vitesse
  const target = 512;
  final scaleF = target / math.max(src.width, src.height);
  final W = (src.width * scaleF).clamp(4, target.toDouble()).round();
  final H = (src.height * scaleF).clamp(4, target.toDouble()).round();
  final small = img.copyResize(
    src,
    width: W,
    height: H,
    interpolation: img.Interpolation.linear,
  );
  final gray = img.grayscale(small);

  // 2. Magnitude du gradient Sobel 3×3
  final mag = List.generate(H, (_) => List.filled(W, 0.0));
  double maxMag = 1.0;
  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      final m = _dcSobel(gray, x, y);
      mag[y][x] = m;
      if (m > maxMag) maxMag = m;
    }
  }

  // 3. Seuil adaptatif : 70e percentile (plus inclusif pour les bords de document)
  final allMags = mag.expand((row) => row).toList()..sort();
  final thresh = allMags[(allMags.length * 0.70).round()].clamp(
    maxMag * 0.04,
    maxMag * 0.5,
  );

  // 4. Scan depuis le CENTRE vers les bords (évite de trouver le fond avant le livre).
  //    Pour chaque colonne, on part du milieu de l'image et on remonte/descend
  //    jusqu'à trouver le premier gradient fort → c'est le bord du document.
  final mW = (W * 0.08).round();
  final mH = (H * 0.08).round();
  final midY = H ~/ 2;
  final midX = W ~/ 2;
  final topPts = <Offset>[], botPts = <Offset>[];
  final lftPts = <Offset>[], rgtPts = <Offset>[];

  for (int x = mW; x < W - mW; x++) {
    // top : du centre vers le haut
    for (int y = midY; y >= 0; y--) {
      if (mag[y][x] >= thresh) {
        topPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    // bottom : du centre vers le bas
    for (int y = midY; y < H; y++) {
      if (mag[y][x] >= thresh) {
        botPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
  }
  for (int y = mH; y < H - mH; y++) {
    // left : du centre vers la gauche
    for (int x = midX; x >= 0; x--) {
      if (mag[y][x] >= thresh) {
        lftPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    // right : du centre vers la droite
    for (int x = midX; x < W; x++) {
      if (mag[y][x] >= thresh) {
        rgtPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
  }

  const minPts = 10;
  if (topPts.length < minPts ||
      botPts.length < minPts ||
      lftPts.length < minPts ||
      rgtPts.length < minPts) {
    return null;
  }

  // 5. Élimination des outliers (trim 10%–90%)
  final topT = _dcTrim(topPts, false); // sort par y détectée
  final botT = _dcTrim(botPts, false);
  final lftT = _dcTrim(lftPts, true); // sort par x détectée
  final rgtT = _dcTrim(rgtPts, true);

  // 6. Régression PCA → 4 droites
  final topL = _dcFitLine(topT);
  final botL = _dcFitLine(botT);
  final lftL = _dcFitLine(lftT);
  final rgtL = _dcFitLine(rgtT);

  // 7. Intersections → 4 coins
  final tl = _dcIntersect(topL, lftL);
  final tr = _dcIntersect(topL, rgtL);
  final br = _dcIntersect(botL, rgtL);
  final bl = _dcIntersect(botL, lftL);
  if (tl == null || tr == null || br == null || bl == null) return null;

  // 8. Validation : coins dans la zone valide + quadrilatère convexe
  const margin = 0.05;
  for (final c in [tl, tr, br, bl]) {
    if (c.dx / W < -margin ||
        c.dx / W > 1 + margin ||
        c.dy / H < -margin ||
        c.dy / H > 1 + margin) {
      return null;
    }
  }
  if (!_dcIsConvex([tl, tr, br, bl])) return null;

  return [
    tl.dx / W,
    tl.dy / H,
    tr.dx / W,
    tr.dy / H,
    br.dx / W,
    br.dy / H,
    bl.dx / W,
    bl.dy / H,
  ];
}

/// Magnitude du gradient de Sobel au pixel (x, y) d'une image en niveaux de gris.
double _dcSobel(img.Image gray, int x, int y) {
  int gv(int px, int py) => gray
      .getPixel(px.clamp(0, gray.width - 1), py.clamp(0, gray.height - 1))
      .r
      .round();
  final gx =
      gv(x + 1, y - 1) +
      2 * gv(x + 1, y) +
      gv(x + 1, y + 1) -
      gv(x - 1, y - 1) -
      2 * gv(x - 1, y) -
      gv(x - 1, y + 1);
  final gy =
      gv(x - 1, y + 1) +
      2 * gv(x, y + 1) +
      gv(x + 1, y + 1) -
      gv(x - 1, y - 1) -
      2 * gv(x, y - 1) -
      gv(x + 1, y - 1);
  return math.sqrt((gx * gx + gy * gy).toDouble());
}

/// Élimine les 10% extrêmes selon la coordonnée choisie (x si [sortByX], sinon y).
List<Offset> _dcTrim(List<Offset> pts, bool sortByX) {
  final sorted = [...pts]
    ..sort(
      (a, b) =>
          ((sortByX ? a.dx : a.dy) - (sortByX ? b.dx : b.dy)).sign.toInt(),
    );
  final lo = (sorted.length * 0.10).round();
  final hi = (sorted.length * 0.90).round().clamp(lo + 1, sorted.length);
  return sorted.sublist(lo, hi);
}

/// Droite en forme générale : px·x + py·y = r.
class _Line2D {
  final double px, py, r;
  const _Line2D(this.px, this.py, this.r);
}

/// Régression PCA : droite passant au mieux par la liste de points.
/// Utilise l'analyse en composantes principales de la matrice de covariance.
_Line2D _dcFitLine(List<Offset> pts) {
  final n = pts.length.toDouble();
  final mx = pts.fold(0.0, (s, p) => s + p.dx) / n;
  final my = pts.fold(0.0, (s, p) => s + p.dy) / n;
  double sxx = 0, syy = 0, sxy = 0;
  for (final p in pts) {
    final dx = p.dx - mx, dy = p.dy - my;
    sxx += dx * dx;
    syy += dy * dy;
    sxy += dx * dy;
  }
  // Direction principale = eigenvecteur de la grande valeur propre.
  // La normale à la droite est l'eigenvecteur de la PETITE valeur propre.
  final theta = 0.5 * math.atan2(2 * sxy, sxx - syy);
  final nx = -math.sin(theta);
  final ny = math.cos(theta);
  return _Line2D(nx, ny, nx * mx + ny * my);
}

/// Intersection de deux droites en forme générale (règle de Cramer).
Offset? _dcIntersect(_Line2D a, _Line2D b) {
  final det = a.px * b.py - b.px * a.py;
  if (det.abs() < 1e-6) return null;
  return Offset(
    (a.r * b.py - b.r * a.py) / det,
    (a.px * b.r - b.px * a.r) / det,
  );
}

/// Vérifie qu'un quadrilatère (4 sommets ordonnés TL→TR→BR→BL) est convexe.
bool _dcIsConvex(List<Offset> q) {
  int sign = 0;
  for (int i = 0; i < 4; i++) {
    final a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4];
    final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (cross.abs() < 0.5) continue;
    final s = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}
