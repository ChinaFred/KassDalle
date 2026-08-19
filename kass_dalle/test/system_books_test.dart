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

  group('migrateLibresRecipes', () {
    Future<void> addRecipe(String id, Map<String, dynamic> data) => db
        .collection('recipes')
        .doc(id)
        .set({'created_by': 'uid', 'titre': 'Recette $id', ...data});

    test('rattache les recettes sans livre, et rend leur nombre', () async {
      await addRecipe('r1', {'book_id': null});
      await addRecipe('r2', {'book_id': null});
      await addRecipe('r3', {'book_id': 'autre-livre'});

      final moved = await repo.migrateLibresRecipes('uid', 'libres', 'Libres');

      expect(moved, 2);
      for (final id in ['r1', 'r2']) {
        final data = (await db.collection('recipes').doc(id).get()).data()!;
        expect(data['book_id'], 'libres');
        expect(data['book_titre'], 'Libres');
      }
      // Une recette déjà rangée ne bouge pas.
      final r3 = (await db.collection('recipes').doc('r3').get()).data()!;
      expect(r3['book_id'], 'autre-livre');
    });

    test('un book_id VIDE compte aussi comme absent', () async {
      // Une chaîne vide n'est pas `null` pour Firestore : ces recettes
      // échappaient à la requête et restaient orphelines pour toujours, tout en
      // s'affichant exactement comme les autres.
      await addRecipe('r4', {'book_id': ''});

      final moved = await repo.migrateLibresRecipes('uid', 'libres', 'Libres');

      expect(moved, 1);
      final data = (await db.collection('recipes').doc('r4').get()).data()!;
      expect(data['book_id'], 'libres');
    });

    test('les recettes d\'un autre compte ne sont pas touchées', () async {
      await db.collection('recipes').doc('r5').set({
        'created_by': 'quelqu-un-d-autre',
        'titre': 'Pas la mienne',
        'book_id': null,
      });

      final moved = await repo.migrateLibresRecipes('uid', 'libres', 'Libres');

      expect(moved, 0);
      final data = (await db.collection('recipes').doc('r5').get()).data()!;
      expect(data['book_id'], isNull);
    });

    test('sans orpheline, l\'opération rend zéro sans rien écrire', () async {
      await addRecipe('r6', {'book_id': 'un-livre'});
      expect(await repo.migrateLibresRecipes('uid', 'libres', 'Libres'), 0);
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
