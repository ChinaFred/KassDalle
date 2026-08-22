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
/// ## Ce qui est posé sur quoi
///
/// Une photo de page n'a presque jamais deux plans. Elle en a trois ou quatre :
/// le canapé, la serviette étalée dessus, le livre posé sur la serviette, et la
/// photographie imprimée dans le livre. Chercher « ce qui se détache du fond »
/// rend la **serviette** — la plus grande chose qui se détache du canapé — et
/// c'est une réponse exacte à la mauvaise question.
///
/// On épluche donc les couches une à une : ce qui se détache du canapé, puis ce
/// qui se détache de la serviette, et ainsi de suite. Chaque couche est mesurée,
/// et on garde **la plus grande qui ressemble à du papier imprimé** :
///
/// - *du papier* — peu saturée et claire. Écarte la photographie imprimée, qui
///   est colorée, et le plateau de bois.
/// - *imprimée* — une densité de contours élevée. Écarte la serviette et la
///   nappe, unies, qui passent le premier test sans difficulté.
///
/// La serviette est du papier sans impression. La photo du plat est de
/// l'impression sans papier. La page est la seule à réunir les deux.
///
/// Si aucune couche ne convainc, une seconde méthode reprend l'appareillage de
/// l'application — Sobel, régression PCA, intersections — mais en balayant du
/// BORD vers le centre. Le premier gradient rencontré est alors la limite du
/// document et non son contenu.
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

/// Une couche trouvée par épluchage, avec ce qui permet d'en juger.
class SandboxLayer {
  /// Rang dans l'empilement : 1 pour ce qui se détache du fond de l'image.
  final int depth;

  /// Les quatre coins, en fraction de l'image.
  final List<Offset> quad;

  /// Part de l'image couverte par la couche.
  final double coverage;

  /// Part des pixels de la couche portant un contour marqué.
  final double detail;

  /// Saturation médiane, de 0 à 255.
  final double saturation;

  /// Luminance médiane, de 0 à 255.
  final double luma;

  const SandboxLayer({
    required this.depth,
    required this.quad,
    required this.coverage,
    required this.detail,
    required this.saturation,
    required this.luma,
  });

  /// Claire et peu colorée : du papier, une nappe, une serviette.
  bool get paperLike =>
      saturation <= _maxPaperSaturation && luma >= _minPaperLuma;

  /// Assez de contours pour porter du texte ou des images.
  bool get printed => detail >= _minPrintedDetail;

  /// Ce que la couche est, en deux mots, pour l'écran.
  String get verdict {
    if (paperLike && printed) return 'papier imprimé';
    if (paperLike) return 'uni — support probable';
    if (printed) return 'coloré et chargé — image, pas page';
    return 'ni papier ni impression';
  }
}

/// Ce qu'a trouvé la détection, et par quel chemin.
///
/// L'échec porte sa raison : dans un bac à sable, « coins introuvables » sans
/// autre précision n'apprend rien et ne se corrige pas.
class SandboxCornersResult {
  /// `[x0,y0, x1,y1, x2,y2, x3,y3]` en fraction de l'image, dans l'ordre
  /// haut-gauche, haut-droit, bas-droit, bas-gauche. `null` si rien trouvé.
  final List<double>? cornersFlat;

  /// « les couches » ou « les bords » — laquelle des deux méthodes a abouti.
  final String method;

  /// Pourquoi la couche retenue l'a été, en une phrase.
  final String? reason;

  /// Pourquoi les deux méthodes ont échoué, en une phrase.
  final String? failure;

  /// Part de l'image couverte par le quadrilatère, entre 0 et 1.
  final double coverage;

  /// L'empilement trouvé, de l'extérieur vers l'intérieur. Affiché tel quel :
  /// c'est ce qui explique pourquoi telle couche a été préférée.
  final List<SandboxLayer> layers;

  /// Rang de la couche retenue, ou 0 si les coins ne viennent pas d'une couche.
  final int chosenDepth;

  const SandboxCornersResult({
    this.cornersFlat,
    required this.method,
    this.reason,
    this.failure,
    this.coverage = 0,
    this.layers = const [],
    this.chosenDepth = 0,
  });

  bool get found => cornersFlat != null;
}

// Seuils de lecture d'une couche. Ils sont ici, nommés, parce que ce sont eux
// qu'on ira bouger après un essai raté — pas l'algorithme.

/// Au-delà, la couche est colorée : une photographie imprimée, pas une page.
const double _maxPaperSaturation = 70;

/// En dessous, la couche est sombre : un plateau de bois, une ombre.
const double _minPaperLuma = 85;

/// En dessous, la couche est unie : une serviette, une nappe, un mur.
const double _minPrintedDetail = 0.06;

/// Une couche plus petite que ça n'est plus une page : c'est un détail dedans.
const double _minLayerCoverage = 0.12;

/// Au-delà, la couche trouvée est sa propre parente : l'épluchage est fini.
const double _maxChildRatio = 0.92;

/// Cherche les quatre coins du document dans l'image.
SandboxCornersResult sandboxDetectCornersIsolate(SandboxCornersParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) {
    return const SandboxCornersResult(
      method: '',
      failure: 'Image illisible : le fichier ne se décode pas.',
    );
  }

  // 512 px suffisent : on cherche une frontière, pas un détail. Le coût est
  // quadratique, et la précision gagnée au-delà se perd de toute façon dans
  // l'épaisseur d'une ombre portée.
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

  final scene = _Scene(small, width, height);
  final byLayers = _cornersFromLayers(scene);
  if (byLayers.found) return byLayers;

  final byEdges = _cornersFromEdges(scene);
  if (byEdges.found) {
    return SandboxCornersResult(
      cornersFlat: byEdges.cornersFlat,
      method: byEdges.method,
      reason: byEdges.reason,
      coverage: byEdges.coverage,
      layers: byLayers.layers,
    );
  }

  return SandboxCornersResult(
    method: '',
    failure: byLayers.failure ?? byEdges.failure,
    layers: byLayers.layers,
  );
}

// ── La scène : ce qui se calcule une fois pour toutes ────────────────────────

class _Scene {
  final img.Image image;
  final int width;
  final int height;

  /// Luminance, saturation et présence d'un contour marqué, pixel par pixel.
  final Uint8List luma;
  final Uint8List saturation;
  final Uint8List edge;
  final Uint8List red;
  final Uint8List green;
  final Uint8List blue;

  _Scene._({
    required this.image,
    required this.width,
    required this.height,
    required this.luma,
    required this.saturation,
    required this.edge,
    required this.red,
    required this.green,
    required this.blue,
  });

  factory _Scene(img.Image image, int width, int height) {
    final count = width * height;
    final red = Uint8List(count);
    final green = Uint8List(count);
    final blue = Uint8List(count);
    final luma = Uint8List(count);
    final saturation = Uint8List(count);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final index = y * width + x;
        final pixel = image.getPixel(x, y);
        final r = pixel.r.round().clamp(0, 255);
        final g = pixel.g.round().clamp(0, 255);
        final b = pixel.b.round().clamp(0, 255);
        red[index] = r;
        green[index] = g;
        blue[index] = b;
        luma[index] = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(0, 255);
        saturation[index] =
            math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      }
    }

    // Contours : Sobel sur la luminance, seuillé au 85e percentile. Le seuil
    // est relatif à l'image entière, et c'est voulu — on compare ensuite des
    // couches entre elles, pas à une valeur absolue.
    final magnitude = Float32List(count);
    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        final index = y * width + x;
        int at(int px, int py) => luma[py * width + px];
        final gx =
            at(x + 1, y - 1) +
            2 * at(x + 1, y) +
            at(x + 1, y + 1) -
            at(x - 1, y - 1) -
            2 * at(x - 1, y) -
            at(x - 1, y + 1);
        final gy =
            at(x - 1, y + 1) +
            2 * at(x, y + 1) +
            at(x + 1, y + 1) -
            at(x - 1, y - 1) -
            2 * at(x, y - 1) -
            at(x + 1, y - 1);
        magnitude[index] = math.sqrt((gx * gx + gy * gy).toDouble());
      }
    }

    final sorted = Float32List.fromList(magnitude)..sort();
    final threshold = math.max(
      30.0,
      sorted[(sorted.length * 0.85).round().clamp(0, sorted.length - 1)],
    );
    final edge = Uint8List(count);
    for (int i = 0; i < count; i++) {
      if (magnitude[i] >= threshold) edge[i] = 1;
    }

    return _Scene._(
      image: image,
      width: width,
      height: height,
      luma: luma,
      saturation: saturation,
      edge: edge,
      red: red,
      green: green,
      blue: blue,
    );
  }
}

// ── Méthode 1 : éplucher les couches ─────────────────────────────────────────

SandboxCornersResult _cornersFromLayers(_Scene scene) {
  final count = scene.width * scene.height;
  final layers = <SandboxLayer>[];
  final masks = <Uint8List>[];

  var parent = Uint8List(count)..fillRange(0, count, 1);
  var parentArea = count.toDouble();
  String? firstFailure;

  // Quatre couches au plus : canapé, serviette, livre, page. Au-delà on entre
  // dans le contenu de la page, et ce n'est plus un support.
  for (int depth = 1; depth <= 4; depth++) {
    final peeled = _peel(scene, parent, depth);
    if (peeled == null) {
      firstFailure ??= depth == 1
          ? 'Rien ne se détache du fond : le document a la couleur de son '
                'support, ou il remplit tout le cadre.'
          : null;
      break;
    }

    layers.add(peeled.layer);
    masks.add(peeled.mask);

    // Une couche qui reprend presque toute sa parente n'apprend rien : c'est la
    // même chose, redécoupée au bruit près.
    if (peeled.area / parentArea > _maxChildRatio) break;
    if (peeled.layer.coverage < _minLayerCoverage) break;

    parent = peeled.mask;
    parentArea = peeled.area;
  }

  if (layers.isEmpty) {
    return SandboxCornersResult(
      method: 'les couches',
      failure:
          firstFailure ??
          'Aucune couche exploitable ne se détache dans cette image.',
    );
  }

  // Le choix. On veut la plus grande couche qui soit à la fois du papier et
  // imprimée : la serviette est du papier sans impression, la photo du plat est
  // de l'impression sans papier.
  final candidates = layers
      .where((l) => l.coverage >= _minLayerCoverage)
      .toList(growable: false);

  SandboxLayer? chosen;
  String reason;
  final printed = candidates.where((l) => l.paperLike && l.printed).toList();
  if (printed.isNotEmpty) {
    chosen = printed.reduce((a, b) => a.coverage >= b.coverage ? a : b);
    reason =
        'couche ${chosen.depth} sur ${layers.length} : claire, peu colorée, '
        'et ${(chosen.detail * 100).round()} % de ses pixels portent un '
        'contour — du papier imprimé.';
  } else {
    final paper = candidates.where((l) => l.paperLike).toList();
    if (paper.isNotEmpty) {
      chosen = paper.reduce((a, b) => a.coverage >= b.coverage ? a : b);
      reason =
          'couche ${chosen.depth} sur ${layers.length} : du papier, mais rien '
          'd\'imprimé dessus. C\'est peut-être le support et non la page.';
    } else if (candidates.isNotEmpty) {
      chosen = candidates.reduce((a, b) => a.coverage >= b.coverage ? a : b);
      reason =
          'couche ${chosen.depth} sur ${layers.length} : aucune couche ne '
          'ressemble à du papier, la plus grande a été retenue faute de mieux.';
    } else {
      return SandboxCornersResult(
        method: 'les couches',
        layers: layers,
        failure:
            'Les couches trouvées couvrent toutes moins d\'un huitième de '
            'l\'image : ce sont des détails, pas une page.',
      );
    }
  }

  return SandboxCornersResult(
    cornersFlat: [
      for (final corner in chosen.quad) ...[corner.dx, corner.dy],
    ],
    method: 'les couches',
    reason: reason,
    coverage: chosen.coverage,
    layers: layers,
    chosenDepth: chosen.depth,
  );
}

class _Peeled {
  final SandboxLayer layer;
  final Uint8List mask;
  final double area;

  const _Peeled({required this.layer, required this.mask, required this.area});
}

/// Trouve ce qui se détache de `parent`, à l'intérieur de `parent`.
///
/// La couleur du support est prise sur l'anneau intérieur de la parente — sa
/// bordure vue du dedans. Au premier tour c'est le bord de l'image ; ensuite
/// c'est le bord de la serviette, puis celui du livre.
_Peeled? _peel(_Scene scene, Uint8List parent, int depth) {
  final W = scene.width;
  final H = scene.height;
  final count = W * H;

  var parentArea = 0;
  for (int i = 0; i < count; i++) {
    if (parent[i] == 1) parentArea++;
  }
  if (parentArea < count * 0.05) return null;

  // Anneau intérieur : la parente moins son érodée.
  final ringWidth = math.max(3, (math.sqrt(parentArea) * 0.05).round());
  final eroded = _erode(parent, W, H, ringWidth);
  final reds = <int>[], greens = <int>[], blues = <int>[];
  for (int i = 0; i < count; i++) {
    if (parent[i] == 1 && eroded[i] == 0) {
      reds.add(scene.red[i]);
      greens.add(scene.green[i]);
      blues.add(scene.blue[i]);
    }
  }
  if (reds.length < 32) return null;

  final bgR = _median(reds), bgG = _median(greens), bgB = _median(blues);

  // Écart au support, en distance de Tchebychev : c'est le canal le plus
  // éloigné qui trahit un objet posé dessus, pas la moyenne des trois.
  final distance = Uint8List(count);
  final histogram = List<int>.filled(256, 0);
  for (int i = 0; i < count; i++) {
    if (parent[i] == 0) continue;
    final d = math.max(
      (scene.red[i] - bgR).abs(),
      math.max((scene.green[i] - bgG).abs(), (scene.blue[i] - bgB).abs()),
    );
    final value = d > 255 ? 255 : d;
    distance[i] = value;
    histogram[value]++;
  }

  // Otsu, borné en bas : sur une zone uniforme, Otsu partage quand même, et
  // rendrait le bruit du capteur pour un document.
  final threshold = math.max(20, _otsu(histogram, parentArea));

  final mask = Uint8List(count);
  var foreground = 0;
  for (int i = 0; i < count; i++) {
    if (parent[i] == 1 && distance[i] >= threshold) {
      mask[i] = 1;
      foreground++;
    }
  }
  if (foreground < parentArea * 0.05) return null;

  _closeMask(mask, W, H, 2);
  _fillEnclosedHoles(mask, parent, W, H);
  for (int i = 0; i < count; i++) {
    if (parent[i] == 0) mask[i] = 0;
  }

  final component = _largestComponent(mask, W, H);
  if (component == null || component.length < count * 0.03) return null;

  final componentMask = Uint8List(count);
  for (final index in component) {
    componentMask[index] = 1;
  }

  final quad = _quadFromComponent(component, W, H);
  if (quad == null) return null;

  return _Peeled(
    layer: SandboxLayer(
      depth: depth,
      quad: [for (final corner in quad) Offset(corner.dx / W, corner.dy / H)],
      coverage: _shoelaceArea(quad) / count,
      detail: _ratioOver(scene.edge, component),
      saturation: _medianOver(scene.saturation, component),
      luma: _medianOver(scene.luma, component),
    ),
    mask: componentMask,
    area: component.length.toDouble(),
  );
}

double _ratioOver(Uint8List values, List<int> indices) {
  if (indices.isEmpty) return 0;
  var hits = 0;
  for (final index in indices) {
    if (values[index] == 1) hits++;
  }
  return hits / indices.length;
}

double _medianOver(Uint8List values, List<int> indices) {
  if (indices.isEmpty) return 0;
  final histogram = List<int>.filled(256, 0);
  for (final index in indices) {
    histogram[values[index]]++;
  }
  final half = indices.length ~/ 2;
  var seen = 0;
  for (int value = 0; value < 256; value++) {
    seen += histogram[value];
    if (seen > half) return value.toDouble();
  }
  return 0;
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
    if (weightForeground <= 0) break;
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

// ── Morphologie ──────────────────────────────────────────────────────────────
//
// Érosion et dilatation sont séparables pour un élément structurant carré :
// une passe horizontale puis une passe verticale, au lieu d'un carré complet
// par pixel. À 512 px et rayon 8, c'est deux ordres de grandeur de moins.

Uint8List _erode(Uint8List mask, int W, int H, int radius) =>
    _morph(mask, W, H, radius, keepWhenAnyIsZero: true);

Uint8List _dilate(Uint8List mask, int W, int H, int radius) =>
    _morph(mask, W, H, radius, keepWhenAnyIsZero: false);

Uint8List _morph(
  Uint8List mask,
  int W,
  int H,
  int radius, {
  required bool keepWhenAnyIsZero,
}) {
  final horizontal = Uint8List(W * H);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      var value = keepWhenAnyIsZero ? 1 : 0;
      for (int dx = -radius; dx <= radius; dx++) {
        final sample = mask[y * W + (x + dx).clamp(0, W - 1)];
        if (keepWhenAnyIsZero) {
          if (sample == 0) {
            value = 0;
            break;
          }
        } else if (sample == 1) {
          value = 1;
          break;
        }
      }
      horizontal[y * W + x] = value;
    }
  }

  final result = Uint8List(W * H);
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      var value = keepWhenAnyIsZero ? 1 : 0;
      for (int dy = -radius; dy <= radius; dy++) {
        final sample = horizontal[(y + dy).clamp(0, H - 1) * W + x];
        if (keepWhenAnyIsZero) {
          if (sample == 0) {
            value = 0;
            break;
          }
        } else if (sample == 1) {
          value = 1;
          break;
        }
      }
      result[y * W + x] = value;
    }
  }
  return result;
}

/// Fermeture morphologique : dilate puis érode.
///
/// Recolle les fragments d'une frontière hachée par le bruit, sans grossir la
/// forme — c'est l'érosion qui rend ce que la dilatation a pris.
void _closeMask(Uint8List mask, int W, int H, int radius) {
  final closed = _erode(_dilate(mask, W, H, radius), W, H, radius);
  mask.setAll(0, closed);
}

/// Bouche les trous : tout fond qui n'atteint pas le bord de la zone parente
/// est enclos par la forme, donc en fait partie.
///
/// Sans cette passe, une page de texte devient un semis de lettres, et ses
/// marges restent au fond. La tache trouvée serait alors le pavé de texte,
/// pas la page.
void _fillEnclosedHoles(Uint8List mask, Uint8List parent, int W, int H) {
  final reachable = Uint8List(W * H);
  final stack = <int>[];

  void push(int index) {
    if (parent[index] == 1 && mask[index] == 0 && reachable[index] == 0) {
      reachable[index] = 1;
      stack.add(index);
    }
  }

  // Germes : les pixels de la parente qui touchent le bord de l'image ou le
  // dehors de la parente. C'est de là que vient le « fond » de ce niveau.
  for (int y = 0; y < H; y++) {
    for (int x = 0; x < W; x++) {
      final index = y * W + x;
      if (parent[index] == 0) continue;
      final onImageBorder = x == 0 || y == 0 || x == W - 1 || y == H - 1;
      final touchesOutside =
          onImageBorder ||
          (x > 0 && parent[index - 1] == 0) ||
          (x < W - 1 && parent[index + 1] == 0) ||
          (y > 0 && parent[index - W] == 0) ||
          (y < H - 1 && parent[index + W] == 0);
      if (touchesOutside) push(index);
    }
  }

  while (stack.isNotEmpty) {
    final index = stack.removeLast();
    final x = index % W;
    final y = index ~/ W;
    if (x > 0) push(index - 1);
    if (x < W - 1) push(index + 1);
    if (y > 0) push(index - W);
    if (y < H - 1) push(index + W);
  }

  for (int i = 0; i < mask.length; i++) {
    if (parent[i] == 1 && mask[i] == 0 && reachable[i] == 0) mask[i] = 1;
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
      void visit(int next) {
        if (mask[next] == 1 && visited[next] == 0) {
          visited[next] = 1;
          stack.add(next);
        }
      }

      if (x > 0) visit(index - 1);
      if (x < W - 1) visit(index + 1);
      if (y > 0) visit(index - W);
      if (y < H - 1) visit(index + W);
    }

    if (best == null || component.length > best.length) best = component;
  }
  return best;
}

/// Les quatre extrêmes d'une tache : le classique `x+y` / `x−y`.
///
/// Le coin haut-gauche est le point qui minimise `x+y`, le bas-droit celui qui
/// le maximise ; `x−y` donne les deux autres. Ça tient tant que la forme est à
/// peu près rectangulaire, quelle que soit son inclinaison.
List<Offset>? _quadFromComponent(List<int> component, int W, int H) {
  var minSum = double.infinity, maxSum = -double.infinity;
  var minDiff = double.infinity, maxDiff = -double.infinity;
  Offset? topLeft, bottomRight, bottomLeft, topRight;

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

  if (topLeft == null ||
      topRight == null ||
      bottomRight == null ||
      bottomLeft == null) {
    return null;
  }
  final quad = [topLeft, topRight, bottomRight, bottomLeft];
  return _isConvex(quad) ? quad : null;
}

// ── Méthode 2 : les bords ────────────────────────────────────────────────────

SandboxCornersResult _cornersFromEdges(_Scene scene) {
  final W = scene.width;
  final H = scene.height;

  // Le balayage part du BORD vers le centre — c'est là toute la différence
  // avec la détection de l'application. Le premier gradient rencontré depuis
  // l'extérieur est la limite du document ; depuis le centre, c'était la
  // première ligne de texte.
  final edge = _dilate(scene.edge, W, H, 1);
  final marginX = (W * 0.04).round();
  final marginY = (H * 0.04).round();
  final midY = H ~/ 2;
  final midX = W ~/ 2;
  final top = <Offset>[], bottom = <Offset>[];
  final left = <Offset>[], right = <Offset>[];

  for (int x = marginX; x < W - marginX; x++) {
    for (int y = 0; y <= midY; y++) {
      if (edge[y * W + x] == 1) {
        top.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    for (int y = H - 1; y >= midY; y--) {
      if (edge[y * W + x] == 1) {
        bottom.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
  }
  for (int y = marginY; y < H - marginY; y++) {
    for (int x = 0; x <= midX; x++) {
      if (edge[y * W + x] == 1) {
        left.add(Offset(x.toDouble(), y.toDouble()));
        break;
      }
    }
    for (int x = W - 1; x >= midX; x--) {
      if (edge[y * W + x] == 1) {
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

// ── Validation ───────────────────────────────────────────────────────────────

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
      for (final corner in corners) ...[corner.dx / W, corner.dy / H],
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
