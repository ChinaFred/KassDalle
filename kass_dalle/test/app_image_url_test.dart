import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/app_image_url.dart';
import 'package:kass_dalle/core/widgets/app_network_image.dart';

/// Le filtre des images affichées : seul le stockage du projet passe.
void main() {
  const bucket = 'kassdale-6d948.firebasestorage.app';
  const download =
      'https://firebasestorage.googleapis.com/v0/b/$bucket/o/'
      'recipes%2Fabc%2Fphoto.jpg?alt=media&token=123';

  group('isAppImageUrl', () {
    test('le bucket du projet est celui de firebase_options', () {
      expect(kAppStorageBucket, bucket);
    });

    test('accepte une URL de téléchargement du bucket du projet', () {
      expect(isAppImageUrl(download, allowEmulator: false), isTrue);
    });

    test('accepte l\'URL publique storage.googleapis.com du bucket', () {
      expect(
        isAppImageUrl(
          'https://storage.googleapis.com/$bucket/illustrations/a.png',
          allowEmulator: false,
        ),
        isTrue,
      );
    });

    test('refuse un autre bucket', () {
      expect(
        isAppImageUrl(
          'https://firebasestorage.googleapis.com/v0/b/autre-projet.appspot.com'
          '/o/recipes%2Fa.jpg?alt=media',
          allowEmulator: false,
        ),
        isFalse,
      );
      expect(
        isAppImageUrl(
          'https://storage.googleapis.com/autre-bucket/a.png',
          allowEmulator: false,
        ),
        isFalse,
      );
    });

    test('refuse un autre hôte, même avec le chemin du bucket', () {
      for (final url in [
        'https://example.com/v0/b/$bucket/o/a.jpg',
        'https://firebasestorage.googleapis.com.evil.com/v0/b/$bucket/o/a.jpg',
        'https://lh3.googleusercontent.com/a/photo.jpg',
        'https://cdn.example.org/plat.png',
      ]) {
        expect(isAppImageUrl(url, allowEmulator: false), isFalse, reason: url);
      }
    });

    test(
      'refuse le bon hôte en http, sur un autre port ou avec identifiants',
      () {
        expect(
          isAppImageUrl(
            download.replaceFirst('https', 'http'),
            allowEmulator: false,
          ),
          isFalse,
        );
        expect(
          isAppImageUrl(
            'https://firebasestorage.googleapis.com:8443/v0/b/$bucket/o/a.jpg',
            allowEmulator: false,
          ),
          isFalse,
        );
        expect(
          isAppImageUrl(
            'https://moi@firebasestorage.googleapis.com/v0/b/$bucket/o/a.jpg',
            allowEmulator: false,
          ),
          isFalse,
        );
      },
    );

    test('refuse un chemin qui ne désigne pas un objet', () {
      for (final url in [
        'https://firebasestorage.googleapis.com/v0/b/$bucket/o/',
        'https://firebasestorage.googleapis.com/v0/b/$bucket/o/a/b.jpg',
        'https://firebasestorage.googleapis.com/v1/b/$bucket/o/a.jpg',
        'https://storage.googleapis.com/$bucket/',
      ]) {
        expect(isAppImageUrl(url, allowEmulator: false), isFalse, reason: url);
      }
    });

    test('refuse une URL mal formée, vide ou absente', () {
      for (final url in [
        null,
        '',
        '   ',
        'pas une url',
        'http://[::1',
        'recipes/abc/photo.jpg',
        'assets/opensource.png',
        'data:image/png;base64,AAAA',
        'blob:https://kassdale-6d948.web.app/1234',
        'file:///tmp/a.jpg',
      ]) {
        expect(isAppImageUrl(url, allowEmulator: false), isFalse, reason: url);
      }
    });

    test('l\'émulateur Storage passe en debug seulement', () {
      const emulator = 'http://127.0.0.1:9199/v0/b/$bucket/o/recipes%2Fa.jpg';
      expect(isAppImageUrl(emulator, allowEmulator: true), isTrue);
      expect(
        isAppImageUrl(
          'http://10.0.2.2:9199/v0/b/$bucket/o/recipes%2Fa.jpg',
          allowEmulator: true,
        ),
        isTrue,
      );
      expect(isAppImageUrl(emulator, allowEmulator: false), isFalse);
      // L'émulateur ne sert que le bucket du projet.
      expect(
        isAppImageUrl(
          'http://localhost:9199/v0/b/autre/o/a.jpg',
          allowEmulator: true,
        ),
        isFalse,
      );
    });

    test('accepte chacun des dossiers publiés, sous les deux formes', () {
      for (final prefix in kPublishedImagePrefixes) {
        final encoded = Uri.encodeComponent('${prefix}u1/photo.jpg');
        expect(
          isAppImageUrl(
            'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encoded'
            '?alt=media&token=t',
            allowEmulator: false,
          ),
          isTrue,
          reason: prefix,
        );
        expect(
          isAppImageUrl(
            'https://storage.googleapis.com/$bucket/${prefix}u1/photo.jpg',
            allowEmulator: false,
          ),
          isTrue,
          reason: prefix,
        );
      }
      expect(kPublishedImagePrefixes, [
        'covers/',
        'scans/',
        'illustrations/',
        'recipes/',
        'users/',
      ]);
    });

    test('refuse une image non modérée du bon bucket (ticket #154)', () {
      for (final path in [
        'quarantine/u1/photo.jpg',
        'quarantine/u1/livres/livre.pdf',
        'rejected/u1/photo.jpg',
        'tickets/u1/t1/screenshot.png',
        'photo.jpg',
        'autre/u1/photo.jpg',
        // Préfixe nu, ou un dossier qui n'en a que le début.
        'recipes/',
        'recipesx/a.jpg',
        'Recipes/a.jpg',
      ]) {
        final encoded = Uri.encodeComponent(path);
        expect(
          isAppImageUrl(
            'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encoded'
            '?alt=media&token=t',
            allowEmulator: false,
          ),
          isFalse,
          reason: path,
        );
        expect(
          isAppImageUrl(
            'https://storage.googleapis.com/$bucket/$path',
            allowEmulator: false,
          ),
          isFalse,
          reason: path,
        );
        expect(
          isAppImageUrl(
            'http://127.0.0.1:9199/v0/b/$bucket/o/$encoded',
            allowEmulator: true,
          ),
          isFalse,
          reason: path,
        );
      }
    });

    test('refuse un chemin encodé avec `..`, `.`, un segment vide ou vide', () {
      for (final encoded in [
        'recipes%2F..%2Fquarantine%2Fu1%2Fa.jpg',
        'recipes%2F%2E%2E%2Fquarantine%2Fu1%2Fa.jpg',
        'recipes%2F.%2Fa.jpg',
        'recipes%2F%2Fa.jpg',
        'recipes%2Fa%2F',
        'recipes%2Fa%5Cb.jpg',
        'recipes%2Fa%00.jpg',
        '%2Frecipes%2Fa.jpg',
        '..',
      ]) {
        expect(
          isAppImageUrl(
            'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encoded',
            allowEmulator: false,
          ),
          isFalse,
          reason: encoded,
        );
      }
      for (final path in [
        'recipes/a%2F..%2F..%2Fquarantine%2Fu1%2Fa.jpg',
        'recipes//a.jpg',
        'recipes/a/',
        'recipes/.%2Fa.jpg',
      ]) {
        expect(
          isAppImageUrl(
            'https://storage.googleapis.com/$bucket/$path',
            allowEmulator: false,
          ),
          isFalse,
          reason: path,
        );
      }
    });

    test('refuse un encodage illisible sans lever d\'exception', () {
      for (final encoded in [
        'recipes%2F%E0%A4%A',
        'recipes%2F%C3',
        'recipes%2F%FF.jpg',
      ]) {
        expect(
          isAppImageUrl(
            'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encoded',
            allowEmulator: false,
          ),
          isFalse,
          reason: encoded,
        );
      }
    });

    test('accepte un nom de fichier encodé hors ASCII', () {
      final encoded = Uri.encodeComponent('recipes/r1/crème brûlée.jpg');
      expect(
        isAppImageUrl(
          'https://firebasestorage.googleapis.com/v0/b/$bucket/o/$encoded',
          allowEmulator: false,
        ),
        isTrue,
      );
    });

    test('un ensemble de buckets explicite remplace ceux du projet', () {
      expect(
        isAppImageUrl(download, buckets: {'autre'}, allowEmulator: false),
        isFalse,
      );
    });

    test('l\'ancien bucket du même projet reste accepté', () {
      expect(kAppStorageBuckets, contains('kassdale-6d948.appspot.com'));
      expect(
        isAppImageUrl(
          'https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.appspot.com'
          '/o/illustrations%2Fa.jpg?alt=media',
          allowEmulator: false,
        ),
        isTrue,
      );
      expect(
        isAppImageUrl(
          'https://storage.googleapis.com/kassdale-6d948.appspot.com/covers/u/a.png',
          allowEmulator: false,
        ),
        isTrue,
      );
    });

    test(
      'requireAppImageUrl lève ForeignImageUrl avant tout téléchargement',
      () {
        expect(
          () => requireAppImageUrl('https://cdn.example.org/plat.png'),
          throwsA(isA<ForeignImageUrl>()),
        );
        expect(() => requireAppImageUrl(download), returnsNormally);
        expect(
          const ForeignImageUrl('x').message,
          contains('ne vient pas de Kass'),
        );
      },
    );
  });

  group('AppNetworkImage', () {
    testWidgets('une URL étrangère affiche le repli, sans chargement', (
      tester,
    ) async {
      Object? received;
      await tester.pumpWidget(
        MaterialApp(
          home: AppNetworkImage(
            imageUrl: 'https://cdn.example.org/plat.png',
            errorWidget: (_, _, error) {
              received = error;
              return const Text('repli');
            },
          ),
        ),
      );
      expect(find.text('repli'), findsOneWidget);
      expect(received, isA<ForeignImageUrl>());
    });

    testWidgets('sans repli, le repli neutre de la taille demandée', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: AppNetworkImage(
              imageUrl: 'https://cdn.example.org/plat.png',
              width: 40,
              height: 30,
            ),
          ),
        ),
      );
      expect(find.byType(AppImageFallback), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(tester.getSize(find.byType(AppImageFallback)), const Size(40, 30));
    });
  });
}
