/// Redressement par homographie, à haute résolution.
///
/// DÉRIVÉ de `warpIsolate` (`core/presentation/image_enhancer_processing.dart`),
/// dont la géométrie est reprise à l'identique. Une seule chose change, et elle
/// est décisive : **le plafond de travail**.
///
/// L'atelier de retouche plafonne à 2048 px, ce qui lui suffit — une photo
/// retouchée s'y regarde, elle ne s'y lit pas. Une double page extraite d'une
/// photo ainsi bornée sort autour de 650 px de large, et le corps de texte y
/// mesure cinq pixels de haut. Aucun modèle ne peut lire ça : sommé de dire
/// dans quel sens court le texte, il invente un titre plausible et se trompe
/// avec aplomb.
///
/// Ce plafond-ci est à 4000 px. La même double page en ressort autour de
/// 1300 px, et le texte devient lisible. Le coût est une boucle quatre fois
/// plus longue, dans un isolate, sur une seule image.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

class SandboxWarpParams {
  final Uint8List bytes;

  /// `[x0,y0, x1,y1, x2,y2, x3,y3]` en fraction de l'image, dans l'ordre
  /// haut-gauche, haut-droit, bas-droit, bas-gauche.
  final List<double> cornersFlat;

  /// Côté long au-delà duquel l'image est réduite avant le calcul.
  final int maxDimension;

  const SandboxWarpParams({
    required this.bytes,
    required this.cornersFlat,
    this.maxDimension = 4000,
  });
}

class SandboxWarpResult {
  final Uint8List bytes;
  final int width;
  final int height;

  const SandboxWarpResult({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Redresse le quadrilatère et rend un rectangle.
SandboxWarpResult sandboxWarpIsolate(SandboxWarpParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) throw Exception('Image illisible.');

  final longest = math.max(source.width, source.height);
  final factor = longest > p.maxDimension ? p.maxDimension / longest : 1.0;
  final work = factor < 1
      ? img.copyResize(
          source,
          width: (source.width * factor).round(),
          height: (source.height * factor).round(),
          interpolation: img.Interpolation.linear,
        )
      : source;

  final width = work.width.toDouble();
  final height = work.height.toDouble();
  final corners = [
    for (var i = 0; i < 4; i++)
      Offset(p.cornersFlat[i * 2] * width, p.cornersFlat[i * 2 + 1] * height),
  ];

  // Moyenne GÉOMÉTRIQUE des deux bords opposés, et non le plus grand des deux :
  // en perspective le bord proche est plus long que le bord lointain, et
  // retenir le maximum étire l'image dans un sens.
  final topWidth = (corners[1] - corners[0]).distance;
  final bottomWidth = (corners[2] - corners[3]).distance;
  final leftHeight = (corners[3] - corners[0]).distance;
  final rightHeight = (corners[2] - corners[1]).distance;
  final outWidth = math.sqrt(topWidth * bottomWidth).round();
  final outHeight = math.sqrt(leftHeight * rightHeight).round();
  if (outWidth < 8 || outHeight < 8) {
    throw Exception('Zone à redresser trop petite.');
  }

  final destination = [
    const Offset(0, 0),
    Offset(outWidth.toDouble(), 0),
    Offset(outWidth.toDouble(), outHeight.toDouble()),
    Offset(0, outHeight.toDouble()),
  ];
  final inverse = _invert(_homography(corners, destination));

  final out = img.Image(width: outWidth, height: outHeight);
  for (var y = 0; y < outHeight; y++) {
    for (var x = 0; x < outWidth; x++) {
      final denominator = inverse[6] * x + inverse[7] * y + inverse[8];
      final sx = (inverse[0] * x + inverse[1] * y + inverse[2]) / denominator;
      final sy = (inverse[3] * x + inverse[4] * y + inverse[5]) / denominator;
      _bilinear(out, x, y, work, sx, sy);
    }
  }

  return SandboxWarpResult(
    bytes: Uint8List.fromList(img.encodeJpg(out, quality: 95)),
    width: outWidth,
    height: outHeight,
  );
}

/// Interpolation bilinéaire : sans elle, chaque diagonale porte des escaliers,
/// et c'est précisément ce qu'on cherchait à corriger.
void _bilinear(
  img.Image out,
  int x,
  int y,
  img.Image source,
  double sx,
  double sy,
) {
  if (sx < 0 || sy < 0 || sx > source.width - 1 || sy > source.height - 1) {
    return;
  }
  final x0 = sx.floor();
  final y0 = sy.floor();
  final x1 = math.min(x0 + 1, source.width - 1);
  final y1 = math.min(y0 + 1, source.height - 1);
  final fx = sx - x0;
  final fy = sy - y0;

  final p00 = source.getPixel(x0, y0);
  final p10 = source.getPixel(x1, y0);
  final p01 = source.getPixel(x0, y1);
  final p11 = source.getPixel(x1, y1);

  double mix(num a, num b, num c, num d) =>
      a * (1 - fx) * (1 - fy) +
      b * fx * (1 - fy) +
      c * (1 - fx) * fy +
      d * fx * fy;

  out.setPixelRgb(
    x,
    y,
    mix(p00.r, p10.r, p01.r, p11.r).round().clamp(0, 255),
    mix(p00.g, p10.g, p01.g, p11.g).round().clamp(0, 255),
    mix(p00.b, p10.b, p01.b, p11.b).round().clamp(0, 255),
  );
}

/// Homographie envoyant `src` sur `dst`, en coordonnées normalisées.
///
/// La normalisation de Hartley n'est pas un raffinement : sans elle, le système
/// linéaire mêle des coordonnées de l'ordre du millier à des produits de
/// l'ordre du million, et la résolution perd ses décimales là où elles comptent.
List<double> _homography(List<Offset> src, List<Offset> dst) {
  final ts = _normalization(src);
  final td = _normalization(dst);
  final ns = _applyNormalization(ts, src);
  final nd = _applyNormalization(td, dst);

  final a = <List<double>>[];
  final b = <double>[];
  for (var i = 0; i < 4; i++) {
    final sx = ns[i].dx, sy = ns[i].dy;
    final dx = nd[i].dx, dy = nd[i].dy;
    a.add([sx, sy, 1, 0, 0, 0, -sx * dx, -sy * dx]);
    b.add(dx);
    a.add([0, 0, 0, sx, sy, 1, -sx * dy, -sy * dy]);
    b.add(dy);
  }

  final h = _solve(a, b);
  final normalized = [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1.0];
  return _multiply(_invert(td), _multiply(normalized, ts));
}

List<double> _normalization(List<Offset> points) {
  var cx = 0.0, cy = 0.0;
  for (final point in points) {
    cx += point.dx;
    cy += point.dy;
  }
  cx /= points.length;
  cy /= points.length;

  var sum = 0.0;
  for (final point in points) {
    sum += math.sqrt(
      (point.dx - cx) * (point.dx - cx) + (point.dy - cy) * (point.dy - cy),
    );
  }
  final mean = sum / points.length;
  final scale = mean > 1e-8 ? math.sqrt2 / mean : 1.0;
  return [scale, 0, -scale * cx, 0, scale, -scale * cy, 0, 0, 1];
}

List<Offset> _applyNormalization(List<double> t, List<Offset> points) => [
  for (final point in points)
    Offset(t[0] * point.dx + t[2], t[4] * point.dy + t[5]),
];

List<double> _multiply(List<double> a, List<double> b) {
  final c = List<double>.filled(9, 0);
  for (var row = 0; row < 3; row++) {
    for (var column = 0; column < 3; column++) {
      for (var k = 0; k < 3; k++) {
        c[row * 3 + column] += a[row * 3 + k] * b[k * 3 + column];
      }
    }
  }
  return c;
}

List<double> _invert(List<double> m) {
  final a = m[0], b = m[1], c = m[2];
  final d = m[3], e = m[4], f = m[5];
  final g = m[6], h = m[7], i = m[8];
  final determinant =
      a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (determinant.abs() < 1e-12) {
    throw Exception('Homographie non inversible.');
  }
  final inv = 1 / determinant;
  return [
    (e * i - f * h) * inv,
    (c * h - b * i) * inv,
    (b * f - c * e) * inv,
    (f * g - d * i) * inv,
    (a * i - c * g) * inv,
    (c * d - a * f) * inv,
    (d * h - e * g) * inv,
    (b * g - a * h) * inv,
    (a * e - b * d) * inv,
  ];
}

/// Élimination de Gauss avec pivot partiel.
List<double> _solve(List<List<double>> a, List<double> b) {
  final n = b.length;
  final matrix = [
    for (var i = 0; i < n; i++) [...a[i], b[i]],
  ];

  for (var column = 0; column < a[0].length; column++) {
    var pivot = column;
    for (var row = column + 1; row < n; row++) {
      if (matrix[row][column].abs() > matrix[pivot][column].abs()) pivot = row;
    }
    final swap = matrix[column];
    matrix[column] = matrix[pivot];
    matrix[pivot] = swap;

    final head = matrix[column][column];
    if (head.abs() < 1e-12) continue;
    for (var k = column; k <= a[0].length; k++) {
      matrix[column][k] /= head;
    }
    for (var row = 0; row < n; row++) {
      if (row == column) continue;
      final factor = matrix[row][column];
      if (factor == 0) continue;
      for (var k = column; k <= a[0].length; k++) {
        matrix[row][k] -= factor * matrix[column][k];
      }
    }
  }

  return [for (var i = 0; i < a[0].length; i++) matrix[i][a[0].length]];
}
