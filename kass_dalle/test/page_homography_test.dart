/// Géométrie du redressement d'une page — la moitié Dart de la fixture partagée.
///
/// L'homographie existe **en double** : ici, dans l'atelier de retouche
/// (`core/presentation/image_enhancer_processing.dart`), et côté serveur dans
/// `functions/src/gemini/perspective.ts`, où elle sert l'extraction des
/// illustrations d'une page importée. Même algorithme des deux côtés —
/// normalisation de Hartley, DLT, élimination de Gauss avec pivot partiel — et,
/// jusqu'ici, rien qui garantisse qu'ils restent d'accord.
///
/// Un écart ne casse aucun écran et ne lève aucune erreur. Il rend une page
/// redressée de travers, parfaitement nette : le genre de faute qu'on découvre
/// des semaines plus tard, sur une découpe déjà publiée.
///
/// `test-fixtures/page_homography.json` est rejouée par les deux suites.
/// Corriger un des deux côtés sans ajouter le cas ici fait échouer la CI de
/// l'autre — c'est le but.
library;

import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/image_enhancer_processing.dart';

/// Applique une homographie 3×3 (ligne par ligne) à un point.
Offset _project(List<double> h, double x, double y) {
  final denominator = h[6] * x + h[7] * y + h[8];
  return Offset(
    (h[0] * x + h[1] * y + h[2]) / denominator,
    (h[3] * x + h[4] * y + h[5]) / denominator,
  );
}

List<Offset> _readQuad(dynamic raw) => [
  for (final point in raw as List)
    Offset((point['x'] as num).toDouble(), (point['y'] as num).toDouble()),
];

void main() {
  final file = File('test-fixtures/page_homography.json');
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final tolerance = (fixture['tolerance'] as num).toDouble();
  final cases = fixture['cases'] as List;

  group('page_homography.json — redressement d\'une page', () {
    for (final entry in cases) {
      final data = entry as Map<String, dynamic>;
      final name = data['name'] as String;
      final why = data['why'] as String;
      final quad = _readQuad(data['quad']);
      final size = data['size'] as Map<String, dynamic>;
      final width = size['width'] as int;
      final height = size['height'] as int;

      test('$name : taille de sortie $width sur $height  ($why)', () {
        final actual = outputSizeFor(quad);
        expect(actual.width, width);
        expect(actual.height, height);
      });

      test('$name : l\'homographie envoie chaque point où il faut', () {
        final destination = <Offset>[
          const Offset(0, 0),
          Offset(width.toDouble(), 0),
          Offset(width.toDouble(), height.toDouble()),
          Offset(0, height.toDouble()),
        ];
        final h = computeHomography(quad, destination);

        for (final probe in data['probes'] as List) {
          final entry = probe as Map<String, dynamic>;
          final from = entry['from'] as Map<String, dynamic>;
          final to = entry['to'] as Map<String, dynamic>;
          final got = _project(
            h,
            (from['x'] as num).toDouble(),
            (from['y'] as num).toDouble(),
          );
          expect(
            got.dx,
            closeTo((to['x'] as num).toDouble(), tolerance),
            reason: 'abscisse de (${from['x']}, ${from['y']})',
          );
          expect(
            got.dy,
            closeTo((to['y'] as num).toDouble(), tolerance),
            reason: 'ordonnée de (${from['x']}, ${from['y']})',
          );
        }
      });
    }
  });
}
