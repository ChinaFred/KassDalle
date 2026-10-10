import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/data/recipe_repository.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_viewer.dart';

import '../support/test_backend.dart';

/// Tests du **vrai** [RecipeRepository], branché sur un Firestore en mémoire.
///
/// Ce qui est vérifié ici n'est vérifiable nulle part ailleurs : le couple
/// requête + filtre + tri. Une clause `where` sur le mauvais champ, un tri
/// inversé, un statut oublié ne cassent aucune compilation et ne lèvent aucune
/// erreur — ils font juste disparaître des recettes de l'écran.
void main() {
  late TestBackend backend;

  // `uid-autre` partage un groupe avec le lecteur ; `uid-etranger`, aucun.
  const lecteur = RecipeViewer(uid: 'uid-test', groupPeers: ['uid-autre']);
  const editeur = RecipeViewer(
    uid: 'uid-test',
    canEdit: true,
    groupPeers: ['uid-autre'],
  );
  const admin = RecipeViewer(uid: 'uid-admin', isAdmin: true, canEdit: true);

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

      final pages = await backend.recipes.watchByBook('book-1', lecteur).first;

      expect(pages.map((r) => r.id), ['validee']);
    });

    // Firestore refuse une requête que ses règles ne prouvent pas : hors
    // administrateur, la lecture d'un livre se scinde entre recettes
    // partagées et recettes du lecteur, fusionnées sans doublon.
    test(
      'lecteur : ses recettes et les partagées de ses groupes, rien d\'autre',
      () async {
        await backend.seedRecipe(
          testRecipe(id: 'partagee', bookId: 'book-1', createdBy: 'uid-autre'),
        );
        await backend.seedRecipe(testRecipe(id: 'a-moi', bookId: 'book-1'));
        await backend.seedRecipe(
          testRecipe(id: 'ma-privee', bookId: 'book-1', isPrivate: true),
        );
        await backend.seedRecipe(
          testRecipe(
            id: 'privee-autre',
            bookId: 'book-1',
            createdBy: 'uid-autre',
            isPrivate: true,
          ),
        );
        await backend.seedRecipe(
          testRecipe(
            id: 'hors-groupe',
            bookId: 'book-1',
            createdBy: 'uid-etranger',
          ),
        );

        final pages = await backend.recipes
            .watchByBook('book-1', lecteur)
            .first;

        expect(
          pages.map((r) => r.id),
          unorderedEquals(['partagee', 'a-moi', 'ma-privee']),
        );
      },
    );

    test('administrateur : tout le livre', () async {
      await backend.seedRecipe(
        testRecipe(
          id: 'privee-autre',
          bookId: 'book-1',
          createdBy: 'uid-autre',
          isPrivate: true,
        ),
      );
      await backend.seedRecipe(testRecipe(id: 'partagee', bookId: 'book-1'));

      final pages = await backend.recipes.watchByBook('book-1', admin).first;

      expect(
        pages.map((r) => r.id),
        unorderedEquals(['privee-autre', 'partagee']),
      );
    });
  });

  group('watchDraftsByBook', () {
    Future<void> seedDrafts() async {
      await backend.seedRecipe(
        testRecipe(
          id: 'brouillon-autre',
          bookId: 'book-1',
          createdBy: 'uid-autre',
          reviewStatus: ReviewStatus.draft,
        ),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'mon-brouillon',
          bookId: 'book-1',
          reviewStatus: ReviewStatus.draft,
        ),
      );
    }

    test('un lecteur ne voit que ses brouillons', () async {
      await seedDrafts();

      final drafts = await backend.recipes
          .watchDraftsByBook('book-1', lecteur)
          .first;

      expect(drafts.map((r) => r.id), ['mon-brouillon']);
    });

    test('un éditeur relit aussi les brouillons partagés des autres', () async {
      await seedDrafts();

      final drafts = await backend.recipes
          .watchDraftsByBook('book-1', editeur)
          .first;

      expect(
        drafts.map((r) => r.id),
        unorderedEquals(['brouillon-autre', 'mon-brouillon']),
      );
    });
  });

  // Firestore borne une requête à 30 disjonctions : au-delà de 30 comptes
  // dans les groupes (15 pour les brouillons, qui portent déjà un `in` à deux
  // valeurs), la requête partagée se découpe en lots.
  group('groupes de plus de 30 comptes', () {
    final peers = [for (var i = 0; i < 40; i++) 'uid-membre-$i'];

    test('un livre montre la recette du 40e compte', () async {
      await backend.seedRecipe(
        testRecipe(id: 'loin', bookId: 'book-1', createdBy: 'uid-membre-39'),
      );

      final pages = await backend.recipes
          .watchByBook(
            'book-1',
            RecipeViewer(uid: 'uid-test', groupPeers: peers),
          )
          .first;

      expect(pages.map((r) => r.id), ['loin']);
    });

    test('un éditeur relit le brouillon du 20e compte', () async {
      await backend.seedRecipe(
        testRecipe(
          id: 'brouillon-loin',
          bookId: 'book-1',
          createdBy: 'uid-membre-19',
          reviewStatus: ReviewStatus.inReview,
        ),
      );

      final drafts = await backend.recipes
          .watchDraftsByBook(
            'book-1',
            RecipeViewer(uid: 'uid-test', canEdit: true, groupPeers: peers),
          )
          .first;

      expect(drafts.map((r) => r.id), ['brouillon-loin']);
    });
  });

  group('countInBook', () {
    test('lecteur : les siennes et les partagées de ses groupes', () async {
      await backend.seedRecipe(testRecipe(id: 'a-moi', bookId: 'book-1'));
      await backend.seedRecipe(
        testRecipe(id: 'partagee', bookId: 'book-1', createdBy: 'uid-autre'),
      );
      await backend.seedRecipe(
        testRecipe(id: 'ma-privee', bookId: 'book-1', isPrivate: true),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'privee-autre',
          bookId: 'book-1',
          createdBy: 'uid-autre',
          isPrivate: true,
        ),
      );

      await backend.seedRecipe(
        testRecipe(
          id: 'hors-groupe',
          bookId: 'book-1',
          createdBy: 'uid-etranger',
        ),
      );

      expect(await backend.recipes.countInBook('book-1', lecteur), 3);
      expect(await backend.recipes.countInBook('book-1', admin), 5);
    });
  });

  group('deleteAllRecipesOfBook', () {
    test(
      'ne supprime que les recettes du lecteur, tout pour un admin',
      () async {
        await backend.seedRecipe(testRecipe(id: 'a-moi', bookId: 'book-1'));
        await backend.seedRecipe(
          testRecipe(id: 'autre', bookId: 'book-1', createdBy: 'uid-autre'),
        );

        await backend.recipes.deleteAllRecipesOfBook('book-1', editeur);
        expect(await backend.recipes.getById('a-moi'), isNull);
        expect(await backend.recipes.getById('autre'), isNotNull);

        await backend.recipes.deleteAllRecipesOfBook('book-1', admin);
        expect(await backend.recipes.getById('autre'), isNull);
      },
    );
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

      final pages = await backend.recipes
          .watchAllPagesByBook('book-1', lecteur)
          .first;

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

  group('updateRecipeIllustrations', () {
    // L'onglet Photos lit `thumbnail_urls[i]` pour la photo `i`. Une liste de
    // vignettes plus courte que celle des photos ne laisse pas la fin sans
    // vignette : elle décale tout. Trois recettes de la base ont fini avec
    // deux photos et une seule vignette — celle de la seconde —, et la
    // première carte affichait donc la seconde photo.
    test(
      'écarte des vignettes moins nombreuses que les photos, dont on ne sait '
      'plus à laquelle elles appartiennent',
      () async {
        await backend.seedRecipe(testRecipe(id: 'photos'));

        await backend.recipes.updateRecipeIllustrations(
          'photos',
          ['https://x/a.jpg', 'https://x/b.jpg'],
          thumbnailUrls: ['https://x/b.jpg'],
        );

        final recipe = await backend.recipes.getById('photos');

        expect(recipe!.thumbnailUrls, ['https://x/a.jpg', 'https://x/b.jpg']);
      },
    );

    test('écarte aussi les vignettes en trop', () async {
      await backend.seedRecipe(testRecipe(id: 'photos'));

      await backend.recipes.updateRecipeIllustrations(
        'photos',
        ['https://x/a.jpg'],
        thumbnailUrls: ['https://x/ta.jpg', 'https://x/tb.jpg'],
      );

      final recipe = await backend.recipes.getById('photos');

      expect(recipe!.thumbnailUrls, ['https://x/a.jpg']);
    });

    test('garde les vignettes quand elles sont aussi nombreuses', () async {
      await backend.seedRecipe(testRecipe(id: 'photos'));

      await backend.recipes.updateRecipeIllustrations(
        'photos',
        ['https://x/a.jpg', 'https://x/b.jpg'],
        thumbnailUrls: ['https://x/ta.jpg', 'https://x/tb.jpg'],
      );

      final recipe = await backend.recipes.getById('photos');

      expect(recipe!.thumbnailUrls, ['https://x/ta.jpg', 'https://x/tb.jpg']);
    });

    test('laisse les vignettes intactes quand aucune n\'est fournie', () async {
      await backend.seedRecipe(testRecipe(id: 'photos'));
      await backend.recipes.updateRecipeIllustrations(
        'photos',
        ['https://x/a.jpg'],
        thumbnailUrls: ['https://x/ta.jpg'],
      );

      await backend.recipes.updateRecipeIllustrations('photos', [
        'https://x/a.jpg',
        'https://x/b.jpg',
      ]);

      final recipe = await backend.recipes.getById('photos');

      expect(recipe!.thumbnailUrls, ['https://x/ta.jpg']);
    });
  });

  // Une recette prend la confidentialité de son livre à l'écriture : les
  // règles Firestore refusent une recette `is_private: false` dans un livre
  // privé (v0.23.8).
  group('confidentialité suivant le livre', () {
    // createRecipe, updateRecipe, validateDraft, la migration des recettes
    // libres et le planning écrivent tous `is_private` par cette fonction.
    test('privacyOfBook : la confidentialité du livre porteur', () async {
      await backend.seedBook(testBook(id: 'secret', isPrivate: true));
      await backend.seedBook(testBook(id: 'commun'));

      expect(await privacyOfBook(backend.firestore, 'secret'), isTrue);
      expect(await privacyOfBook(backend.firestore, 'commun'), isFalse);
    });

    test(
      'privacyOfBook : livre introuvable partagé, sans livre rien',
      () async {
        expect(await privacyOfBook(backend.firestore, 'inconnu'), isFalse);
        expect(await privacyOfBook(backend.firestore, null), isNull);
        expect(await privacyOfBook(backend.firestore, ''), isNull);
      },
    );

    // updateRecipe, createRecipe et la copie écrivent par withBookPrivacy :
    // une recette libre privée (page détachée d'un livre privé) le reste.
    // Le livre n'est relu qu'à un changement : l'auteur d'une page rangée
    // dans le livre privé d'un autre ne peut pas le lire.
    test('bookChanges : nul et vide valent « sans livre »', () {
      expect(bookChanges(null, ''), isFalse);
      expect(bookChanges('b1', 'b1'), isFalse);
      expect(bookChanges('b1', 'b2'), isTrue);
      expect(bookChanges(null, 'b1'), isTrue);
    });

    test('sans livre, la confidentialité écrite est celle de la recette', () {
      final data = testRecipe(id: 'libre').toFirestore()..['is_private'] = true;
      expect(withBookPrivacy(data, null)['is_private'], isTrue);
      expect(withBookPrivacy(data, false)['is_private'], isFalse);
    });
  });

  group('countOthersInBook', () {
    test('compte les pages partagées des autres, zéro pour un admin', () async {
      await backend.seedRecipe(testRecipe(id: 'a-moi', bookId: 'book-1'));
      await backend.seedRecipe(
        testRecipe(id: 'autre', bookId: 'book-1', createdBy: 'uid-autre'),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'hors-groupe',
          bookId: 'book-1',
          createdBy: 'uid-etranger',
        ),
      );

      expect(await backend.recipes.countOthersInBook('book-1', editeur), 1);
      expect(await backend.recipes.countOthersInBook('book-1', admin), 0);
    });
  });
}
