/// Recalage du cadre de la page sur le bord réel du papier.
///
/// Le modèle place la page à quelques pour cent près, et ces quelques pour cent
/// se voient : un pied de cadre qui déborde de vingt pour cent emporte une bande
/// de serviette, et le redressement l'étire dans la page.
///
/// Ce fichier ne cherche pas la page — c'est le travail du modèle, et deux
/// tentatives sans lui ont échoué (voir `sandbox_image_ops.dart`). Il **resserre
/// un cadre déjà posé sur elle**, dans une bande étroite. C'est ce qui le rend
/// sûr : il ne peut pas repartir sur le support.
///
/// La méthode, pour chaque côté : essayer toutes les translations d'une bande
/// étroite et toutes les inclinaisons de plus ou moins six degrés, et noter
/// chaque candidat par la **moyenne du gradient perpendiculaire le long de la
/// droite entière**. Un vrai bord de papier est une longue ligne droite : il
/// ressort franchement. Une ombre, un pli de tissu, une ligne de texte ne sont
/// jamais aussi longs ni aussi rectilignes.
///
/// Deux règles empêchent le cadre de partir :
///
/// - un candidat doit être **nettement** meilleur que la position de départ,
///   pas seulement meilleur ;
/// - à score presque égal, le plus proche du cadre du modèle l'emporte. C'est
///   ce qui évite de sauter sur le bord de la serviette quand il passe dans la
///   bande.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

class SandboxSnapParams {
  final Uint8List bytes;

  /// Le cadre rendu par le modèle : `[x0,y0, x1,y1, x2,y2, x3,y3]` en fraction
  /// de l'image, dans l'ordre haut-gauche, haut-droit, bas-droit, bas-gauche.
  final List<double> cornersFlat;

  const SandboxSnapParams({required this.bytes, required this.cornersFlat});
}

class SandboxSnapResult {
  /// Le cadre recalé, même forme que l'entrée. Identique à l'entrée quand rien
  /// n'a été jugé assez net pour bouger.
  final List<double> cornersFlat;

  /// Combien des quatre côtés ont trouvé un bord franc.
  final int sidesSnapped;

  /// De combien le coin le plus déplacé a bougé, en fraction du côté long.
  final double maxShift;

  /// Pourquoi le recalage a été abandonné, quand il l'a été.
  final String? rejected;

  const SandboxSnapResult({
    required this.cornersFlat,
    required this.sidesSnapped,
    required this.maxShift,
    this.rejected,
  });

  bool get applied => sidesSnapped > 0 && rejected == null;
}

/// Largeur de la bande fouillée de part et d'autre du bord, en part de la page.
const double _band = 0.16;

/// Inclinaison explorée autour de chaque côté, en degrés.
const double _maxAngle = 6;

/// Un candidat doit dépasser ce multiple du score de départ pour être adopté.
const double _dominance = 1.15;

/// Recale les quatre côtés du cadre sur le bord réel du papier.
SandboxSnapResult sandboxSnapQuadIsolate(SandboxSnapParams p) {
  final decoded = img.decodeImage(p.bytes);
  if (decoded == null) {
    return SandboxSnapResult(
      cornersFlat: p.cornersFlat,
      sidesSnapped: 0,
      maxShift: 0,
      rejected: 'Image illisible.',
    );
  }

  // 1024 px : assez pour placer un bord au pixel près une fois ramené à
  // l'échelle, et bien moins de travail qu'à pleine résolution.
  const work = 1024;
  final scale = work / math.max(decoded.width, decoded.height);
  final width = scale < 1 ? (decoded.width * scale).round() : decoded.width;
  final height = scale < 1 ? (decoded.height * scale).round() : decoded.height;
  final small = scale < 1
      ? img.copyResize(
          decoded,
          width: width,
          height: height,
          interpolation: img.Interpolation.average,
        )
      : decoded;

  final gray = img.grayscale(small);
  final gx = Float32List(width * height);
  final gy = Float32List(width * height);
  for (int y = 1; y < height - 1; y++) {
    for (int x = 1; x < width - 1; x++) {
      int at(int px, int py) => gray.getPixel(px, py).r.round();
      gx[y * width + x] =
          (at(x + 1, y - 1) +
                  2 * at(x + 1, y) +
                  at(x + 1, y + 1) -
                  at(x - 1, y - 1) -
                  2 * at(x - 1, y) -
                  at(x - 1, y + 1))
              .toDouble();
      gy[y * width + x] =
          (at(x - 1, y + 1) +
                  2 * at(x, y + 1) +
                  at(x + 1, y + 1) -
                  at(x - 1, y - 1) -
                  2 * at(x, y - 1) -
                  at(x + 1, y - 1))
              .toDouble();
    }
  }

  final corners = [
    for (int i = 0; i < 4; i++)
      Offset(p.cornersFlat[i * 2] * width, p.cornersFlat[i * 2 + 1] * height),
  ];

  // La bande se mesure sur la dimension perpendiculaire au côté : un côté haut
  // se cherche sur la hauteur de la page, pas sur sa largeur.
  final pageWidth =
      ((corners[1] - corners[0]).distance +
          (corners[2] - corners[3]).distance) /
      2;
  final pageHeight =
      ((corners[3] - corners[0]).distance +
          (corners[2] - corners[1]).distance) /
      2;
  if (pageWidth < 16 || pageHeight < 16) {
    return SandboxSnapResult(
      cornersFlat: p.cornersFlat,
      sidesSnapped: 0,
      maxShift: 0,
      rejected: 'Cadre trop petit pour être recalé.',
    );
  }

  final lines = <_Line>[];
  var snapped = 0;
  for (int side = 0; side < 4; side++) {
    final band = math.max(8.0, (side.isEven ? pageHeight : pageWidth) * _band);
    final found = _snapSide(
      gx,
      gy,
      width,
      height,
      corners[side],
      corners[(side + 1) % 4],
      band,
    );
    lines.add(found.line);
    if (found.moved) snapped++;
  }

  final refined = <Offset>[];
  for (int i = 0; i < 4; i++) {
    final point = _intersect(lines[(i + 3) % 4], lines[i]);
    if (point == null) {
      return SandboxSnapResult(
        cornersFlat: p.cornersFlat,
        sidesSnapped: 0,
        maxShift: 0,
        rejected: 'Deux côtés recalés sont devenus parallèles.',
      );
    }
    refined.add(point);
  }

  // Garde-fous. Un recalage qui déplace un coin de plus que la bande fouillée,
  // ou qui change franchement l'aire, n'a pas recalé : il a trouvé autre chose.
  final longest = math.max(pageWidth, pageHeight);
  var maxShift = 0.0;
  for (int i = 0; i < 4; i++) {
    final shift = (refined[i] - corners[i]).distance;
    if (shift > maxShift) maxShift = shift;
  }
  final areaBefore = _area(corners);
  final areaAfter = _area(refined);
  if (maxShift > longest * _band * 1.5 ||
      !_isConvex(refined) ||
      areaAfter < areaBefore * 0.65 ||
      areaAfter > areaBefore * 1.5) {
    return SandboxSnapResult(
      cornersFlat: p.cornersFlat,
      sidesSnapped: 0,
      maxShift: 0,
      rejected:
          'Le cadre recalé s\'écarte trop de celui du modèle : celui du modèle '
          'est conservé.',
    );
  }

  return SandboxSnapResult(
    cornersFlat: [
      for (final corner in refined) ...[corner.dx / width, corner.dy / height],
    ],
    sidesSnapped: snapped,
    maxShift: longest > 0 ? maxShift / longest : 0,
  );
}

/// Une droite sous la forme `px·x + py·y = r`, `(px, py)` étant sa normale.
class _Line {
  final double px;
  final double py;
  final double r;

  const _Line(this.px, this.py, this.r);
}

class _Side {
  final _Line line;
  final bool moved;

  const _Side(this.line, this.moved);
}

_Side _snapSide(
  Float32List gx,
  Float32List gy,
  int width,
  int height,
  Offset a,
  Offset b,
  double band,
) {
  final length = (b - a).distance;
  final middle = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  final baseAngle = math.atan2(b.dy - a.dy, b.dx - a.dx);

  // Les extrémités sont écartées : près d'un coin, deux bords se croisent et le
  // gradient appartient autant à l'un qu'à l'autre.
  const samples = 48;
  const from = 0.08, to = 0.92;

  double scoreOf(double offset, double angleDegrees) {
    final angle = baseAngle + angleDegrees * math.pi / 180;
    final ux = math.cos(angle), uy = math.sin(angle);
    final nx = -uy, ny = ux;
    var total = 0.0;
    var counted = 0;
    for (int i = 0; i < samples; i++) {
      final t = from + (to - from) * i / (samples - 1);
      final along = (t - 0.5) * length;
      final x = (middle.dx + along * ux + offset * nx).round();
      final y = (middle.dy + along * uy + offset * ny).round();
      if (x < 1 || y < 1 || x >= width - 1 || y >= height - 1) continue;
      final index = y * width + x;
      total += (gx[index] * nx + gy[index] * ny).abs();
      counted++;
    }
    // Une droite qui sort du cadre sur plus d'un tiers de sa longueur ne se
    // compare pas aux autres : son score serait celui d'un tronçon.
    return counted < samples * 0.6 ? 0 : total / counted;
  }

  final startScore = scoreOf(0, 0);
  final step = math.max(1.0, band / 40);

  var bestScore = startScore;
  var bestOffset = 0.0;
  var bestAngle = 0.0;
  for (double offset = -band; offset <= band; offset += step) {
    for (double angle = -_maxAngle; angle <= _maxAngle; angle += 1) {
      final score = scoreOf(offset, angle);
      if (score > bestScore) {
        bestScore = score;
        bestOffset = offset;
        bestAngle = angle;
      }
    }
  }

  // Un bord doit être NETTEMENT meilleur que la position de départ pour la
  // remplacer. Sans cette exigence, le cadre glisse au moindre pli de tissu.
  if (bestScore <= 0 || bestScore < startScore * _dominance) {
    return _Side(_lineOf(middle, baseAngle, 0), false);
  }

  // À score presque égal, le plus proche du modèle l'emporte.
  var chosenOffset = bestOffset;
  var chosenAngle = bestAngle;
  var chosenDistance = bestOffset.abs();
  for (double offset = -band; offset <= band; offset += step) {
    if (offset.abs() >= chosenDistance) continue;
    for (double angle = -_maxAngle; angle <= _maxAngle; angle += 1) {
      if (scoreOf(offset, angle) >= bestScore * 0.85) {
        chosenOffset = offset;
        chosenAngle = angle;
        chosenDistance = offset.abs();
        break;
      }
    }
  }

  return _Side(
    _lineOf(middle, baseAngle + chosenAngle * math.pi / 180, chosenOffset),
    true,
  );
}

_Line _lineOf(Offset middle, double angle, double offset) {
  final ux = math.cos(angle), uy = math.sin(angle);
  final nx = -uy, ny = ux;
  final x = middle.dx + offset * nx;
  final y = middle.dy + offset * ny;
  return _Line(nx, ny, nx * x + ny * y);
}

Offset? _intersect(_Line a, _Line b) {
  final determinant = a.px * b.py - a.py * b.px;
  if (determinant.abs() < 1e-9) return null;
  return Offset(
    (a.r * b.py - b.r * a.py) / determinant,
    (a.px * b.r - b.px * a.r) / determinant,
  );
}

double _area(List<Offset> quad) {
  var sum = 0.0;
  for (int i = 0; i < quad.length; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % quad.length];
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  return sum.abs() / 2;
}

bool _isConvex(List<Offset> quad) {
  var sign = 0;
  for (int i = 0; i < 4; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % 4];
    final c = quad[(i + 2) % 4];
    final cross = (b.dx - a.dx) * (c.dy - b.dy) - (b.dy - a.dy) * (c.dx - b.dx);
    if (cross.abs() < 1e-9) continue;
    final current = cross > 0 ? 1 : -1;
    if (sign == 0) {
      sign = current;
    } else if (sign != current) {
      return false;
    }
  }
  return sign != 0;
}
