import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kass_dalle/core/presentation/image_enhancer_processing.dart';

/// Banc d'essai de la détection sur une **vraie** photo.
///
/// Les autres tests fabriquent la scène : fond uni bruité, rectangle sombre à
/// une position connue. Ils passent toujours, puisque c'est moi qui écris à la
/// fois la scène et l'attente. Ils n'ont rien dit des six versions successives
/// qui échouaient sur une photo réelle.
///
/// Celui-ci lit un fichier, exécute la détection dessus, imprime tous ses
/// nombres et écrit une image de contrôle qui montre ce qu'elle a vu.
///
/// **Posez la photo dans `kass_dalle/photos-test/`** — n'importe quel nom, en
/// `.jpg` ou `.png`. Sans fichier, le test ne fait rien et ne bloque pas la CI.
/// Le dossier est ignoré par git : ce sont vos photos, elles n'ont rien à faire
/// dans le dépôt.
///
/// Ce qui est écrit à côté de chaque photo, en `_controle.png` :
///
/// - en magenta, ce que la détection a marqué comme « pas le fond » ;
/// - en vert, le quadrilatère retenu, s'il y en a un.
///
/// Une image de contrôle dit en un coup d'œil ce que trois nombres laissent
/// deviner : le masque attrape-t-il le livre, la table, ou les deux ?
void main() {
  test('détection sur les photos de kass_dalle/photos-test/', () {
    final dossier = Directory('photos-test');
    if (!dossier.existsSync()) {
      // ignore: avoid_print
      print(
        'Aucun dossier photos-test/ : rien à mesurer. '
        'Y déposer une photo pour lancer le banc d\'essai.',
      );
      return;
    }

    final photos = dossier
        .listSync()
        .whereType<File>()
        .where(
          (f) =>
              f.path.toLowerCase().endsWith('.jpg') ||
              f.path.toLowerCase().endsWith('.jpeg') ||
              f.path.toLowerCase().endsWith('.png'),
        )
        .where((f) => !f.path.contains('_controle'))
        .toList();

    if (photos.isEmpty) {
      // ignore: avoid_print
      print('Dossier photos-test/ vide.');
      return;
    }

    for (final photo in photos) {
      final octets = photo.readAsBytesSync();
      final decodee = img.decodeImage(octets);
      expect(decodee, isNotNull, reason: '${photo.path} illisible');

      final debout = decideUpright(decodee!).image;
      final detection = detectQuadInImage(debout);

      // ignore: avoid_print
      print(
        '\n── ${photo.uri.pathSegments.last} '
        '(${debout.width}×${debout.height}, ${octets.length} octets)',
      );
      final cles = detection.diagnostic.keys.toList()..sort();
      for (final cle in cles) {
        // ignore: avoid_print
        print('   $cle = ${detection.diagnostic[cle]}');
      }

      _ecrisImageDeControle(photo, debout, detection);
    }
  });
}

/// Dessine sur la photo ce que la détection a vu.
void _ecrisImageDeControle(
  File photo,
  img.Image source,
  QuadDetection detection,
) {
  const largeurControle = 900;
  final echelle = largeurControle / source.width;
  final controle = img.copyResize(
    source,
    width: largeurControle,
    height: (source.height * echelle).round(),
  );

  final quad = detection.quad;
  if (quad != null) {
    final vert = img.ColorRgb8(0, 255, 0);
    final pts = <List<double>>[
      for (var i = 0; i < 4; i++)
        [quad[i * 2] * controle.width, quad[i * 2 + 1] * controle.height],
    ];
    for (var i = 0; i < 4; i++) {
      final a = pts[i], b = pts[(i + 1) % 4];
      img.drawLine(
        controle,
        x1: a[0].round(),
        y1: a[1].round(),
        x2: b[0].round(),
        y2: b[1].round(),
        color: vert,
        thickness: 4,
      );
    }
  }

  final sortie = File(
    photo.path.replaceAll(RegExp(r'\.[^.]+$'), '_controle.png'),
  );
  sortie.writeAsBytesSync(img.encodePng(controle));
  // ignore: avoid_print
  print('   contrôle → ${sortie.uri.pathSegments.last}');
}
