import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/data/book_repository.dart';
import 'package:kass_dalle/features/books/domain/book.dart';

/// Les livres système : renommables, jamais supprimables.
///
/// Ce sont les destinations par défaut — « Mes recettes libres » pour ce qui
/// n'a pas de livre, « Mes créations Kass'Dalle » pour ce que l'IA invente.
/// Les perdre ne perd pas qu'un livre : la règle « toute recette a un livre »
/// n'aurait plus où se poser, et les recettes qu'ils portent seraient
/// orphelines.
///
/// La garde vivait dans un menu, qui masquait « Supprimer ». Un menu n'est pas
/// une règle : il est à un appel de distance d'être contourné.
void main() {
  late FakeFirebaseFirestore db;
  late BookRepository repo;

  setUp(() {
    db = FakeFirebaseFirestore();
    repo = BookRepository(firestore: db);
  });

  Future<String> addBook({
    required String titre,
    List<String> tags = const [],
  }) {
    final now = DateTime(2026, 8, 19);
    return repo.createBook(
      Book(
        id: '',
        titre: titre,
        auteur: 'Kassbi',
        langue: 'fr',
        tags: tags,
        createdBy: 'uid',
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  group('deleteBook', () {
    test('un livre ordinaire se supprime', () async {
      final id = await addBook(titre: 'Terroir belge');
      await repo.deleteBook(id);
      expect((await db.collection('books').doc(id).get()).exists, isFalse);
    });

    for (final tag in [Book.tagLibres, Book.tagKassdalle, Book.tagSecretes]) {
      test('un livre système ($tag) refuse la suppression', () async {
        final id = await addBook(titre: 'Système', tags: [tag]);
        await expectLater(repo.deleteBook(id), throwsA(isA<StateError>()));
        // Et il est toujours là : le refus n'est pas qu'un message.
        expect((await db.collection('books').doc(id).get()).exists, isTrue);
      });
    }

    test('un livre déjà absent ne fait pas échouer la suppression', () async {
      // Supprimer deux fois de suite ne doit pas lever : le document n'est plus
      // là, l'intention est satisfaite.
      await repo.deleteBook('inexistant');
    });
  });

  group('isSystemBook', () {
    test('reconnaît un livre à son tag, quel que soit son titre', () {
      final now = DateTime(2026, 8, 19);
      // Le titre est renommable : c'est le tag interne qui fait foi. Un livre
      // renommé « Mes trucs » reste le livre des recettes libres.
      final renamed = Book(
        id: 'b1',
        titre: 'Mes trucs à moi',
        auteur: 'Kassbi',
        langue: 'fr',
        tags: const [Book.tagLibres],
        createdBy: 'uid',
        createdAt: now,
        updatedAt: now,
      );
      expect(renamed.isLibresBook, isTrue);
      expect(renamed.isSystemBook, isTrue);
    });

    test('un livre sans tag interne n\'est pas un livre système', () {
      final now = DateTime(2026, 8, 19);
      final ordinary = Book(
        id: 'b2',
        titre: 'Mes recettes libres',
        auteur: 'Kassbi',
        langue: 'fr',
        tags: const ['Pâtisserie'],
        createdBy: 'uid',
        createdAt: now,
        updatedAt: now,
      );
      expect(ordinary.isSystemBook, isFalse);
    });
  });
}
