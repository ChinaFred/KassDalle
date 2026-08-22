import 'package:flutter/material.dart';

/// Ce que le modèle dit avoir cadré.
enum PageKind {
  page('Page'),
  doublePage('Double page'),
  feuille('Feuille'),
  autre('Autre');

  final String label;

  const PageKind(this.label);

  static PageKind parse(String? raw) => switch (raw) {
    'page' => PageKind.page,
    'double_page' => PageKind.doublePage,
    'feuille' => PageKind.feuille,
    _ => PageKind.autre,
  };
}

/// La page repérée dans la photo, et ses quatre coins.
///
/// Les coins arrivent du serveur en repère normalisé 0-1000, dans l'ordre
/// [y, x] — la verticale d'abord, comme le veut le modèle. Ils sont convertis
/// ici en fractions [0..1] de l'image, dans l'ordre (x, y) attendu par tout ce
/// qui dessine et par `warpIsolate`. C'est le seul endroit où les deux
/// conventions se croisent.
@immutable
class DetectedPage {
  /// Haut-gauche, haut-droit, bas-droit, bas-gauche, en fraction de l'image.
  final List<Offset> corners;
  final PageKind kind;
  final double confidence;

  /// Ce que le modèle dit avoir vu. Sert à comprendre un cadrage douteux.
  final String note;

  const DetectedPage({
    required this.corners,
    required this.kind,
    required this.confidence,
    required this.note,
  });

  /// Rend `null` plutôt que de lever : une réponse mal formée est un échec de
  /// détection, pas une panne de l'écran.
  static DetectedPage? fromJson(Map<String, dynamic> json) {
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

    return DetectedPage(
      corners: corners,
      kind: PageKind.parse(json['kind'] as String?),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      note: (json['note'] as String?)?.trim() ?? '',
    );
  }

  /// `[x0,y0, x1,y1, x2,y2, x3,y3]`, la forme attendue par `warpIsolate`.
  List<double> get cornersFlat => [
    for (final corner in corners) ...[corner.dx, corner.dy],
  ];

  /// Part de l'image couverte, entre 0 et 1.
  double get coverage {
    var sum = 0.0;
    for (var i = 0; i < corners.length; i++) {
      final a = corners[i];
      final b = corners[(i + 1) % corners.length];
      sum += a.dx * b.dy - b.dx * a.dy;
    }
    return sum.abs() / 2;
  }

  /// Les quatre coins sont-ils ceux de l'image ?
  ///
  /// Sur un scan à plat, le modèle rend le cadre entier. Redresser reviendrait
  /// à rééchantillonner chaque pixel pour rien — et un rééchantillonnage coûte
  /// de la netteté.
  bool get isFullFrame {
    const tolerance = 0.015;
    const expected = [Offset(0, 0), Offset(1, 0), Offset(1, 1), Offset(0, 1)];
    for (var i = 0; i < expected.length; i++) {
      if ((corners[i].dx - expected[i].dx).abs() > tolerance) return false;
      if ((corners[i].dy - expected[i].dy).abs() > tolerance) return false;
    }
    return true;
  }
}
