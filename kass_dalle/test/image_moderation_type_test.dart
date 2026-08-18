import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/moderation/data/image_moderation_service.dart';

/// Résolution du type MIME d'une image avant envoi en quarantaine.
///
/// Ce test existe à cause d'une panne réelle : `image/$ext` produisait
/// `image/jpg` pour un fichier `.jpg`, la règle de quarantaine n'accepte que
/// `image/jpeg`, et l'utilisateur lisait
/// `[firebase_storage/unauthorized] User is not authorized` — un message qui
/// accuse ses droits pour un problème de format.
void main() {
  Uint8List jpeg([int extra = 16]) =>
      Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List.filled(extra, 0)]);
  Uint8List png([int extra = 16]) => Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...List.filled(extra, 0),
  ]);

  group('canonicalImageType', () {
    test('un .jpg rend image/jpeg, jamais image/jpg', () {
      // `image/jpg` n'existe pas. C'est exactement ce que produisait la
      // concaténation, et ce que la quarantaine refusait.
      expect(canonicalImageType(jpeg(), 'photo.jpg'), 'image/jpeg');
    });

    test('un .jpeg rend image/jpeg', () {
      expect(canonicalImageType(jpeg(), 'photo.jpeg'), 'image/jpeg');
    });

    test('un .png rend image/png', () {
      expect(canonicalImageType(png(), 'photo.png'), 'image/png');
    });

    test('la signature l\'emporte sur un nom qui ment', () {
      // Le sélecteur réencode en JPEG sans toujours renommer : une photo
      // iPhone arrive en .heic avec des octets JPEG. La refuser sur son nom
      // écarterait une image que le serveur accepterait.
      expect(canonicalImageType(jpeg(), 'IMG_0042.heic'), 'image/jpeg');
      expect(canonicalImageType(png(), 'capture.webp'), 'image/png');
    });

    test('un nom sans extension passe encore par la signature', () {
      expect(canonicalImageType(jpeg(), 'sans_extension'), 'image/jpeg');
    });

    test('l\'extension sert de repli quand la signature est inconnue', () {
      final inconnu = Uint8List.fromList(List.filled(32, 0x42));
      expect(canonicalImageType(inconnu, 'photo.png'), 'image/png');
      expect(canonicalImageType(inconnu, 'photo.JPG'), 'image/jpeg');
    });

    test('un format ni reconnu ni nommé rend null', () {
      final inconnu = Uint8List.fromList(List.filled(32, 0x42));
      expect(canonicalImageType(inconnu, 'document.webp'), isNull);
      expect(canonicalImageType(inconnu, 'sans_extension'), isNull);
      expect(canonicalImageType(Uint8List(0), 'vide.jpg'), 'image/jpeg');
    });

    test('un refus de format se dit, il ne se devine pas', () {
      // L'exception porte le nom du fichier et les formats acceptés : sans
      // cela, l'utilisateur ne sait pas quoi faire de son image.
      final message = const UnsupportedImageFormat('photo.webp').toString();
      expect(message, contains('photo.webp'));
      expect(message, contains('JPEG'));
      expect(message, contains('PNG'));
    });
  });
}
