import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/domain/book.dart';

import '../support/test_backend.dart';

/// Tests du **vrai** [BookRepository] sur un Firestore en mémoire.
void main() {
  late TestBackend backend;

  setUp(() => backend = TestBackend());

  group('watchMyBooks', () {
    test(
      'ne rend que les livres du propriétaire, du plus récent au plus ancien',
      () async {
        await backend.seedBook(
          testBook(id: 'vieux', updatedAt: DateTime.utc(2026, 1, 1)),
        );
        await backend.seedBook(
          testBook(id: 'neuf', updatedAt: DateTime.utc(2026, 7, 1)),
        );
        await backend.seedBook(
          testBook(id: 'du-cousin', createdBy: 'uid-cousin'),
        );

        final mine = await backend.books.watchMyBooks('uid-test').first;

        expect(mine.map((b) => b.id), ['neuf', 'vieux']);
      },
    );
  });

  group('watchDraftBooks', () {
    test('ne rend que les livres en brouillon', () async {
      await backend.seedBook(
        testBook(id: 'brouillon', reviewStatus: BookReviewStatus.draft),
      );
      await backend.seedBook(testBook(id: 'valide'));

      final drafts = await backend.books.watchDraftBooks('uid-test').first;

      expect(drafts.map((b) => b.id), ['brouillon']);
    });
  });

  group('watchValidatedBooksByOwners', () {
    test('écarte les brouillons et les livres privés', () async {
      await backend.seedBook(
        testBook(id: 'partageable', createdBy: 'uid-cousin'),
      );
      await backend.seedBook(
        testBook(
          id: 'brouillon-cousin',
          createdBy: 'uid-cousin',
          reviewStatus: BookReviewStatus.draft,
        ),
      );
      await backend.seedBook(
        testBook(id: 'prive-cousin', createdBy: 'uid-cousin', isPrivate: true),
      );

      final vus = await backend.books.watchValidatedBooksByOwners([
        'uid-cousin',
      ]).first;

      expect(vus.map((b) => b.id), ['partageable']);
    });

    test('une liste vide de propriétaires ne lit pas Firestore', () async {
      await backend.seedBook(testBook(id: 'peu-importe'));

      expect(
        await backend.books.watchValidatedBooksByOwners([]).first,
        isEmpty,
      );
    });
  });

  group('getBook', () {
    test('rend null pour un identifiant inconnu', () async {
      expect(await backend.books.getBook('fantome'), isNull);
    });

    test('relit fidèlement ce qui a été écrit', () async {
      await backend.seedBook(
        testBook(
          id: 'aller-retour',
          titre: 'Le Grand Livre',
          tags: ['classique'],
        ),
      );

      final book = await backend.books.getBook('aller-retour');

      expect(book, isNotNull);
      expect(book!.titre, 'Le Grand Livre');
      expect(book.tags, ['classique']);
      expect(book.reviewStatus, BookReviewStatus.validated);
      expect(book.isPrivate, isFalse);
    });
  });

  group('livres système', () {
    test('les getters de type reposent sur les tags, pas sur le titre', () {
      expect(testBook(tags: [Book.tagLibres]).isLibresBook, isTrue);
      expect(testBook(tags: [Book.tagSecretes]).isSecretesBook, isTrue);
      expect(testBook(tags: [Book.tagKassdalle]).isKassDalleBook, isTrue);
      expect(testBook(titre: 'Mes recettes libres').isLibresBook, isFalse);
    });

    test('un livre système porte une couverture par défaut', () {
      expect(
        testBook(tags: [Book.tagLibres]).defaultCoverAsset,
        'assets/opensource.png',
      );
      expect(
        testBook(tags: [Book.tagWeb]).defaultCoverAsset,
        'assets/FromTheWeb.png',
      );
      expect(testBook().defaultCoverAsset, isNull);
    });
  });
}
