import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:kass_dalle/core/presentation/image_enhancer_processing.dart';

/// Une photo de téléphone existe en deux versions.
///
/// Celle que Flutter **affiche** honore l'orientation EXIF. Celle que le paquet
/// `image` **décode** l'ignore. Pour une photo prise en portrait, les deux sont
/// tournées de quatre-vingt-dix degrés l'une par rapport à l'autre.
///
/// La détection des coins et le redressement de perspective travaillent tous
/// deux sur la seconde. Sans remise d'aplomb préalable, ils rendent des
/// coordonnées justes dans un repère couché, que l'écran pose sur l'image
/// debout : les poignées atterrissent à côté de la page, et la découpe suit.
/// Rien ne lève d'erreur — le résultat est net, il montre autre chose.
///
/// Le serveur avait été corrigé en août 2026, l'atelier de retouche non. Le
/// symptôme s'est vu le 1er septembre : « je pousse sur Cadre et les coins ne
/// sont pas au bon endroit ».
///
/// Les tests portent sur [decideUpright] et non sur `uprightIsolate` :
/// `encodeJpg` ne réécrit pas le bloc EXIF, une image fabriquée ici perdrait
/// donc son orientation au premier aller-retour, et le montage mesurerait la
/// bibliothèque au lieu du code.
void main() {
  img.Image photo({int? orientation}) {
    // Grille stockée en paysage — ce que produit un téléphone tenu droit.
    final source = img.Image(width: 40, height: 20);
    if (orientation != null) source.exif.imageIfd.orientation = orientation;
    return source;
  }

  group('decideUpright', () {
    test('un quart de tour est appliqué dans les pixels', () {
      final decision = decideUpright(photo(orientation: 6));

      expect(decision.rotated, isTrue);
      expect(decision.image.width, 20);
      expect(decision.image.height, 40);
    });

    test('une image sans orientation reste telle quelle', () {
      final source = photo();
      final decision = decideUpright(source);

      expect(decision.rotated, isFalse);
      expect(identical(decision.image, source), isTrue);
    });

    test('une orientation 1 ne déclenche aucun réencodage', () {
      // Réencoder pour rien coûterait une génération de JPEG, donc de la
      // netteté, sans rien corriger.
      final source = photo(orientation: 1);
      final decision = decideUpright(source);

      expect(decision.rotated, isFalse);
      expect(identical(decision.image, source), isTrue);
    });

    test('un demi-tour est appliqué, à dimensions inchangées', () {
      // Le piège de la version qui décidait sur les dimensions : quatre des
      // huit orientations ne changent ni la largeur ni la hauteur. Un demi-tour
      // ignoré met les coins détectés à l'exact opposé de la page.
      final decision = decideUpright(photo(orientation: 3));

      expect(decision.rotated, isTrue);
      expect(decision.image.width, 40);
      expect(decision.image.height, 20);
    });

    test('un miroir horizontal est appliqué lui aussi', () {
      final decision = decideUpright(photo(orientation: 2));

      expect(decision.rotated, isTrue);
      expect(decision.image.width, 40);
    });
  });
}
