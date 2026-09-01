import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kass_dalle/core/presentation/image_enhancer_processing.dart';

/// Détection du document dans une photo.
///
/// Le cas réel : un livre foncé posé sur une table claire, photographié de
/// face. La version précédente cherchait un contour au gradient de Sobel et
/// s'arrêtait au premier bord franc rencontré depuis le centre. Sur une
/// couverture — qui est une photographie — elle butait sur le bord d'une
/// assiette, ou filait jusqu'au cadre de la photo. Les quatre validations du
/// 1er septembre 2026 donnaient des coins à 1,8 %, 2,6 %, 14,6 % et 19,5 % des
/// bords : jamais sur le livre.
///
/// Ces tests fabriquent la scène plutôt que de la photographier : fond clair
/// bruité, rectangle sombre à une position connue. On vérifie que les coins
/// rendus tombent sur le rectangle, à la tolérance de la réduction à 512 px.
void main() {
  final alea = math.Random(7);

  /// Une table claire, légèrement veinée, avec ou sans livre posé dessus.
  img.Image scene({
    double? gauche,
    double? haut,
    double? droite,
    double? bas,
    double rotationDeg = 0,
    int fond = 205,
    int livre = 55,
  }) {
    final image = img.Image(width: 300, height: 400);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        // Veinage : un fond parfaitement uni ne dirait rien du seuil adaptatif.
        final bruit = alea.nextInt(17) - 8;
        final v = (fond + bruit).clamp(0, 255);
        image.setPixelRgb(
          x,
          y,
          v,
          (v - 12).clamp(0, 255),
          (v - 30).clamp(0, 255),
        );
      }
    }
    if (gauche == null) return image;

    final x0 = gauche * image.width;
    final x1 = droite! * image.width;
    final y0 = haut! * image.height;
    final y1 = bas! * image.height;
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    final a = rotationDeg * math.pi / 180.0;
    final cosA = math.cos(-a), sinA = math.sin(-a);

    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final dx = x - cx, dy = y - cy;
        final u = dx * cosA - dy * sinA + cx;
        final v = dx * sinA + dy * cosA + cy;
        if (u < x0 || u > x1 || v < y0 || v > y1) continue;
        // La couverture est une photographie : elle porte ses propres contours,
        // dont un aplat clair — l'assiette blanche qui égarait l'ancienne
        // détection.
        final assiette =
            u > x0 + (x1 - x0) * 0.25 &&
            u < x0 + (x1 - x0) * 0.75 &&
            v > y0 + (y1 - y0) * 0.55 &&
            v < y0 + (y1 - y0) * 0.90;
        final t = assiette ? 240 : livre + alea.nextInt(40);
        image.setPixelRgb(x, y, t, t, t);
      }
    }
    return image;
  }

  /// Les quatre coins rendus, en fractions de l'image.
  List<double> coins(img.Image image) {
    final quad = detectQuadInImage(image).quad;
    expect(quad, isNotNull, reason: 'aucun document détecté');
    return quad!;
  }

  group('detectQuadInImage', () {
    test('un livre foncé sur une table claire est cadré', () {
      final quad = coins(
        scene(gauche: 0.20, haut: 0.15, droite: 0.80, bas: 0.85),
      );

      // haut-gauche, haut-droit, bas-droit, bas-gauche
      expect(quad[0], closeTo(0.20, 0.04));
      expect(quad[1], closeTo(0.15, 0.04));
      expect(quad[2], closeTo(0.80, 0.04));
      expect(quad[3], closeTo(0.15, 0.04));
      expect(quad[4], closeTo(0.80, 0.04));
      expect(quad[5], closeTo(0.85, 0.04));
      expect(quad[6], closeTo(0.20, 0.04));
      expect(quad[7], closeTo(0.85, 0.04));
    });

    test('l\'aplat clair intérieur ne casse pas le cadrage', () {
      // C'est le piège de l'ancienne méthode : l'assiette blanche ressemble au
      // fond. La fermeture morphologique la rattache à la tache du livre.
      final quad = coins(
        scene(gauche: 0.15, haut: 0.10, droite: 0.85, bas: 0.90),
      );

      expect(quad[0], closeTo(0.15, 0.05));
      expect(quad[5], closeTo(0.90, 0.05));
    });

    test('un livre posé de travers est suivi', () {
      final quad = coins(
        scene(
          gauche: 0.22,
          haut: 0.18,
          droite: 0.78,
          bas: 0.82,
          rotationDeg: 8,
        ),
      );

      // Le rectangle tourné déborde la boîte droite : on vérifie qu'il reste
      // centré sur le livre et n'a pas filé sur les bords de la photo.
      final xs = [quad[0], quad[2], quad[4], quad[6]];
      final ys = [quad[1], quad[3], quad[5], quad[7]];
      expect(xs.reduce(math.min), greaterThan(0.10));
      expect(xs.reduce(math.max), lessThan(0.90));
      expect(ys.reduce(math.min), greaterThan(0.08));
      expect(ys.reduce(math.max), lessThan(0.92));
    });

    test('une table vide ne fabrique pas de document', () {
      // L'ancienne méthode rendait le cadre de la photo. Ne rien rendre laisse
      // les coins par défaut, ce qui est plus honnête qu'un cadrage inventé.
      expect(detectQuadInImage(scene()).quad, isNull);
    });

    test('un livre qui remplit toute la photo est écarté', () {
      // Il n'y a alors rien à recadrer, et le fond ne peut plus être modélisé.
      expect(
        detectQuadInImage(
          scene(gauche: 0.0, haut: 0.0, droite: 1.0, bas: 1.0),
        ).quad,
        isNull,
      );
    });
  });
}
