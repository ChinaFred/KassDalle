/// Opérations d'image propres au bac à sable, exécutées dans un isolate.
///
/// Le redressement lui-même appelle `warpIsolate` de
/// `core/presentation/image_enhancer_processing.dart` tel quel. La détection
/// des coins, en revanche, est **dérivée** : celle de l'application scanne du
/// centre vers les bords et retient le premier gradient fort. C'est le bon
/// choix pour une feuille peu chargée ; sur une page de livre, le premier
/// gradient rencontré depuis le centre est une ligne de texte, et jamais le
/// bord du papier.
///
/// Deux méthodes sont donc essayées ici, dans cet ordre :
///
/// 1. **Le fond.** L'anneau extérieur de l'image donne la couleur du support —
///    la table, la serviette. Tout ce qui s'en écarte est le document. On garde
///    la tache connexe qui contient le centre, on bouche ses trous, et ses
///    quatre points extrêmes sont les coins.
/// 2. **Les bords.** Même appareillage que l'application — Sobel, régression
///    PCA, intersections — mais le balayage part du BORD vers le centre. Le
///    premier gradient rencontré est alors la limite du document, pas son
///    contenu.
///
/// La première réussit sur un fond uni et contrasté. La seconde rattrape les
/// cas où le document a la couleur de son support, et où seule l'ombre portée
/// dessine la limite.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:image/image.dart' as img;

// ── Réduction avant envoi au modèle ──────────────────────────────────────────

class SandboxDownscaleParams {
  final Uint8List bytes;

  /// Côté long visé, en pixels.
  final int maxDimension;

  const SandboxDownscaleParams({
    required this.bytes,
    required this.maxDimension,
  });
}

class SandboxDownscaleResult {
  final Uint8List bytes;
  final int width;
  final int height;

  const SandboxDownscaleResult({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Réduit une image avant de l'envoyer au modèle.
///
/// L'appel callable plafonne à 10 Mo, et le base64 alourdit d'un tiers ce
/// qu'on lui donne. Une photo de téléphone passe donc rarement telle quelle.
///
/// Ça ne coûte aucune précision : le modèle rend ses coins en repère
/// normalisé 0-1000, qui ne dépend pas de la taille envoyée. Les découpes,
/// elles, se feront plus tard sur les pixels d'origine.
SandboxDownscaleResult sandboxDownscaleIsolate(SandboxDownscaleParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) throw Exception('Image illisible.');

  final longest = source.width > source.height ? source.width : source.height;
  if (longest <= p.maxDimension) {
    return SandboxDownscaleResult(
      bytes: p.bytes,
      width: source.width,
      height: source.height,
    );
  }

  final factor = p.maxDimension / longest;
  final resized = img.copyResize(
    source,
    width: (source.width * factor).round(),
    height: (source.height * factor).round(),
    interpolation: img.Interpolation.linear,
  );
  return SandboxDownscaleResult(
    bytes: Uint8List.fromList(img.encodeJpg(resized, quality: 90)),
    width: resized.width,
    height: resized.height,
  );
}

// ── Détection des quatre coins de la page ────────────────────────────────────

class SandboxCornersParams {
  final Uint8List bytes;

  const SandboxCornersParams({required this.bytes});
}

/// Ce qu'a trouvé la détection, et par quel chemin.
///
/// L'échec porte sa raison : dans un bac à sable, « coins introuvables » sans
/// autre précision n'apprend rien et ne se corrige pas.
class SandboxCornersResult {
  /// `[x0,y0, x1,y1, x2,y2, x3,y3]` en fraction de l'image, dans l'ordre
  /// haut-gauche, haut-droit, bas-droit, bas-gauche. `null` si rien trouvé.
  final List<double>? cornersFlat;

  /// « le fond » ou « les bords » — laquelle des deux méthodes a abouti.
  final String method;

  /// Pourquoi les deux ont échoué, en une phrase.
  final String? failure;

  /// Part de l'image couverte par le quadrilatère, entre 0 et 1.
  final double coverage;

  const SandboxCornersResult({
    this.cornersFlat,
    required this.method,
    this.failure,
    this.coverage = 0,
  });

  bool get found => cornersFlat != null;
}

/// Cherche les quatre coins du document dans l'image.
SandboxCornersResult sandboxDetectCornersIsolate(SandboxCornersParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) {
    return const SandboxCornersResult(
      method: '',
      failure: 'Image illisible : le fichier ne se décode pas.',
    );
  }

  // 512 px suffisent : on cherche une frontière, pas un détail. Le coût de la
  // détection est quadratique, et la précision gagnée au-delà se perd de toute
  // façon dans l'épaisseur d'une ombre portée.
  const target = 512;
  final scale = target / math.max(source.width, source.height);
  final width = math.max(32, (source.width * scale).round());
  final height = math.max(32, (source.height * scale).round());
  final small = img.copyResize(
    source,
    width: width,
    height: height,
    interpolation: img.Interpolation.average,
  );

  final byBackground = _cornersFromBackground(small, width, height);
  // 25 % : en dessous, la tache trouvée n'est pas la page mais une illustration
  // sombre posée dessus, ou l'ombre du photographe.
  if (byBackground.found && byBackground.coverage >= 0.25) return byBackground;

  final byEdges = _cornersFromEdges(small, width, height);
  if (byEdges.found) return byEdges;

  // La première a peut-être trouvé quelque chose de petit : mieux vaut ça que
  // rien, et l'écran affiche la couverture pour qu'on en juge.
  if (byBackground.found) return byBackground;

  return SandboxCornersResult(
    method: '',
    failure: byBackground.failure ?? byEdges.failure,
  );
}

// ── Méthode 1 : le fond ──────────────────────────────────────────────────────

SandboxCornersResult _cornersFromBackground(img.Image im, int W, int H) {
  // Couleur du support, prise sur l'anneau extérieur. La médiane et non la
  // moyenne : un coin d'image qui mord sur le document tirerait la moyenne
  // vers lui, la médiane l'ignore.
  final ringWidth = math.max(3, (math.min(W, H) * 0.04).round());
  final reds = <int>[], greens = <int>[], blues = <int>[];
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      final onRing =
          x < ringWidth ||
          y < ringWidth ||
          x >= W - ringWidth ||
          y >= H - ringWidth;
      if (!onRing) continue;
      final pixel = im.getPixel(x, y);
      reds.add(pixel.r.round());
      greens.add(pixel.g.round());
      blues.add(pixel.b.round());
    }
  }
  if (reds.isEmpty) {
    return const SandboxCornersResult(
      method: 'le fond',
      failure: 'Image trop petite pour y lire une couleur de support.',
    );
  }
  final bgR = _median(reds), bgG = _median(greens), bgB = _median(blues);

  // Écart au support, en distance de Tchebychev : c'est le canal le plus
  // éloigné qui trahit un document, pas la moyenne des trois.
  final distance = Uint8List(W * H);
  final histogram = List<int>.filled(256, 0);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      final pixel = im.getPixel(x, y);
      final d = math.max(
        (pixel.r.round() - bgR).abs(),
        math.max((pixel.g.round() - bgG).abs(), (pixel.b.round() - bgB).abs()),
      );
      final value = d > 255 ? 255 : d;
      distance[y * W + x] = value;
      histogram[value]++;
    }
  }

  // Otsu, borné en bas : sur une image entièrement uniforme, Otsu partage
  // quand même — il rendrait le bruit du capteur pour un document.
  final threshold = math.max(20, _otsu(histogram, W * H));

  final mask = Uint8List(W * H);
  var foreground = 0;
  for (int i = 0; i < mask.length; i++) {
    if (distance[i] >= threshold) {
      mask[i] = 1;
      foreground++;
    }
  }
  final ratio = foreground / (W * H);
  if (ratio < 0.05) {
    return const SandboxCornersResult(
      method: 'le fond',
      failure:
          'Le document a la couleur de son support : rien ne s\'en détache. '
          'Poser la page sur un fond franchement contrasté.',
    );
  }
  if (ratio > 0.98) {
    return const SandboxCornersResult(
      method: 'le fond',
      failure:
          'Le document remplit tout le cadre : aucun support visible autour, '
          'donc aucun bord à trouver.',
    );
  }

  _closeMask(mask, W, H, 2);
  _fillEnclosedHoles(mask, W, H);

  final component = _largestComponent(mask, W, H);
  if (component == null) {
    return const SandboxCornersResult(
      method: 'le fond',
      failure: 'Aucune zone continue ne se détache du support.',
    );
  }

  return _quadFromComponent(component, W, H, 'le fond');
}

/// Otsu : le seuil qui sépare le mieux deux populations dans un histogramme.
int _otsu(List<int> histogram, int total) {
  var sum = 0.0;
  for (int i = 0; i < 256; i++) {
    sum += i * histogram[i];
  }
  var sumBackground = 0.0;
  var weightBackground = 0;
  var best = 0.0;
  var threshold = 0;
  for (int t = 0; t < 256; t++) {
    weightBackground += histogram[t];
    if (weightBackground == 0) continue;
    final weightForeground = total - weightBackground;
    if (weightForeground == 0) break;
    sumBackground += t * histogram[t];
    final meanBackground = sumBackground / weightBackground;
    final meanForeground = (sum - sumBackground) / weightForeground;
    final between =
        weightBackground *
        weightForeground *
        (meanBackground - meanForeground) *
        (meanBackground - meanForeground);
    if (between > best) {
      best = between;
      threshold = t;
    }
  }
  return threshold;
}

int _median(List<int> values) {
  values.sort();
  return values[values.length ~/ 2];
}

/// Fermeture morphologique : dilate puis érode.
///
/// Recolle les fragments d'une frontière hachée par le bruit, sans grossir la
/// forme — c'est l'érosion qui rend ce que la dilatation a pris.
void _closeMask(Uint8List mask, int W, int H, int radius) {
  final dilated = Uint8List(W * H);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      if (mask[y * W + x] == 0) continue;
      for (int dy = -radius; dy <= radius; dy++) {
        final ny = (y + dy).clamp(0, H - 1);
        for (int dx = -radius; dx <= radius; dx++) {
          dilated[ny * W + (x + dx).clamp(0, W - 1)] = 1;
        }
      }
    }
  }
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      var keep = 1;
      for (int dy = -radius; dy <= radius && keep == 1; dy++) {
        final ny = (y + dy).clamp(0, H - 1);
        for (int dx = -radius; dx <= radius; dx++) {
          if (dilated[ny * W + (x + dx).clamp(0, W - 1)] == 0) {
            keep = 0;
            break;
          }
        }
      }
      mask[y * W + x] = keep;
    }
  }
}

/// Bouche les trous : tout fond qui n'atteint pas le bord de l'image est
/// enclos par le document, donc en fait partie.
///
/// Sans cette passe, une page de texte blanc devient un semis de lettres, et
/// ses marges restent au fond. La tache trouvée serait alors le pavé de texte,
/// pas la page.
void _fillEnclosedHoles(Uint8List mask, int W, int H) {
  final reachable = Uint8List(W * H);
  final stack = <int>[];

  void push(int x, int y) {
    final index = y * W + x;
    if (mask[index] == 0 && reachable[index] == 0) {
      reachable[index] = 1;
      stack.add(index);
    }
  }

  for (int x = 0; x < W; x++) {
    push(x, 0);
    push(x, H - 1);
  }
  for (int y = 0; y < H; y++) {
    push(0, y);
    push(W - 1, y);
  }

  while (stack.isNotEmpty) {
    final index = stack.removeLast();
    final x = index % W;
    final y = index ~/ W;
    if (x > 0) push(x - 1, y);
    if (x < W - 1) push(x + 1, y);
    if (y > 0) push(x, y - 1);
    if (y < H - 1) push(x, y + 1);
  }

  for (int i = 0; i < mask.length; i++) {
    if (mask[i] == 0 && reachable[i] == 0) mask[i] = 1;
  }
}

/// Points de la plus grande tache connexe du masque.
List<int>? _largestComponent(Uint8List mask, int W, int H) {
  final visited = Uint8List(W * H);
  List<int>? best;

  for (int start = 0; start < mask.length; start++) {
    if (mask[start] == 0 || visited[start] == 1) continue;

    final component = <int>[];
    final stack = <int>[start];
    visited[start] = 1;
    while (stack.isNotEmpty) {
      final index = stack.removeLast();
      component.add(index);
      final x = index % W;
      final y = index ~/ W;
      void visit(int nx, int ny) {
        final next = ny * W + nx;
        if (mask[next] == 1 && visited[next] == 0) {
          visited[next] = 1;
          stack.add(next);
        }
      }

      if (x > 0) visit(x - 1, y);
      if (x < W - 1) visit(x + 1, y);
      if (y > 0) visit(x, y - 1);
      if (y < H - 1) visit(x, y + 1);
    }

    if (best == null || component.length > best.length) best = component;
  }
  return best;
}

/// Les quatre extrêmes d'une tache : le classique `x+y` / `x−y`.
///
/// Le coin haut-gauche est le point qui minimise `x+y`, le bas-droit celui qui
/// le maximise ; `x−y` donne les deux autres. Ça tient tant que le document est
/// à peu près rectangulaire, quelle que soit son inclinaison.
SandboxCornersResult _quadFromComponent(
  List<int> component,
  int W,
  int H,
  String method,
) {
  var minSum = double.infinity, maxSum = -double.infinity;
  var minDiff = double.infinity, maxDiff = -double.infinity;
  late Offset topLeft, bottomRight, bottomLeft, topRight;

  for (final index in component) {
    final x = (index % W).toDouble();
    final y = (index ~/ W).toDouble();
    final sum = x + y;
    final diff = x - y;
    if (sum < minSum) {
      minSum = sum;
      topLeft = Offset(x, y);
    }
    if (sum > maxSum) {
      maxSum = sum;
      bottomRight = Offset(x, y);
    }
    if (diff < minDiff) {
      minDiff = diff;
      bottomLeft = Offset(x, y);
    }
    if (diff > maxDiff) {
      maxDiff = diff;
      topRight = Offset(x, y);
    }
  }

  return _validate([topLeft, topRight, bottomRight, bottomLeft], W, H, method);
}

// ── Méthode 2 : les bords ────────────────────────────────────────────────────

SandboxCornersResult _cornersFromEdges(img.Image im, int W, int H) {
  final gray = img.normalize(img.grayscale(im), min: 0, max: 255);

  final magnitude = List.generate(H, (_) => List.filled(W, 0.0));
  var maxMagnitude = 1.0;
  for (int y = 1; y < H - 1; y++) {
    for (int x = 1; x < W - 1; x++) {
      final m = _sobel(gray, x, y);
      magnitude[y][x] = m;
      if (m > maxMagnitude) maxMagnitude = m;
    }
  }

  // 85e percentile, plus sélectif que le 70e de l'application : le balayage
  // part du bord, et la texture d'une nappe ou d'une serviette s'y présente
  // avant le document. Un seuil lâche prendrait le tissu pour du papier.
  final sorted = magnitude.expand((row) => row).toList()..sort();
  final threshold = sorted[(sorted.length * 0.85).round()].clamp(
    maxMagnitude * 0.06,
    maxMagnitude * 0.6,
  );

  final edge = List.generate(H, (_) => List.filled(W, false));
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      if (magnitude[y][x] < threshold) continue;
      for (int dy = -1; dy <= 1; dy++) {
        final ny = (y + dy).clamp(0, H - 1);
        for (int dx = -1; dx <= 1; dx++) {
          edge[ny][(x + dx).clamp(0, W - 1)] = true;
        }
      }
    }
  }

  // Le balayage part du BORD vers le centre — c'est là toute la différence
  // avec la détection de l'application. Le premier gradient rencontré depuis
  // l'extérieur est la limite du document ; depuis le centre, c'était la
  // première ligne de texte.
  final marginX = (W * 0.04).round();
  final marginY = (H * 0.04).round();
  final midY = H ~/ 2;
  final midX = W ~/ 2;
  final top = <Offset>[], bottom = <Offset>[];
  final left = <Offset>[], right = <Offset>[];

  for (int x = marginX; x < W - marginX; x++) {
    for (int y = 0; y <= midY; y++) {
      if (edge[y][x]) {
        top.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    for (int y = H - 1; y >= midY; y--) {
      if (edge[y][x]) {
        bottom.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
  }
  for (int y = marginY; y < H - marginY; y++) {
    for (int x = 0; x <= midX; x++) {
      if (edge[y][x]) {
        left.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    for (int x = W - 1; x >= midX; x--) {
      if (edge[y][x]) {
        right.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
  }

  const minimumPoints = 12;
  if (top.length < minimumPoints ||
      bottom.length < minimumPoints ||
      left.length < minimumPoints ||
      right.length < minimumPoints) {
    return const SandboxCornersResult(
      method: 'les bords',
      failure:
          'Bords trop flous ou trop peu contrastés : les quatre côtés du '
          'document ne se dessinent pas.',
    );
  }

  final topLine = _fitLine(_trim(top, false));
  final bottomLine = _fitLine(_trim(bottom, false));
  final leftLine = _fitLine(_trim(left, true));
  final rightLine = _fitLine(_trim(right, true));

  final tl = _intersect(topLine, leftLine);
  final tr = _intersect(topLine, rightLine);
  final br = _intersect(bottomLine, rightLine);
  final bl = _intersect(bottomLine, leftLine);
  if (tl == null || tr == null || br == null || bl == null) {
    return const SandboxCornersResult(
      method: 'les bords',
      failure: 'Deux côtés opposés sont parallèles : pas de coin à en tirer.',
    );
  }

  return _validate([tl, tr, br, bl], W, H, 'les bords');
}

double _sobel(img.Image gray, int x, int y) {
  int value(int px, int py) => gray
      .getPixel(px.clamp(0, gray.width - 1), py.clamp(0, gray.height - 1))
      .r
      .round();
  final gx =
      value(x + 1, y - 1) +
      2 * value(x + 1, y) +
      value(x + 1, y + 1) -
      value(x - 1, y - 1) -
      2 * value(x - 1, y) -
      value(x - 1, y + 1);
  final gy =
      value(x - 1, y + 1) +
      2 * value(x, y + 1) +
      value(x + 1, y + 1) -
      value(x - 1, y - 1) -
      2 * value(x, y - 1) -
      value(x + 1, y - 1);
  return math.sqrt((gx * gx + gy * gy).toDouble());
}

/// Écarte les 10 % extrêmes : une ombre portée ou un pli de tissu déplace
/// quelques points, et une droite ajustée sur eux part de travers.
List<Offset> _trim(List<Offset> points, bool sortByX) {
  final sorted = [...points]
    ..sort((a, b) => sortByX ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  final cut = (sorted.length * 0.1).round();
  final kept = sorted.sublist(cut, sorted.length - cut);
  return kept.isEmpty ? sorted : kept;
}

/// Droite `px·x + py·y = r`, ajustée par analyse en composantes principales.
class _Line {
  final double px;
  final double py;
  final double r;

  const _Line(this.px, this.py, this.r);
}

_Line _fitLine(List<Offset> points) {
  var cx = 0.0, cy = 0.0;
  for (final point in points) {
    cx += point.dx;
    cy += point.dy;
  }
  cx /= points.length;
  cy /= points.length;

  var sxx = 0.0, sxy = 0.0, syy = 0.0;
  for (final point in points) {
    final dx = point.dx - cx;
    final dy = point.dy - cy;
    sxx += dx * dx;
    sxy += dx * dy;
    syy += dy * dy;
  }

  // Direction principale : le vecteur propre de la plus grande valeur propre.
  final trace = sxx + syy;
  final determinant = sxx * syy - sxy * sxy;
  final root = math.sqrt(math.max(0, trace * trace / 4 - determinant));
  final lambda = trace / 2 + root;

  double dx, dy;
  if (sxy.abs() > 1e-9) {
    dx = lambda - syy;
    dy = sxy;
  } else {
    dx = sxx >= syy ? 1 : 0;
    dy = sxx >= syy ? 0 : 1;
  }
  final norm = math.sqrt(dx * dx + dy * dy);
  dx /= norm;
  dy /= norm;

  // La normale à la direction principale porte l'équation de la droite.
  final px = -dy;
  final py = dx;
  return _Line(px, py, px * cx + py * cy);
}

Offset? _intersect(_Line a, _Line b) {
  final determinant = a.px * b.py - a.py * b.px;
  if (determinant.abs() < 1e-9) return null;
  return Offset(
    (a.r * b.py - b.r * a.py) / determinant,
    (a.px * b.r - b.px * a.r) / determinant,
  );
}

// ── Validation commune ───────────────────────────────────────────────────────

SandboxCornersResult _validate(
  List<Offset> corners,
  int W,
  int H,
  String method,
) {
  const margin = 0.04;
  for (final corner in corners) {
    if (corner.dx / W < -margin ||
        corner.dx / W > 1 + margin ||
        corner.dy / H < -margin ||
        corner.dy / H > 1 + margin) {
      return SandboxCornersResult(
        method: method,
        failure:
            'Les coins trouvés tombent hors de l\'image : le document sort du '
            'cadre, ou ce qui a été pris pour lui n\'en est pas un.',
      );
    }
  }
  if (!_isConvex(corners)) {
    return SandboxCornersResult(
      method: method,
      failure:
          'Les quatre coins ne forment pas un quadrilatère convexe : deux '
          'côtés se croisent.',
    );
  }

  final coverage = _shoelaceArea(corners) / (W * H);
  if (coverage < 0.10) {
    return SandboxCornersResult(
      method: method,
      failure:
          'La zone trouvée couvre moins d\'un dixième de l\'image : c\'est un '
          'détail, pas la page.',
    );
  }

  return SandboxCornersResult(
    method: method,
    coverage: coverage,
    cornersFlat: [
      corners[0].dx / W,
      corners[0].dy / H,
      corners[1].dx / W,
      corners[1].dy / H,
      corners[2].dx / W,
      corners[2].dy / H,
      corners[3].dx / W,
      corners[3].dy / H,
    ],
  );
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

double _shoelaceArea(List<Offset> quad) {
  var sum = 0.0;
  for (int i = 0; i < quad.length; i++) {
    final a = quad[i];
    final b = quad[(i + 1) % quad.length];
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  return sum.abs() / 2;
}
