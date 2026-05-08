import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Génère une image de couverture PNG 600×800 pour le livre
/// "Mes créations Kass'Dalle ✨".
///
/// Utilise uniquement [dart:ui] (disponible sur toutes les plateformes Flutter)
/// sans dépendance externe.
class KassDalleCoverGenerator {
  static const double _w = 600;
  static const double _h = 800;

  static Future<Uint8List> generate() async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, _w, _h),
    );

    _drawBackground(canvas);
    _drawRadialGlow(canvas);
    _drawStars(canvas);
    _drawSparkle(canvas, const ui.Offset(_w / 2, _h * 0.38), 82,
        const ui.Color(0xFFE4D2FF));
    _drawSparkle(canvas, const ui.Offset(_w / 2 - 118, _h * 0.24), 24,
        const ui.Color(0xCCD2B8FF));
    _drawSparkle(canvas, const ui.Offset(_w / 2 + 132, _h * 0.19), 17,
        const ui.Color(0xCCD2B8FF));
    _drawSparkle(canvas, const ui.Offset(_w / 2 - 58, _h * 0.56), 12,
        const ui.Color(0xAAD2B8FF));
    _drawSparkle(canvas, const ui.Offset(_w / 2 + 88, _h * 0.53), 14,
        const ui.Color(0xAAD2B8FF));
    _drawSparkle(canvas, const ui.Offset(_w / 2 + 165, _h * 0.49), 9,
        const ui.Color(0x88D2B8FF));

    _centeredText(
      canvas,
      'Mes créations',
      _w / 2,
      _h * 0.60,
      30,
      const ui.Color(0xCCDDCCFF),
    );
    _centeredText(
      canvas,
      "Kass'Dalle",
      _w / 2,
      _h * 0.655,
      54,
      const ui.Color(0xFFFFFFFF),
      bold: true,
    );
    _centeredText(
      canvas,
      "Recettes créées par l'IA",
      _w / 2,
      _h * 0.755,
      20,
      const ui.Color(0x88BDB2EE),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(_w.toInt(), _h.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  // ── Couches graphiques ──────────────────────────────────────────────────────

  static void _drawBackground(ui.Canvas canvas) {
    final paint = ui.Paint()
      ..shader = ui.Gradient.linear(
        ui.Offset.zero,
        const ui.Offset(_w, _h),
        const [
          ui.Color(0xFF0C001F),
          ui.Color(0xFF1C0A38),
          ui.Color(0xFF051222),
        ],
        [0.0, 0.55, 1.0],
      );
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, _w, _h), paint);
  }

  static void _drawRadialGlow(ui.Canvas canvas) {
    final paint = ui.Paint()
      ..shader = ui.Gradient.radial(
        const ui.Offset(_w / 2, _h * 0.38),
        270,
        const [ui.Color(0x44A060FF), ui.Color(0x00000000)],
      );
    canvas.drawRect(ui.Rect.fromLTWH(0, 0, _w, _h), paint);
  }

  static void _drawStars(ui.Canvas canvas) {
    final rng = Random(42);
    for (int i = 0; i < 50; i++) {
      final x = rng.nextDouble() * _w;
      final y = rng.nextDouble() * _h * 0.88;
      final r = rng.nextDouble() * 1.6 + 0.4;
      final opacity = (rng.nextDouble() * 0.55 + 0.25).clamp(0.0, 1.0);
      canvas.drawCircle(
        ui.Offset(x, y),
        r,
        ui.Paint()
          ..color =
              ui.Color.fromARGB((opacity * 255).round(), 255, 255, 255),
      );
    }
  }

  /// Étoile à 4 branches (sparkle).
  static void _drawSparkle(
    ui.Canvas canvas,
    ui.Offset c,
    double size,
    ui.Color color,
  ) {
    final h = size / 2;
    final q = size / 5;
    final path = ui.Path()
      ..moveTo(c.dx, c.dy - h)
      ..cubicTo(c.dx + q, c.dy - q, c.dx + q, c.dy - q, c.dx + h, c.dy)
      ..cubicTo(c.dx + q, c.dy + q, c.dx + q, c.dy + q, c.dx, c.dy + h)
      ..cubicTo(c.dx - q, c.dy + q, c.dx - q, c.dy + q, c.dx - h, c.dy)
      ..cubicTo(c.dx - q, c.dy - q, c.dx - q, c.dy - q, c.dx, c.dy - h)
      ..close();
    canvas.drawPath(path, ui.Paint()..color = color);

    if (size > 40) {
      canvas.drawCircle(
        c,
        size * 0.18,
        ui.Paint()
          ..color = const ui.Color(0xAAFFFFFF)
          ..maskFilter =
              const ui.MaskFilter.blur(ui.BlurStyle.normal, 10),
      );
    }
  }

  static void _centeredText(
    ui.Canvas canvas,
    String text,
    double cx,
    double y,
    double fontSize,
    ui.Color color, {
    bool bold = false,
  }) {
    const double textWidth = 560;
    final pb = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textAlign: ui.TextAlign.center,
        fontSize: fontSize,
        fontWeight:
            bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
      ),
    )
      ..pushStyle(ui.TextStyle(color: color))
      ..addText(text);
    final para = pb.build()
      ..layout(const ui.ParagraphConstraints(width: textWidth));
    canvas.drawParagraph(para, ui.Offset(cx - textWidth / 2, y));
  }
}
