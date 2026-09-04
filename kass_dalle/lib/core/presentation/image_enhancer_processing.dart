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

/// Qualité du **seul** encodage JPEG de l'atelier.
///
/// On travaille l'image telle qu'elle arrive et on ne la compresse qu'une fois,
/// pour le stockage. La chaîne en comptait trois : la remise d'aplomb
/// réencodait en 95, chaque quart de tour en 97 puis en 90, le redressement en
/// 97 puis en 88 — et réduisait au passage le grand côté à 2048 px. Une photo
/// de 3000 × 4000 arrivait donc rognée et trois fois recompressée avant même
/// d'être lue.
///
/// Chaque génération JPEG abîme d'abord les petits caractères, ce qui est
/// exactement ce qu'un titre de couverture donne à lire.
const int kAtelierJpegQuality = 95;

/// Plus grand côté admis pour le travail sur les pixels.
///
/// Même chiffre que `gemini/perspective.ts` pour l'extraction d'une page : ce
/// n'est pas un excès de zèle, c'est une valeur mesurée. En dessous, le corps
/// de texte d'une page redressée descend à quelques pixels de haut, et le
/// modèle qui la lit invente un titre plausible.
const int kAtelierMaxWorkDimension = 4000;

/// Part minimale de l'image qu'un document doit couvrir pour être proposé.
///
/// En dessous, ce qui a été trouvé est un détail de la scène : une assiette, un
/// reflet, un aplat de la couverture quand le livre remplit déjà la photo.
const double kAtelierAireMinimale = 0.25;

// ── Isolate rotation ──────────────────────────────────────────────────────────

class RotateParams {
  final Uint8List imageBytes;
  final double angle; // degrés, positif = sens horaire

  /// Appliquer d'abord l'orientation EXIF, quand les octets la portent encore.
  final bool bakeOrientation;

  const RotateParams({
    required this.imageBytes,
    required this.angle,
    this.bakeOrientation = false,
  });
}

Uint8List rotateIsolate(RotateParams p) {
  final src = img.decodeImage(p.imageBytes);
  if (src == null) throw Exception('Impossible de décoder l\'image');
  final base = p.bakeOrientation ? decideUpright(src).image : src;
  // image package: angle positif = sens horaire
  final rotated = img.copyRotate(base, angle: p.angle);
  return Uint8List.fromList(
    img.encodeJpg(rotated, quality: kAtelierJpegQuality),
  );
}

// ── Isolate warp ───────────────────────────────────────────────────────────────

class WarpParams {
  final Uint8List imageBytes;
  final List<double> cornersFlat; // [x0,y0, x1,y1, x2,y2, x3,y3] normalized
  final double brightness;
  final double contrast;
  final double saturation;
  final bool sharpen;

  /// Appliquer d'abord l'orientation EXIF, quand les octets la portent encore.
  final bool bakeOrientation;

  const WarpParams({
    required this.imageBytes,
    required this.cornersFlat,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.sharpen,
    this.bakeOrientation = false,
  });
}

// ── Remise d'aplomb EXIF ─────────────────────────────────────────────────────

/// Applique l'orientation EXIF dans les pixels eux-mêmes.
///
/// Sans cette passe, une photo de téléphone existe en deux versions : celle que
/// Flutter **affiche**, qui honore l'EXIF, et celle que le paquet `image`
/// **décode**, qui l'ignore. Les deux sont tournées de quatre-vingt-dix degrés
/// l'une par rapport à l'autre.
///
/// [detectCornersIsolate] rendait donc des coins justes dans le repère couché,
/// que l'écran posait sur l'image debout : les poignées atterrissaient à côté
/// de la page, et [warpIsolate] découpait au même mauvais endroit. Le résultat
/// est un morceau de table, parfaitement net.
///
/// Le serveur avait été corrigé en août ; l'atelier, non.
///
/// Une seule remise d'aplomb, à l'ouverture, et tout le reste de la chaîne
/// parle du même repère.
/// Ce que la remise d'aplomb décide, avant tout encodage.
class UprightDecision {
  final img.Image image;
  final bool rotated;

  const UprightDecision({required this.image, required this.rotated});
}

/// Décide si les pixels doivent tourner, et les tourne.
///
/// Appelée par les trois isolats qui décodent l'image, jamais seule : une
/// passe dédiée à la seule orientation coûtait un décodage complet — près de
/// trois secondes sur une photo de douze mégapixels dans un navigateur — et un
/// réencodage, pour un travail que chacun d'eux fait au passage.
///
/// Testable telle quelle : `encodeJpg` ne réécrit pas le bloc EXIF, une image
/// fabriquée dans un test perdrait donc son orientation au premier
/// aller-retour. Ici, l'image arrive décodée, avec son EXIF intact.
///
/// La décision porte sur la **valeur EXIF**, pas sur les dimensions. Quatre des
/// huit orientations — miroir horizontal, demi-tour, et leurs combinaisons — ne
/// changent ni la largeur ni la hauteur. Les reconnaître à leurs dimensions
/// revenait à les laisser passer, et un demi-tour non appliqué met les coins
/// détectés à l'exact opposé de la page.
UprightDecision decideUpright(img.Image source) {
  final orientation = source.exif.imageIfd.orientation;
  if (orientation == null || orientation <= 1) {
    return UprightDecision(image: source, rotated: false);
  }
  return UprightDecision(image: img.bakeOrientation(source), rotated: true);
}

Uint8List warpIsolate(WarpParams p) {
  final decoded = img.decodeImage(p.imageBytes);
  if (decoded == null) throw Exception('Impossible de décoder l\'image');
  final src = p.bakeOrientation ? decideUpright(decoded).image : decoded;

  // Plafond de travail : 4000 px, la borne que le serveur a mesurée.
  //
  // Il était à 2048 « for performance ». Une photo de 3000 × 4000 ressortait
  // donc en 1536 × 2048, définitivement : c'est cette image-là qui part au
  // stockage et que le modèle lit ensuite. `gemini/perspective.ts` a fait le
  // constat côté serveur — « une double page redressée dans une image bornée à
  // 2048 px sort autour de 650 px de large, et son corps de texte y mesure cinq
  // pixels de haut » — et a relevé sa propre borne à 4000.
  //
  // La garde reste utile : la boucle ci-dessous parcourt chaque pixel de sortie
  // en Dart pur, et sur le web elle n'a aucun isolate où se réfugier. Une photo
  // de cinquante mégapixels y figerait l'onglet.
  final maxDim = math.max(src.width, src.height);
  final img.Image work;
  if (maxDim > kAtelierMaxWorkDimension) {
    final s = kAtelierMaxWorkDimension / maxDim;
    work = img.copyResize(
      src,
      width: (src.width * s).round(),
      height: (src.height * s).round(),
      interpolation: img.Interpolation.cubic,
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

  /// Appliquer d'abord l'orientation EXIF, quand les octets la portent encore.
  ///
  /// Sans cela, les coins rendus sont justes dans le repère STOCKÉ et faux dans
  /// celui que l'écran affiche — l'affichage honore l'EXIF, ce décodeur non.
  final bool bakeOrientation;

  const DetectParams({required this.imageBytes, this.bakeOrientation = false});
}

/// Détecte automatiquement les 4 coins d'un document dans une image.
/// Analyse le gradient (Sobel), scanne depuis les 4 bords, ajuste 4 droites
/// par régression PCA et retourne leurs intersections.
///
/// Retourne \[x0,y0, x1,y1, x2,y2, x3,y3\] normalisés \[0..1\] (TL, TR, BR, BL)
/// ou null si la détection échoue (fond trop homogène, pas de bord net).
/// Ce que la détection a trouvé, et par où elle est passée.
class QuadDetection {
  /// Les quatre coins normalisés, ou `null` si rien n'a été retenu.
  final List<double>? quad;

  /// Où la détection s'est arrêtée, et sur quels chiffres.
  ///
  /// Transporté plutôt que remonté sur place : cette fonction tourne dans un
  /// isolat, où aucun service de l'application n'existe. C'est l'écran qui
  /// écrit le rapport.
  ///
  /// Sans ces nombres, un cadre qui ne bouge pas ne dit rien : la détection
  /// a-t-elle trouvé une tache trop petite, un fond mal modélisé, ou rien du
  /// tout ? Trois séances de diagnostic sont parties sur des hypothèses
  /// plausibles faute de les avoir.
  final Map<String, Object?> diagnostic;

  const QuadDetection({this.quad, required this.diagnostic});
}

QuadDetection detectCornersIsolate(DetectParams p) {
  final decoded = img.decodeImage(p.imageBytes);
  if (decoded == null) {
    return const QuadDetection(diagnostic: {'sortie': 'image_illisible'});
  }
  final src = p.bakeOrientation ? decideUpright(decoded).image : decoded;
  return detectQuadInImage(src);
}

/// Cherche le document dans une image décodée.
///
/// **On sépare une région, on ne traque pas un contour.**
///
/// La version précédente calculait un gradient de Sobel puis balayait depuis le
/// centre jusqu'au premier bord franc. Elle supposait un intérieur uniforme —
/// une page de texte. Sur une couverture de livre, qui est une photographie,
/// l'intérieur porte des contours bien plus marqués que la frontière
/// carton/table : le balayage s'arrêtait sur le bord d'une assiette, ou, quand
/// le seuil les écartait tous, filait jusqu'au cadre de la photo et rendait
/// l'image entière.
///
/// Ici, on part de ce qui est réellement simple dans la scène : **le fond est
/// uniforme et il occupe les bords**. On le modélise depuis la bande
/// extérieure, on marque tout ce qui s'en écarte, on garde la plus grande tache
/// et on lui ajuste un rectangle. L'intérieur du livre n'a plus aucune
/// influence : photographie chargée ou page blanche, il est simplement « pas la
/// table ».
///
/// Cette approche rend aussi la réduction à 512 px inoffensive. Un bord d'un
/// pixel de large ne se détecte pas ; une tache de deux cent mille pixels, si.
///
/// Rend les coins dans l'ordre haut-gauche, haut-droit, bas-droit, bas-gauche,
/// **et** le chemin suivi, que l'appelant remonte.
QuadDetection detectQuadInImage(img.Image source) {
  final diag = <String, Object?>{};

  // 1. Réduction : une région se reconnaît aussi bien à 512 px, et la suite
  //    parcourt chaque pixel plusieurs fois.
  const target = 512;
  final scaleF = target / math.max(source.width, source.height);
  final W = (source.width * scaleF).clamp(4, target.toDouble()).round();
  final H = (source.height * scaleF).clamp(4, target.toDouble()).round();
  final small = scaleF >= 1
      ? source
      : img.copyResize(
          source,
          width: W,
          height: H,
          interpolation: img.Interpolation.average,
        );
  final pleineW = small.width;
  final pleineH = small.height;
  diag['largeur'] = pleineW;
  diag['hauteur'] = pleineH;
  if (pleineW < 16 || pleineH < 16) {
    diag['sortie'] = 'image_trop_petite';
    return QuadDetection(diagnostic: diag);
  }

  // 1b. Retirer les bandes uniformes qui bordent la photo.
  //
  //     Une photo prise au téléphone arrive parfois avec des bandes noires en
  //     haut et en bas. Elles ne font pas partie de la scène, mais elles
  //     occupent la bande extérieure d'où l'on tire le modèle du fond : mesuré
  //     le 1er septembre 2026, ce fond ressortait à 21,23,24 — du noir — au
  //     lieu du bois de la table. Le bois devenait alors « pas le fond »,
  //     autant que le livre, et le cadre entourait tout sauf les bandes.
  final bandes = _bandesUniformes(small);
  final zone = bandes.estPleine(pleineW, pleineH)
      ? small
      : img.copyCrop(
          small,
          x: bandes.x0,
          y: bandes.y0,
          width: bandes.x1 - bandes.x0,
          height: bandes.y1 - bandes.y0,
        );
  diag['bandes'] =
      '${bandes.y0} ${pleineH - bandes.y1} '
      '${bandes.x0} ${pleineW - bandes.x1}';

  final w = zone.width;
  final h = zone.height;
  if (w < 16 || h < 16) {
    diag['sortie'] = 'zone_trop_petite';
    return QuadDetection(diagnostic: diag);
  }

  // 2. Modèle du fond : sa couleur ET sa texture, pris sur la bande extérieure.
  //
  //    Les bords d'une photo posée sur une table montrent la table. On en tire
  //    deux mesures, parce qu'aucune des deux ne suffit seule.
  //
  //    La couleur ne suffit pas : mesuré sur la photo qui échouait, le bois est
  //    à 115,85,44 et la couverture contient une planche en bois et des bruns
  //    dorés exactement de cette teinte. Un seuil de couleur les garde avec le
  //    fond, et le livre ressort en morceaux.
  //
  //    La texture ne suffit pas non plus : la bande sombre du titre et
  //    l'assiette blanche sont lisses, aussi lisses que la table.
  //
  //    Leur union, si. Un pixel appartient au document s'il est loin du fond
  //    par la couleur **ou** plus texturé que lui.
  final bande = math.max(4, (math.min(w, h) * 0.06).round());
  bool surLaBande(int x, int y) =>
      x < bande || x >= w - bande || y < bande || y >= h - bande;

  // 2a. Texture : écart-type de la luminance sur une fenêtre de neuf pixels,
  //     calculé par images intégrales — sans elles, chaque pixel relirait
  //     quatre-vingt-une valeurs.
  final lum = List.generate(h, (_) => List.filled(w, 0.0));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = zone.getPixel(x, y);
      lum[y][x] = px.r * 0.299 + px.g * 0.587 + px.b * 0.114;
    }
  }
  final ecartLocal = _ecartTypeLocal(lum, w, h, 4);

  // 2b. Couleur : médiane de la bande, puis **raffinement**.
  //
  //     La bande n'est pas toujours pure. Sur la photo mesurée, elle contenait
  //     un ordinateur noir sur toute la hauteur gauche : la moitié de ses
  //     pixels. La dispersion brute en sortait à 171, un seuil qui laissait
  //     passer le livre entier. On ne garde donc, pour mesurer la dispersion,
  //     que les pixels de bande proches de la médiane — le vrai fond.
  final rs = <int>[], gs = <int>[], bs = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!surLaBande(x, y)) continue;
      final px = zone.getPixel(x, y);
      rs.add(px.r.toInt());
      gs.add(px.g.toInt());
      bs.add(px.b.toInt());
    }
  }
  if (rs.length < 64) {
    diag['sortie'] = 'bande_insuffisante';
    return QuadDetection(diagnostic: diag);
  }

  final fondR = _mediane(rs);
  final fondG = _mediane(gs);
  final fondB = _mediane(bs);

  final distance = List.generate(h, (_) => List.filled(w, 0.0));
  final distancesFond = <double>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final px = zone.getPixel(x, y);
      final d = _distanceCouleur(
        px.r.toInt(),
        px.g.toInt(),
        px.b.toInt(),
        fondR,
        fondG,
        fondB,
      );
      distance[y][x] = d;
      if (surLaBande(x, y)) distancesFond.add(d);
    }
  }

  final proches = distancesFond.where((d) => d < 70).toList()..sort();

  // La bande décrit-elle UN fond, ou plusieurs ?
  //
  // L'hypothèse « les bords montrent la table » tient tant que les bords ne
  // montrent que la table. Mesuré sur deux photos : sur la première, 81 % des
  // pixels de bande se serrent autour de leur médiane — c'est du bois. Sur la
  // seconde, 33 % seulement : à gauche un objet noir, à droite un canapé
  // sombre, et la médiane sort à 62,65,63. Le bois, lui, se retrouve à 110 de
  // ce faux fond et passe pour du document.
  //
  // Quand la bande n'est pas cohérente, la couleur ne dit plus rien de fiable
  // et **on ne s'en sert pas**. La texture, elle, reste vraie : une table est
  // lisse, un canapé aussi, un objet noir aussi — une couverture imprimée non.
  final coherence = distancesFond.isEmpty
      ? 0.0
      : proches.length / distancesFond.length;
  final couleurFiable = coherence >= 0.55 && proches.length > 64;
  diag['coherence_fond'] = (coherence * 100).round();
  diag['couleur_fiable'] = couleurFiable;

  final reference = couleurFiable ? proches : (distancesFond..sort());
  final seuilCouleur = math.max(
    28.0,
    reference[(reference.length * 0.90).round().clamp(
          0,
          reference.length - 1,
        )] *
        1.5,
  );

  // La texture du fond se mesure sur les pixels de bande qui SONT le fond.
  //
  //    Mesurée sur toute la bande, elle sortait à 31 au lieu de 19 : la bande
  //    longe un ordinateur noir, et la frontière ordinateur/table est un bord
  //    franc, donc très texturé. Un seuil gonflé par ce bord laisse ensuite
  //    passer la moitié du livre.
  //
  //    On ne garde donc que les pixels de bande dont la COULEUR est déjà celle
  //    du fond. Les deux mesures se tiennent : la couleur filtre, la texture
  //    complète.
  // La texture du fond se mesure sur les pixels de bande qui SONT le fond.
  //
  // Quand la couleur est fiable, elle sert de filtre : seuls les pixels déjà
  // de la bonne teinte comptent. Prise sur toute la bande, la mesure sortait à
  // 31 au lieu de 19 sur la première photo — la frontière ordinateur/table est
  // un bord franc, donc très texturé.
  //
  // Quand elle ne l'est pas, aucun filtre n'est possible : on prend toute la
  // bande, au 75e centile plutôt qu'au 90e. Les frontières entre les objets du
  // fond y sont, et un centile plus bas les laisse dehors.
  final texturesFond = <double>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!surLaBande(x, y)) continue;
      if (couleurFiable && distance[y][x] >= 70) continue;
      texturesFond.add(ecartLocal[y][x]);
    }
  }
  texturesFond.sort();
  final centile = couleurFiable ? 0.90 : 0.75;
  final seuilTexture = texturesFond.length > 64
      ? math.max(
          6.0,
          texturesFond[(texturesFond.length * centile).round().clamp(
                0,
                texturesFond.length - 1,
              )] *
              1.3,
        )
      : 12.0;

  diag['fond_rgb'] = '$fondR,$fondG,$fondB';
  diag['bande_px'] = distancesFond.length;
  diag['bande_proches'] = proches.length;
  diag['seuil_couleur'] = seuilCouleur.round();
  diag['seuil_texture'] = seuilTexture.round();

  // 3. Masque : loin du fond par la couleur, ou plus texturé que lui.
  var masque = List.generate(h, (_) => List.filled(w, false));
  var marques = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final loinParLaCouleur = couleurFiable && distance[y][x] > seuilCouleur;
      if (loinParLaCouleur || ecartLocal[y][x] > seuilTexture) {
        masque[y][x] = true;
        marques++;
      }
    }
  }
  // La bande qui a servi de modele EST le fond : l'y marquer comme document
  // serait se contredire. Cela empeche aussi la tache de sortir par le bord et
  // d'emporter le bois au-dela.
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (surLaBande(x, y) && masque[y][x]) {
        masque[y][x] = false;
        marques--;
      }
    }
  }
  diag['part_marquee'] = (marques / (w * h) * 100).round();

  // 4. Nettoyage.
  //
  //    Ouverture d'abord : elle efface le grain isolé du bois, qui passe le
  //    seuil de texture par endroits. Fermeture ensuite : elle recolle le trait
  //    du contour là où il s'interrompt. Remplissage enfin : tout ce qui n'est
  //    pas relié au bord de l'image appartient au document — c'est ainsi que
  //    l'assiette blanche, lisse et de couleur proche du fond, rejoint le livre
  //    au lieu de le trouer.
  masque = _dilate(_erode(masque, w, h, 3), w, h, 3);
  masque = _erode(_dilate(masque, w, h, 3), w, h, 3);
  masque = _boucheLesTrous(masque, w, h);

  // 5. Plus grande tache connexe.
  final tache = _plusGrandeComposante(masque, w, h);
  if (tache == null) {
    diag['sortie'] = 'aucune_tache';
    return QuadDetection(diagnostic: diag);
  }

  final aireTache = tache.length / (w * h);
  diag['aire_tache'] = (aireTache * 100).round();

  // Etendue de la tache, pour distinguer une tache qui deborde d'un rectangle
  // qui s'etire : les deux donnent la meme aire finale et ne se corrigent pas
  // au meme endroit.
  var bx0 = w, by0 = h, bx1 = 0, by1 = 0;
  for (final i in tache) {
    final x = i % w, y = i ~/ w;
    if (x < bx0) bx0 = x;
    if (x > bx1) bx1 = x;
    if (y < by0) by0 = y;
    if (y > by1) by1 = y;
  }
  diag['tache_bbox'] =
      '${(bx0 / w * 100).round()} ${(by0 / h * 100).round()} '
      '${(bx1 / w * 100).round()} ${(by1 / h * 100).round()}';

  // Trop petit : une assiette, un reflet, une ombre — et le cas où le livre
  // remplit la photo, où le fond modélisé EST le livre et où la seule tache
  // trouvée est un aplat de la couverture. Trop grand : le fond lui-même a été
  // pris pour le document, il n'y a rien à recadrer.
  //
  // Le plancher vaut un quart de l'image. L'écran repasse ensuite un contrôle
  // à 35 % avant d'adopter le cadre : le premier écarte l'absurde, le second
  // décide.
  if (aireTache < kAtelierAireMinimale || aireTache > 0.97) {
    diag['sortie'] = 'aire_tache_hors_bornes';
    return QuadDetection(diagnostic: diag);
  }

  // 6. Rectangle d'aire minimale autour de la tache.
  //
  //    Un livre est un rectangle : son image, photographiée à peu près de face,
  //    en est un tourné. Chercher un quadrilatère libre inviterait le bruit à
  //    tirer un coin ; chercher un rectangle contraint la forme à ce qu'on sait
  //    d'elle.
  final contour = _contourParLigne(tache, w, h);
  if (contour.length < 8) {
    diag['sortie'] = 'contour_trop_court';
    return QuadDetection(diagnostic: diag);
  }
  final brut = _rectangleAireMinimale(contour);
  if (brut == null) {
    diag['sortie'] = 'rectangle_introuvable';
    return QuadDetection(diagnostic: diag);
  }
  // Le rectangle brut fait foi.
  //
  // Un recalage sur les bords a ete essaye : glisser chaque cote le long de sa
  // normale et garder la position ou le gradient est le plus fort. Mesure sur
  // deux photos, il tirait les cotes vers les contours INTERIEURS de la
  // couverture -- le bord d une assiette, la bande du titre, plus francs que
  // la frontiere carton/table -- et le cadre entrait dans le livre. Restreint
  // a cinq pour cent et conditionne a un gain d un quart, il rognait encore
  // cinq pour cent du livre sans rien corriger ailleurs. Retire.
  final rect = brut.coins;
  final aireRect = _aireQuad(rect) / (w * h);
  diag['aire_rect'] = (aireRect * 100).round();
  if (aireRect < kAtelierAireMinimale || aireRect > 0.98) {
    diag['sortie'] = 'aire_rect_hors_bornes';
    return QuadDetection(diagnostic: diag);
  }

  final ordonne = _ordonneCoins(rect);
  // Retour dans le repère de l'image entière : les coins ont été trouvés dans
  // la zone rognée, l'écran les pose sur la photo complète.
  final quad = [
    for (final c in ordonne) ...[
      ((bandes.x0 + c.dx) / pleineW).clamp(0.0, 1.0),
      ((bandes.y0 + c.dy) / pleineH).clamp(0.0, 1.0),
    ],
  ];
  diag['sortie'] = 'quadrilatere';
  diag['coins'] = quad.map((v) => (v * 1000).round() / 1000).join(' ');
  return QuadDetection(quad: quad, diagnostic: diag);
}

/// Ce qui reste de l'image une fois ses bandes uniformes retirées.
class BandesUniformes {
  final int x0, y0, x1, y1;
  const BandesUniformes(this.x0, this.y0, this.x1, this.y1);

  bool estPleine(int w, int h) => x0 == 0 && y0 == 0 && x1 == w && y1 == h;
}

/// Repère les bandes unies qui bordent une photo.
///
/// Une bande est une suite de lignes — ou de colonnes — dont la couleur ne
/// varie pas et qui ne ressemble pas au centre de l'image. C'est ce que
/// produisent les bandes noires d'une photo de téléphone, et ce n'est pas la
/// scène : les laisser fausse le modèle du fond, qui se prend pour du noir
/// alors que le sujet est posé sur du bois.
///
/// Le rognage est borné à 30 % par côté : au-delà, ce n'est plus une bordure,
/// c'est le sujet.
BandesUniformes _bandesUniformes(img.Image im) {
  final w = im.width, h = im.height;

  // Couleur du centre, pour savoir de quoi la bande doit se distinguer.
  final cr = <int>[], cg = <int>[], cb = <int>[];
  for (var y = (h * 0.35).round(); y < (h * 0.65).round(); y += 2) {
    for (var x = (w * 0.35).round(); x < (w * 0.65).round(); x += 2) {
      final px = im.getPixel(x, y);
      cr.add(px.r.toInt());
      cg.add(px.g.toInt());
      cb.add(px.b.toInt());
    }
  }
  if (cr.length < 16) return BandesUniformes(0, 0, w, h);
  final centreR = _mediane(cr), centreG = _mediane(cg), centreB = _mediane(cb);

  /// Une ligne ou une colonne est-elle une bande ?
  bool estUneBande(List<int> rs, List<int> gs, List<int> bs) {
    if (rs.length < 8) return false;
    final mr = _mediane(rs), mg = _mediane(gs), mb = _mediane(bs);

    // SOMBRE. C'est le point qui distingue une bande d'un fond.
    //
    // La première version demandait seulement « unie et différente du centre » :
    // la table claire répondait à la définition, et le rognage mangeait le fond
    // qu'il devait préserver. Une bordure de capteur est noire ; une table ne
    // l'est pas.
    final luminance = mr * 0.299 + mg * 0.587 + mb * 0.114;
    if (luminance > 40) return false;

    // Loin du centre : sinon c'est le sujet lui-même, sombre et uni.
    if (_distanceCouleur(mr, mg, mb, centreR, centreG, centreB) < 60) {
      return false;
    }

    // Franchement unie : une bande de capteur n'a pas de grain, une ombre si.
    final ecarts = <int>[];
    for (var i = 0; i < rs.length; i++) {
      ecarts.add(_distanceCouleur(rs[i], gs[i], bs[i], mr, mg, mb).round());
    }
    return _mediane(ecarts) < 10;
  }

  List<List<int>> ligne(int y) {
    final rs = <int>[], gs = <int>[], bs = <int>[];
    for (var x = 0; x < w; x += 2) {
      final px = im.getPixel(x, y);
      rs.add(px.r.toInt());
      gs.add(px.g.toInt());
      bs.add(px.b.toInt());
    }
    return [rs, gs, bs];
  }

  List<List<int>> colonne(int x) {
    final rs = <int>[], gs = <int>[], bs = <int>[];
    for (var y = 0; y < h; y += 2) {
      final px = im.getPixel(x, y);
      rs.add(px.r.toInt());
      gs.add(px.g.toInt());
      bs.add(px.b.toInt());
    }
    return [rs, gs, bs];
  }

  final maxY = (h * 0.30).round();
  final maxX = (w * 0.30).round();

  var y0 = 0;
  while (y0 < maxY) {
    final l = ligne(y0);
    if (!estUneBande(l[0], l[1], l[2])) break;
    y0++;
  }
  var y1 = h;
  while (h - y1 < maxY && y1 > y0 + 8) {
    final l = ligne(y1 - 1);
    if (!estUneBande(l[0], l[1], l[2])) break;
    y1--;
  }
  var x0 = 0;
  while (x0 < maxX) {
    final c = colonne(x0);
    if (!estUneBande(c[0], c[1], c[2])) break;
    x0++;
  }
  var x1 = w;
  while (w - x1 < maxX && x1 > x0 + 8) {
    final c = colonne(x1 - 1);
    if (!estUneBande(c[0], c[1], c[2])) break;
    x1--;
  }

  return BandesUniformes(x0, y0, x1, y1);
}

/// Écart-type de la luminance sur une fenêtre carrée, par images intégrales.
///
/// C'est la mesure de texture qui distingue une couverture imprimée d'une
/// table : la première est une photographie, la seconde est lisse. Sans les
/// images intégrales, chaque pixel relirait les quatre-vingt-une valeurs de sa
/// fenêtre — vingt millions de lectures sur une image réduite.
List<List<double>> _ecartTypeLocal(
  List<List<double>> lum,
  int w,
  int h,
  int rayon,
) {
  final s1 = List.generate(h + 1, (_) => List.filled(w + 1, 0.0));
  final s2 = List.generate(h + 1, (_) => List.filled(w + 1, 0.0));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = lum[y][x];
      s1[y + 1][x + 1] = v + s1[y][x + 1] + s1[y + 1][x] - s1[y][x];
      s2[y + 1][x + 1] = v * v + s2[y][x + 1] + s2[y + 1][x] - s2[y][x];
    }
  }
  double bloc(List<List<double>> s, int x0, int y0, int x1, int y1) =>
      s[y1][x1] - s[y0][x1] - s[y1][x0] + s[y0][x0];

  final out = List.generate(h, (_) => List.filled(w, 0.0));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final x0 = math.max(0, x - rayon), y0 = math.max(0, y - rayon);
      final x1 = math.min(w, x + rayon + 1), y1 = math.min(h, y + rayon + 1);
      final n = (x1 - x0) * (y1 - y0);
      final moyenne = bloc(s1, x0, y0, x1, y1) / n;
      final carres = bloc(s2, x0, y0, x1, y1) / n;
      out[y][x] = math.sqrt(math.max(0.0, carres - moyenne * moyenne));
    }
  }
  return out;
}

/// Rattache au document tout ce que le fond n'atteint pas depuis les bords.
///
/// L'assiette blanche de la couverture est lisse et pâle : ni la texture ni la
/// couleur ne la distinguent de la table. Elle creusait donc un trou au milieu
/// du livre. Mais elle est **entourée** par le livre, et le fond ne peut pas
/// l'atteindre en partant du bord de l'image : c'est ce qui la trahit.
List<List<bool>> _boucheLesTrous(List<List<bool>> m, int w, int h) {
  final dehors = List.generate(h, (_) => List.filled(w, false));
  final pile = <int>[];

  void pousse(int x, int y) {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    if (dehors[y][x] || m[y][x]) return;
    dehors[y][x] = true;
    pile.add(y * w + x);
  }

  for (var x = 0; x < w; x++) {
    pousse(x, 0);
    pousse(x, h - 1);
  }
  for (var y = 0; y < h; y++) {
    pousse(0, y);
    pousse(w - 1, y);
  }
  while (pile.isNotEmpty) {
    final i = pile.removeLast();
    final x = i % w, y = i ~/ w;
    pousse(x - 1, y);
    pousse(x + 1, y);
    pousse(x, y - 1);
    pousse(x, y + 1);
  }

  return List.generate(
    h,
    (y) => List.generate(w, (x) => m[y][x] || !dehors[y][x]),
  );
}

double _distanceCouleur(int r, int g, int b, int mr, int mg, int mb) {
  final dr = (r - mr).toDouble();
  final dg = (g - mg).toDouble();
  final db = (b - mb).toDouble();
  return math.sqrt(dr * dr + dg * dg + db * db);
}

int _mediane(List<int> valeurs) {
  final tri = List<int>.from(valeurs)..sort();
  return tri[tri.length ~/ 2];
}

List<List<bool>> _dilate(List<List<bool>> m, int w, int h, int rayon) {
  final out = List.generate(h, (_) => List.filled(w, false));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      if (!m[y][x]) continue;
      for (var dy = -rayon; dy <= rayon; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -rayon; dx <= rayon; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          out[yy][xx] = true;
        }
      }
    }
  }
  return out;
}

List<List<bool>> _erode(List<List<bool>> m, int w, int h, int rayon) {
  final out = List.generate(h, (_) => List.filled(w, false));
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var plein = true;
      for (var dy = -rayon; dy <= rayon && plein; dy++) {
        final yy = (y + dy).clamp(0, h - 1);
        for (var dx = -rayon; dx <= rayon; dx++) {
          final xx = (x + dx).clamp(0, w - 1);
          if (!m[yy][xx]) {
            plein = false;
            break;
          }
        }
      }
      out[y][x] = plein;
    }
  }
  return out;
}

/// Plus grande composante connexe (4-connexité), rendue comme liste d'indices.
List<int>? _plusGrandeComposante(List<List<bool>> m, int w, int h) {
  final vu = List.filled(w * h, false);
  List<int>? meilleure;
  final pile = <int>[];

  for (var depart = 0; depart < w * h; depart++) {
    if (vu[depart] || !m[depart ~/ w][depart % w]) continue;
    final courante = <int>[];
    pile
      ..clear()
      ..add(depart);
    vu[depart] = true;

    while (pile.isNotEmpty) {
      final i = pile.removeLast();
      courante.add(i);
      final x = i % w;
      final y = i ~/ w;
      if (x > 0 && !vu[i - 1] && m[y][x - 1]) {
        vu[i - 1] = true;
        pile.add(i - 1);
      }
      if (x < w - 1 && !vu[i + 1] && m[y][x + 1]) {
        vu[i + 1] = true;
        pile.add(i + 1);
      }
      if (y > 0 && !vu[i - w] && m[y - 1][x]) {
        vu[i - w] = true;
        pile.add(i - w);
      }
      if (y < h - 1 && !vu[i + w] && m[y + 1][x]) {
        vu[i + w] = true;
        pile.add(i + w);
      }
    }

    if (meilleure == null || courante.length > meilleure.length) {
      meilleure = courante;
    }
  }
  return meilleure;
}

/// Contour de la tache : les deux extrêmes de chaque ligne.
///
/// Suffit à porter l'enveloppe convexe, et borne l'entrée du rectangle à deux
/// points par ligne au lieu de deux cent mille.
List<Offset> _contourParLigne(List<int> tache, int w, int h) {
  final gauche = List.filled(h, -1);
  final droite = List.filled(h, -1);
  for (final i in tache) {
    final x = i % w;
    final y = i ~/ w;
    if (gauche[y] < 0 || x < gauche[y]) gauche[y] = x;
    if (droite[y] < 0 || x > droite[y]) droite[y] = x;
  }
  final points = <Offset>[];
  for (var y = 0; y < h; y++) {
    if (gauche[y] < 0) continue;
    points.add(Offset(gauche[y].toDouble(), y.toDouble()));
    points.add(Offset(droite[y].toDouble(), y.toDouble()));
  }
  return points;
}

/// Un rectangle tourné, décrit par son angle et ses quatre bornes.
class RectangleTourne {
  final double angle;
  final double u0, u1, v0, v1;

  const RectangleTourne(this.angle, this.u0, this.u1, this.v0, this.v1);

  Offset _versImage(double u, double v) {
    final c = math.cos(angle), s = math.sin(angle);
    return Offset(u * c - v * s, u * s + v * c);
  }

  List<Offset> get coins => [
    _versImage(u0, v0),
    _versImage(u1, v0),
    _versImage(u1, v1),
    _versImage(u0, v1),
  ];

  RectangleTourne avecBornes(double nu0, double nu1, double nv0, double nv1) =>
      RectangleTourne(angle, nu0, nu1, nv0, nv1);
}

/// Rectangle tourné d'aire minimale contenant tous les points.
///
/// Balayage d'un quart de tour par pas d'un degré : à cette échelle, un degré
/// d'erreur déplace un coin de moins de trois pixels sur 512, et le coût reste
/// de quelques milliers d'opérations.
RectangleTourne? _rectangleAireMinimale(List<Offset> points) {
  if (points.length < 4) return null;
  double meilleureAire = double.infinity;
  RectangleTourne? meilleur;

  for (var deg = 0; deg < 90; deg++) {
    final a = deg * math.pi / 180.0;
    final cosA = math.cos(a), sinA = math.sin(a);
    var minU = double.infinity, maxU = -double.infinity;
    var minV = double.infinity, maxV = -double.infinity;
    for (final p in points) {
      final u = p.dx * cosA + p.dy * sinA;
      final v = -p.dx * sinA + p.dy * cosA;
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final aire = (maxU - minU) * (maxV - minV);
    if (aire >= meilleureAire) continue;
    meilleureAire = aire;
    meilleur = RectangleTourne(a, minU, maxU, minV, maxV);
  }
  return meilleur;
}

double _aireQuad(List<Offset> q) {
  var s = 0.0;
  for (var i = 0; i < q.length; i++) {
    final a = q[i], b = q[(i + 1) % q.length];
    s += a.dx * b.dy - b.dx * a.dy;
  }
  return s.abs() / 2;
}

/// Range les quatre coins en haut-gauche, haut-droit, bas-droit, bas-gauche.
List<Offset> _ordonneCoins(List<Offset> quad) {
  final cx = quad.map((p) => p.dx).reduce((a, b) => a + b) / quad.length;
  final cy = quad.map((p) => p.dy).reduce((a, b) => a + b) / quad.length;
  final tri = List<Offset>.from(quad)
    ..sort(
      (a, b) => math
          .atan2(a.dy - cy, a.dx - cx)
          .compareTo(math.atan2(b.dy - cy, b.dx - cx)),
    );
  // Le tri par angle part de la gauche ; on repart du coin le plus haut-gauche
  // pour que l'ordre soit celui qu'attend le redressement.
  var depart = 0;
  var meilleur = double.infinity;
  for (var i = 0; i < tri.length; i++) {
    final somme = tri[i].dx + tri[i].dy;
    if (somme < meilleur) {
      meilleur = somme;
      depart = i;
    }
  }
  return [for (var i = 0; i < 4; i++) tri[(depart + i) % 4]];
}
