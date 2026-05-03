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

  const ImageEnhancerScreen({
    super.key,
    required this.imageBytes,
    this.title = 'Recadrer / améliorer',
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
      final dist = (d.localPosition - _normToWidget(_corners[i], fitted)).distance;
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

  void _cancel() => Navigator.of(context).pop<Uint8List?>(null);

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
      if (mounted) Navigator.of(context).pop<Uint8List?>(result);
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
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return LayoutBuilder(builder: (context, constraints) {
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
                child: Image.memory(widget.imageBytes, fit: BoxFit.contain),
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
            ],
          ),
        ),
      );
    });
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
          zoom: 3.5,
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
              const Icon(Icons.brightness_6_outlined,
                  color: Colors.white70, size: 20),
              const SizedBox(width: 8),
              Text('Luminosité',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white70)),
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
                child: Text(pctLabel,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.white54),
                    textAlign: TextAlign.right),
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.lens_blur_outlined,
                  color: Colors.white70, size: 20),
              const SizedBox(width: 8),
              Text('Netteté',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: Colors.white70)),
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

  Offset _tw(Offset n) =>
      Offset(fitted.left + n.dx * fitted.width, fitted.top + n.dy * fitted.height);

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
        canvas.drawCircle(pts[i], 22,
            Paint()..color = Colors.orangeAccent.withValues(alpha: 0.3));
      }
      canvas.drawCircle(
          pts[i],
          active ? 13 : 10,
          Paint()
            ..color = active ? Colors.orangeAccent : Colors.white
            ..style = PaintingStyle.fill);
      canvas.drawCircle(
          pts[i],
          active ? 13 : 10,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.4)
            ..strokeWidth = 1.5
            ..style = PaintingStyle.stroke);
      final r = active ? 7.0 : 5.0;
      final cross = Paint()
        ..color = Colors.black54
        ..strokeWidth = 1.2;
      canvas.drawLine(
          Offset(pts[i].dx - r, pts[i].dy), Offset(pts[i].dx + r, pts[i].dy), cross);
      canvas.drawLine(
          Offset(pts[i].dx, pts[i].dy - r), Offset(pts[i].dx, pts[i].dy + r), cross);
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
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: center, radius: r)));
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = Colors.black);
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
          ..strokeWidth = 1.2);
    canvas.restore();

    // Border
    canvas.drawCircle(
        center,
        r,
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);
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
    work = img.copyResize(src,
        width: (src.width * s).round(),
        height: (src.height * s).round(),
        interpolation: img.Interpolation.linear);
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
  final outW = math.max(topW, botW).round();
  final outH = math.max(leftH, rightH).round();

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
    result = img.convolution(result,
        filter: [0, -1, 0, -1, 5, -1, 0, -1, 0], div: 1);
  }
  return Uint8List.fromList(img.encodeJpg(result, quality: 92));
}

void _bilinear(img.Image dst, int dx, int dy, img.Image src, double sx, double sy) {
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
  final r = lerp(lerp(p00.r, p10.r, fx), lerp(p01.r, p11.r, fx), fy).round().clamp(0, 255);
  final g = lerp(lerp(p00.g, p10.g, fx), lerp(p01.g, p11.g, fx), fy).round().clamp(0, 255);
  final b = lerp(lerp(p00.b, p10.b, fx), lerp(p01.b, p11.b, fx), fy).round().clamp(0, 255);
  dst.setPixelRgba(dx, dy, r, g, b, 255);
}

// ── Homography (DLT) ──────────────────────────────────────────────────────────

List<double> _computeHomography(List<Offset> src, List<Offset> dst) {
  // For each point: 2 equations (h33 = 1)
  // [xi, yi, 1, 0, 0, 0, -xp*xi, -xp*yi] * h = xp
  // [0,  0,  0, xi, yi, 1, -yp*xi, -yp*yi] * h = yp
  final A = <List<double>>[];
  final b = <double>[];
  for (int i = 0; i < 4; i++) {
    final xi = src[i].dx, yi = src[i].dy;
    final xp = dst[i].dx, yp = dst[i].dy;
    A.add([xi, yi, 1, 0, 0, 0, -xp * xi, -xp * yi]);
    b.add(xp);
    A.add([0, 0, 0, xi, yi, 1, -yp * xi, -yp * yi]);
    b.add(yp);
  }
  return [..._gaussianElim(A, b), 1.0];
}

List<double> _gaussianElim(List<List<double>> A, List<double> b) {
  const n = 8;
  final M = List.generate(n, (i) => [...A[i], b[i]]);
  for (int col = 0; col < n; col++) {
    int maxRow = col;
    for (int row = col + 1; row < n; row++) {
      if (M[row][col].abs() > M[maxRow][col].abs()) maxRow = row;
    }
    final tmp = M[col]; M[col] = M[maxRow]; M[maxRow] = tmp;
    if (M[col][col].abs() < 1e-12) continue;
    for (int row = col + 1; row < n; row++) {
      final f = M[row][col] / M[col][col];
      for (int k = col; k <= n; k++) { M[row][k] -= f * M[col][k]; }
    }
  }
  final x = List.filled(n, 0.0);
  for (int i = n - 1; i >= 0; i--) {
    x[i] = M[i][n];
    for (int j = i + 1; j < n; j++) { x[i] -= M[i][j] * x[j]; }
    if (M[i][i].abs() > 1e-12) { x[i] /= M[i][i]; }
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
    (e * k - f * h) * inv, (c * h - b * k) * inv, (b * f - c * e) * inv,
    (f * g - d * k) * inv, (a * k - c * g) * inv, (c * d - a * f) * inv,
    (d * h - e * g) * inv, (b * g - a * h) * inv, (a * e - b * d) * inv,
  ];
}

// Unused imports kept for compatibility — remove if linter warns
// ignore: unused_import
// (crop_your_image removed — replaced by perspective correction)

