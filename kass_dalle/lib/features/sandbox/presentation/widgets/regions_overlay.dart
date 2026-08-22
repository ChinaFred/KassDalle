import 'package:flutter/material.dart';

import '../../domain/detected_region.dart';

/// Dessine les zones détectées par-dessus la page redressée.
///
/// Les coins sont en fraction de la page : le peintre les multiplie par la
/// taille réelle du cadre. Tant que la boîte peinte est exactement celle de
/// l'image — même rapport, même position — les cadres tombent juste, quelle
/// que soit la taille d'écran.
class RegionsOverlayPainter extends CustomPainter {
  final List<DetectedRegion> regions;

  /// Épais et rouge : ces cadres servent à juger un cadrage d'un coup d'œil,
  /// pas à décorer.
  static const Color _stroke = Color(0xFFE53935);
  static const double _strokeWidth = 5;

  const RegionsOverlayPainter({required this.regions});

  @override
  void paint(Canvas canvas, Size size) {
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..color = _stroke;

    for (var index = 0; index < regions.length; index++) {
      final corners = regions[index].corners
          .map((c) => Offset(c.dx * size.width, c.dy * size.height))
          .toList(growable: false);

      final path = Path()..moveTo(corners.first.dx, corners.first.dy);
      for (final corner in corners.skip(1)) {
        path.lineTo(corner.dx, corner.dy);
      }
      path.close();
      canvas.drawPath(path, border);

      _paintBadge(canvas, corners.first, index + 1);
    }
  }

  /// Le numéro, posé au coin haut-gauche de la zone.
  ///
  /// Sans lui, deux cadres qui se touchent ne se distinguent plus de la liste
  /// affichée dessous.
  void _paintBadge(Canvas canvas, Offset anchor, int number) {
    const radius = 14.0;
    final center = Offset(anchor.dx + radius, anchor.dy + radius);

    canvas.drawCircle(center, radius, Paint()..color = _stroke);

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
  bool shouldRepaint(RegionsOverlayPainter oldDelegate) =>
      oldDelegate.regions != regions;
}
