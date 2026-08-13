import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

import '../support/test_backend.dart';

/// Tests du **vrai** [RecipeRepository], branché sur un Firestore en mémoire.
///
/// Ce qui est vérifié ici n'est vérifiable nulle part ailleurs : le couple
/// requête + filtre + tri. Une clause `where` sur le mauvais champ, un tri
/// inversé, un statut oublié ne cassent aucune compilation et ne lèvent aucune
/// erreur — ils font juste disparaître des recettes de l'écran.
void main() {
  late TestBackend backend;

  setUp(() => backend = TestBackend());

  group('watchDrafts', () {
    test('ne retient que les brouillons de l\'utilisateur demandé', () async {
      await backend.seedRecipe(
        testRecipe(id: 'mine-draft', reviewStatus: ReviewStatus.draft),
      );
      await backend.seedRecipe(
        testRecipe(id: 'mine-review', reviewStatus: ReviewStatus.inReview),
      );
      await backend.seedRecipe(
        testRecipe(id: 'mine-validated', reviewStatus: ReviewStatus.validated),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'other-draft',
          createdBy: 'uid-autre',
          reviewStatus: ReviewStatus.draft,
        ),
      );

      final drafts = await backend.recipes.watchDrafts('uid-test').first;

      expect(
        drafts.map((r) => r.id),
        unorderedEquals(['mine-draft', 'mine-review']),
      );
    });

    test('trie du plus récemment modifié au plus ancien', () async {
      await backend.seedRecipe(
        testRecipe(
          id: 'ancien',
          reviewStatus: ReviewStatus.draft,
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'recent',
          reviewStatus: ReviewStatus.draft,
          updatedAt: DateTime.utc(2026, 7, 1),
        ),
      );

      final drafts = await backend.recipes.watchDrafts('uid-test').first;

      expect(drafts.map((r) => r.id), ['recent', 'ancien']);
    });
  });

  group('watchByBook', () {
    test('ne remonte que les pages validées du livre demandé', () async {
      await backend.seedRecipe(testRecipe(id: 'validee', bookId: 'book-1'));
      await backend.seedRecipe(
        testRecipe(
          id: 'brouillon',
          bookId: 'book-1',
          reviewStatus: ReviewStatus.draft,
        ),
      );
      await backend.seedRecipe(testRecipe(id: 'autre-livre', bookId: 'book-2'));

      final pages = await backend.recipes.watchByBook('book-1').first;

      expect(pages.map((r) => r.id), ['validee']);
    });
  });

  group('watchAllPagesByBook', () {
    test('classe par numéro de page, les pages sans numéro à la fin', () async {
      await backend.seedRecipe(
        testRecipe(id: 'p10', bookId: 'book-1', pageNumber: 10),
      );
      await backend.seedRecipe(
        testRecipe(id: 'p2', bookId: 'book-1', pageNumber: 2),
      );
      await backend.seedRecipe(
        testRecipe(id: 'sans-numero', bookId: 'book-1', titre: 'Zeste'),
      );

      final pages = await backend.recipes.watchAllPagesByBook('book-1').first;

      expect(pages.map((r) => r.id), ['p2', 'p10', 'sans-numero']);
    });
  });

  group('watchUnattached', () {
    test('exclut ce qui appartient à un livre', () async {
      await backend.seedRecipe(testRecipe(id: 'libre'));
      await backend.seedRecipe(testRecipe(id: 'dans-livre', bookId: 'book-1'));

      final libres = await backend.recipes.watchUnattached('uid-test').first;

      expect(libres.map((r) => r.id), ['libre']);
    });
  });

  group('watchUnattachedByOwners', () {
    test('ne remonte que le validé et libre des propriétaires cités', () async {
      await backend.seedRecipe(
        testRecipe(id: 'cousin-libre', createdBy: 'uid-cousin'),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'cousin-brouillon',
          createdBy: 'uid-cousin',
          reviewStatus: ReviewStatus.draft,
        ),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'cousin-dans-livre',
          createdBy: 'uid-cousin',
          bookId: 'book-1',
        ),
      );
      await backend.seedRecipe(testRecipe(id: 'la-mienne'));

      final vues = await backend.recipes.watchUnattachedByOwners([
        'uid-cousin',
      ]).first;

      expect(vues.map((r) => r.id), ['cousin-libre']);
    });

    test('une liste vide de propriétaires ne lit pas Firestore', () async {
      await backend.seedRecipe(testRecipe(id: 'peu-importe'));

      final vues = await backend.recipes.watchUnattachedByOwners([]).first;

      expect(vues, isEmpty);
    });
  });

  group('getById', () {
    test('rend null pour un identifiant inconnu', () async {
      expect(await backend.recipes.getById('fantome'), isNull);
    });

    test('relit fidèlement ce qui a été écrit', () async {
      await backend.seedRecipe(
        testRecipe(
          id: 'aller-retour',
          titre: 'Poulet basquaise',
          bookId: 'book-1',
          pageNumber: 42,
        ),
      );

      final recipe = await backend.recipes.getById('aller-retour');

      expect(recipe, isNotNull);
      expect(recipe!.titre, 'Poulet basquaise');
      expect(recipe.bookId, 'book-1');
      expect(recipe.pageNumber, 42);
      expect(recipe.reviewStatus, ReviewStatus.validated);
      // Un aller-retour Firestore conserve l'instant, pas sa représentation :
      // `Timestamp.toDate()` rend une date **locale**. Comparer les DateTime
      // bruts ferait échouer le test partout sauf sur un serveur en UTC.
      expect(recipe.updatedAt.isUtc, isFalse);
      expect(recipe.updatedAt.toUtc(), DateTime.utc(2026, 6, 1));
    });
  });

  group('watchRecipe', () {
    test('émet la mise à jour quand le document change', () async {
      await backend.seedRecipe(testRecipe(id: 'suivie', titre: 'Avant'));

      // Une seule souscription, deux émissions attendues : c'est le contrat
      // d'un flux temps réel. Rappeler `.first` rouvrirait un flux neuf et ne
      // testerait rien.
      final titres = backend.recipes.watchRecipe('suivie').map((r) => r?.titre);
      final future = expectLater(titres, emitsInOrder(['Avant', 'Après']));

      await backend.seedRecipe(testRecipe(id: 'suivie', titre: 'Après'));
      await future;
    });
  });
}
