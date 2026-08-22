import 'package:flutter/material.dart';

/// Ce qu'une zone détectée contient, tel que le modèle la qualifie.
enum RegionKind {
  photo('Photo'),
  dessin('Dessin'),
  schema('Schéma'),
  texteManuscrit('Manuscrit'),
  autre('Autre');

  final String label;

  const RegionKind(this.label);

  static RegionKind parse(String? raw) => switch (raw) {
    'photo' => RegionKind.photo,
    'dessin' => RegionKind.dessin,
    'schema' => RegionKind.schema,
    'texte_manuscrit' => RegionKind.texteManuscrit,
    _ => RegionKind.autre,
  };
}

/// Une zone imagée repérée dans une page.
///
/// Les coins arrivent du serveur en repère normalisé 0-1000, dans l'ordre
/// [y, x] — la verticale d'abord, comme le veut le modèle. Ils sont convertis
/// ici en fractions [0..1] de la page, dans l'ordre (x, y) attendu par tout ce
/// qui dessine : c'est le seul endroit où les deux conventions se croisent.
@immutable
class DetectedRegion {
  /// Haut-gauche, haut-droit, bas-droit, bas-gauche, en fraction de la page.
  final List<Offset> corners;
  final RegionKind kind;
  final String label;
  final double confidence;

  const DetectedRegion({
    required this.corners,
    required this.kind,
    required this.label,
    required this.confidence,
  });

  /// Rend `null` plutôt que de lever : une zone mal formée se saute, elle ne
  /// fait pas échouer la détection entière.
  static DetectedRegion? fromJson(Map<String, dynamic> json) {
    final rawQuad = json['quad'];
    if (rawQuad is! List || rawQuad.length != 4) return null;

    final corners = <Offset>[];
    for (final rawCorner in rawQuad) {
      if (rawCorner is! List || rawCorner.length != 2) return null;
      final y = (rawCorner[0] as num?)?.toDouble();
      final x = (rawCorner[1] as num?)?.toDouble();
      if (y == null || x == null) return null;
      corners.add(Offset(x / 1000, y / 1000));
    }

    return DetectedRegion(
      corners: corners,
      kind: RegionKind.parse(json['kind'] as String?),
      label: (json['label'] as String?)?.trim() ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
    );
  }

  /// Le rectangle qui contient la zone, en fraction de la page.
  Rect get bounds {
    var left = corners.first.dx;
    var right = corners.first.dx;
    var top = corners.first.dy;
    var bottom = corners.first.dy;
    for (final corner in corners) {
      if (corner.dx < left) left = corner.dx;
      if (corner.dx > right) right = corner.dx;
      if (corner.dy < top) top = corner.dy;
      if (corner.dy > bottom) bottom = corner.dy;
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }
}
