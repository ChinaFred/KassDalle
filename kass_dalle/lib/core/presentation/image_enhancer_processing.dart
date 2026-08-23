import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

// ── Quad overlay painter ───────────────────────────────────────────────────────

class QuadOverlayPainter extends CustomPainter {
  final List<Offset> corners;
  final Rect fitted;
  final int? activeCorner;

  const QuadOverlayPainter({
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
  bool shouldRepaint(QuadOverlayPainter old) =>
      old.corners != corners ||
      old.activeCorner != activeCorner ||
      old.fitted != fitted;
}

// ── Magnifier loupe painter ────────────────────────────────────────────────────

class LoupePainter extends CustomPainter {
  final ui.Image uiImage;
  final int imgW, imgH;
  final Offset focalWidget;
  final Rect fitted;
  final double zoom;

  const LoupePainter({
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
  bool shouldRepaint(LoupePainter old) => old.focalWidget != focalWidget;
}

// ── Isolate rotation ──────────────────────────────────────────────────────────

class RotateParams {
  final Uint8List imageBytes;
  final double angle; // degrés, positif = sens horaire
  const RotateParams({required this.imageBytes, required this.angle});
}

Uint8List rotateIsolate(RotateParams p) {
  final src = img.decodeImage(p.imageBytes);
  if (src == null) throw Exception('Impossible de décoder l\'image');
  // image package: angle positif = sens horaire
  final rotated = img.copyRotate(src, angle: p.angle);
  // Qualité haute : flutter_image_compress appliquera la compression native finale
  return Uint8List.fromList(img.encodeJpg(rotated, quality: 97));
}

// ── Isolate warp ───────────────────────────────────────────────────────────────

class WarpParams {
  final Uint8List imageBytes;
  final List<double> cornersFlat; // [x0,y0, x1,y1, x2,y2, x3,y3] normalized
  final double brightness;
  final double contrast;
  final double saturation;
  final bool sharpen;

  const WarpParams({
    required this.imageBytes,
    required this.cornersFlat,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.sharpen,
  });
}

Uint8List warpIsolate(WarpParams p) {
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

  // Moyenne géométrique : meilleure estimation de la vraie dimension du document
  // en présence de perspective (évite l'écrasement causé par max()). Le calcul
  // vit dans `outputSizeFor` pour que la fixture partagée le verrouille sur le
  // chemin réel, et non sur une copie qui pourrait en dériver.
  final outSize = outputSizeFor(corners);
  final outW = outSize.width;
  final outH = outSize.height;

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
  if (p.brightness != 1.0 || p.contrast != 1.0 || p.saturation != 1.0) {
    result = img.adjustColor(
      result,
      brightness: p.brightness,
      contrast: p.contrast,
      saturation: p.saturation,
    );
  }
  if (p.sharpen) {
    result = img.convolution(
      result,
      filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
      div: 1,
    );
  }
  // Qualité haute : flutter_image_compress appliquera la compression native finale
  return Uint8List.fromList(img.encodeJpg(result, quality: 97));
}

// ── Analyse rapide de l'image (presets intelligents) ───────────────────────

class AutoTuneStats {
  final double meanLuma;
  final double lumaStdDev;

  const AutoTuneStats({required this.meanLuma, required this.lumaStdDev});
}

AutoTuneStats analyzeImageStatsIsolate(Uint8List bytes) {
  final src = img.decodeImage(bytes);
  if (src == null) {
    return const AutoTuneStats(meanLuma: 0.5, lumaStdDev: 0.2);
  }

  final thumb = img.copyResize(
    src,
    width: src.width > 256 ? 256 : src.width,
    height: src.height > 256 ? 256 : src.height,
    interpolation: img.Interpolation.average,
  );

  final total = thumb.width * thumb.height;
  if (total <= 0) {
    return const AutoTuneStats(meanLuma: 0.5, lumaStdDev: 0.2);
  }

  double sum = 0;
  for (final p in thumb) {
    final luma = (0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b) / 255.0;
    sum += luma;
  }
  final mean = sum / total;

  double varSum = 0;
  for (final p in thumb) {
    final luma = (0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b) / 255.0;
    final d = luma - mean;
    varSum += d * d;
  }
  final stdDev = math.sqrt(varSum / total);

  return AutoTuneStats(meanLuma: mean, lumaStdDev: stdDev);
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

/// L'homographie qui envoie `src` sur `dst`, en 3×3 ligne par ligne.
///
/// Publique pour une seule raison : ce calcul existe **en double**, ici et dans
/// `functions/src/gemini/perspective.ts`, et la fixture partagée
/// `test-fixtures/page_homography.json` doit pouvoir le rejouer des deux côtés.
/// Un écart entre les deux ne lève aucune erreur — il rend une page redressée
/// de travers, parfaitement nette.
List<double> computeHomography(List<Offset> src, List<Offset> dst) =>
    _computeHomography(src, dst);

/// Les dimensions du rectangle de sortie d'un quadrilatère.
///
/// Moyenne **géométrique** des bords opposés, et non le plus grand des deux :
/// en perspective, le bord proche est plus long que le lointain, et retenir le
/// maximum étire l'image dans un sens. Même remarque que ci-dessus sur la
/// duplication : c'est la seconde moitié de ce que la fixture verrouille.
({int width, int height}) outputSizeFor(List<Offset> quad) {
  final topWidth = (quad[1] - quad[0]).distance;
  final bottomWidth = (quad[2] - quad[3]).distance;
  final leftHeight = (quad[3] - quad[0]).distance;
  final rightHeight = (quad[2] - quad[1]).distance;
  return (
    width: math.sqrt(topWidth * bottomWidth).round(),
    height: math.sqrt(leftHeight * rightHeight).round(),
  );
}

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

// ── Détection automatique des coins ───────────────────────────────────────────

class DetectParams {
  final Uint8List imageBytes;
  const DetectParams({required this.imageBytes});
}

/// Détecte automatiquement les 4 coins d'un document dans une image.
/// Analyse le gradient (Sobel), scanne depuis les 4 bords, ajuste 4 droites
/// par régression PCA et retourne leurs intersections.
///
/// Retourne \[x0,y0, x1,y1, x2,y2, x3,y3\] normalisés \[0..1\] (TL, TR, BR, BL)
/// ou null si la détection échoue (fond trop homogène, pas de bord net).
List<double>? detectCornersIsolate(DetectParams p) {
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

  // 1b. Étirement d'histogramme : normalise les niveaux de gris à [0, 255].
  //     Améliore massivement la détection sur les photos sombres, pages jaunies
  //     et scans à faible contraste (Sobel trouve des bords plus nets).
  final normalized = img.normalize(gray, min: 0, max: 255);

  // 2. Magnitude du gradient Sobel 3×3
  final mag = List.generate(H, (_) => List.filled(W, 0.0));
  double maxMag = 1.0;
  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      final m = _dcSobel(normalized, x, y);
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

  // 3b. Dilation morphologique (rayon 1) : élargit les bords d'1 pixel dans toutes
  //     les directions, comblant les lacunes 1-pixel dans le contour du document.
  final edge = _buildEdgeMask(mag, W, H, thresh, 1);

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
      if (edge[y][x]) {
        topPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    // bottom : du centre vers le bas
    for (int y = midY; y < H; y++) {
      if (edge[y][x]) {
        botPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
  }
  for (int y = mH; y < H - mH; y++) {
    // left : du centre vers la gauche
    for (int x = midX; x >= 0; x--) {
      if (edge[y][x]) {
        lftPts.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    // right : du centre vers la droite
    for (int x = midX; x < W; x++) {
      if (edge[y][x]) {
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

/// Crée un masque binaire à partir du gradient Sobel avec dilation morphologique.
/// Chaque pixel fort (>= thresh) dilate ses voisins dans un carré de rayon [radius].
/// Cela comble les lacunes 1-pixel dans les contours du document avant le scan.
List<List<bool>> _buildEdgeMask(
  List<List<double>> mag,
  int W,
  int H,
  double thresh,
  int radius,
) {
  final result = List.generate(H, (_) => List.filled(W, false));
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      if (mag[y][x] >= thresh) {
        for (int dy = -radius; dy <= radius; dy++) {
          for (int dx = -radius; dx <= radius; dx++) {
            result[(y + dy).clamp(0, H - 1)][(x + dx).clamp(0, W - 1)] = true;
          }
        }
      }
    }
  }
  return result;
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
