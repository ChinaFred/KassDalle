import 'package:flutter/material.dart';

import '../../domain/detected_region.dart';

/// Dessine des quadrilatères par-dessus une image.
///
/// Les coins sont en fraction de l'image : le peintre les multiplie par la
/// taille du cadre. Tant que la boîte peinte est exactement celle de l'image —
/// même rapport, même position — les cadres tombent juste, quelle que soit la
/// taille d'écran.
class SandboxQuadPainter extends CustomPainter {
  /// Un quadrilatère par entrée, quatre coins en fraction de l'image.
  final List<List<Offset>> quads;

  /// Numérote les cadres. Sans numéro, deux cadres qui se touchent ne se
  /// rattachent plus à la liste affichée dessous.
  final bool numbered;

  final Color color;

  /// Épais et rouge par défaut : ces cadres servent à juger un cadrage d'un
  /// coup d'œil, pas à décorer.
  static const Color defaultColor = Color(0xFFE53935);

  const SandboxQuadPainter({
    required this.quads,
    this.numbered = true,
    this.color = defaultColor,
  });

  /// Le peintre des zones détectées à l'étape 3.
  factory SandboxQuadPainter.regions(List<DetectedRegion> regions) =>
      SandboxQuadPainter(
        quads: regions.map((r) => r.corners).toList(growable: false),
      );

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    for (var index = 0; index < quads.length; index++) {
      final corners = quads[index]
          .map((c) => Offset(c.dx * size.width, c.dy * size.height))
          .toList(growable: false);
      if (corners.length < 3) continue;

      final path = Path()..moveTo(corners.first.dx, corners.first.dy);
      for (final corner in corners.skip(1)) {
        path.lineTo(corner.dx, corner.dy);
      }
      path.close();
      canvas.drawPath(path, border);

      if (numbered) _paintBadge(canvas, corners.first, index + 1);
    }
  }

  /// Le numéro, posé au coin haut-gauche du cadre.
  void _paintBadge(Canvas canvas, Offset anchor, int number) {
    const radius = 14.0;
    final center = Offset(anchor.dx + radius, anchor.dy + radius);

    canvas.drawCircle(center, radius, Paint()..color = color);

    final painter = TextPainter(
      text: TextSpan(
        text: '$number',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(SandboxQuadPainter oldDelegate) =>
      oldDelegate.quads != quads ||
      oldDelegate.color != color ||
      oldDelegate.numbered != numbered;
}
