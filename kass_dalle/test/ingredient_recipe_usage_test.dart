import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:kass_dalle/core/services/cooklang_parser.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/data/ingredient_usage_repository.dart';
import 'package:kass_dalle/features/admin/data/nutrition_ingredients_repository.dart';
import 'package:kass_dalle/features/admin/domain/ingredient_recipe_usage.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/admin/presentation/nutrition_ingredients_screen.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

import 'support/test_backend.dart';

class _RecordingErrorReportService extends ErrorReportService {
  final List<String> features = [];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'test';
  }
}

/// Un Firestore dont tout accès échoue.
class _BrokenFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Firestore injoignable');
}

/// Le vrai repository sur un Firestore en mémoire, qui compte ses lectures
/// et peut échouer ou rester en attente.
class _CountingRepository extends IngredientUsageRepository {
  int calls = 0;
  bool fail = false;
  Completer<void>? gate;

  _CountingRepository(FakeFirebaseFirestore firestore)
    : super(
        firestore: firestore,
        errorReportService: _RecordingErrorReportService(),
      );

  @override
  Future<IngredientRecipeUsage> fetchRecipesUsing(List<String> values) async {
    calls++;
    final pending = gate;
    if (pending != null) await pending.future;
    if (fail) {
      // Erreur transitoire : `AppErrorState` ne propose « Réessayer » que
      // pour une erreur que réessayer peut corriger.
      throw FirebaseException(plugin: 'cloud_firestore', code: 'unavailable');
    }
    return super.fetchRecipesUsing(values);
  }
}

Map<String, dynamic> _recipe(
  String titre,
  List<String> index, {
  String? book,
  bool isPrivate = false,
  String status = 'validated',
}) => {
  'titre': titre,
  'ingredients_index': index,
  'book_titre': ?book,
  'is_private': isPrivate,
  'review_status': status,
};

const _papier = NutritionIngredientDoc(
  id: 'papier_sulfurise',
  source: 'admin',
  qualityStatus: 'verified',
  per100g: {},
  canonicalName: 'papier sulfurisé',
  aliases: ['Papier sulfurisé ', 'feuille de papier cuisson'],
);

void main() {
  group('ingredientUsageSearchValues', () {
    test('papier_sulfurise produit « papier sulfurisé », comme l\'index', () {
      final values = ingredientUsageSearchValues(
        id: 'papier_sulfurise',
        canonicalName: 'papier sulfurisé',
        aliases: const ['Papier sulfurisé ', 'feuille de papier cuisson'],
      );
      expect(values, [
        'papier sulfurisé',
        'papier sulfurise',
        'feuille de papier cuisson',
      ]);
      // Même valeur que celle écrite dans `ingredients_index` d'une recette
      // qui cite l'ingrédient sous son nom écrit.
      final index = buildIngredientsIndex(const [
        RecipeIngredient(name: ' Papier sulfurisé', qty: '1', unit: 'feuille'),
      ]);
      expect(values, contains(index.single));
    });

    test('sans nom canonique ni alias : l\'identifiant lu comme un nom', () {
      expect(ingredientUsageSearchValues(id: 'huile_olive'), ['huile olive']);
    });

    test('au plus 30 valeurs, canonique et identifiant gardés', () {
      final values = ingredientUsageSearchValues(
        id: 'sel',
        canonicalName: 'sel fin',
        aliases: [for (var i = 0; i < 40; i++) 'sel $i'],
      );
      expect(values, hasLength(kIngredientUsageMaxValues));
      expect(values.take(2), ['sel fin', 'sel']);
    });

    test('valeurs vides écartées', () {
      expect(
        ingredientUsageSearchValues(
          id: 'oeuf',
          canonicalName: '  ',
          aliases: const [''],
        ),
        ['oeuf'],
      );
    });
  });

  group('NutritionIngredientDoc', () {
    test('lit canonical_name et aliases', () {
      final doc = NutritionIngredientDoc.fromFirestore('papier_sulfurise', {
        'canonical_name': 'papier sulfurisé',
        'aliases': ['papier sulfurisé', 3, 'papier cuisson'],
      });
      expect(doc.canonicalName, 'papier sulfurisé');
      expect(doc.aliases, ['papier sulfurisé', 'papier cuisson']);
    });

    test('champs absents ou mal formés', () {
      final doc = NutritionIngredientDoc.fromFirestore('sel', {
        'canonical_name': 12,
        'aliases': 'sel',
      });
      expect(doc.canonicalName, isNull);
      expect(doc.aliases, isEmpty);
    });
  });

  group('IngredientRecipeRef.fromFirestore', () {
    test('document mal formé : une ligne lisible', () {
      final ref = IngredientRecipeRef.fromFirestore('r1', {
        'titre': 4,
        'book_titre': '',
        'is_private': 'oui',
      });
      expect(ref.title, 'Sans titre');
      expect(ref.bookTitle, isNull);
      expect(ref.isPrivate, isFalse);
      expect(ref.isDraft, isTrue);
    });
  });

  group('IngredientUsageRepository', () {
    late FakeFirebaseFirestore firestore;
    late _RecordingErrorReportService errors;
    late IngredientUsageRepository repo;

    setUp(() {
      firestore = FakeFirebaseFirestore();
      errors = _RecordingErrorReportService();
      repo = IngredientUsageRepository(
        firestore: firestore,
        errorReportService: errors,
      );
    });

    test(
      'trouve les recettes par l\'une des valeurs, privées comprises',
      () async {
        await firestore
            .collection('recipes')
            .doc('a')
            .set(
              _recipe('Tarte', ['papier sulfurisé', 'farine'], book: 'Mamie'),
            );
        await firestore
            .collection('recipes')
            .doc('b')
            .set(
              _recipe('Cake', ['feuille de papier cuisson'], isPrivate: true),
            );
        await firestore
            .collection('recipes')
            .doc('c')
            .set(_recipe('Soupe', ['poireau']));

        final usage = await repo.fetchRecipesUsing(const [
          'papier sulfurisé',
          'feuille de papier cuisson',
        ]);
        expect(usage.recipes.map((r) => r.id).toSet(), {'a', 'b'});
        expect(usage.hasMore, isFalse);
        final cake = usage.recipes.firstWhere((r) => r.id == 'b');
        expect(cake.isPrivate, isTrue);
      },
    );

    test('21 recettes : 20 rendues, et la suite signalée', () async {
      for (var i = 0; i < 25; i++) {
        await firestore
            .collection('recipes')
            .doc('r$i')
            .set(_recipe('Recette $i', ['sel']));
      }
      final usage = await repo.fetchRecipesUsing(const ['sel']);
      expect(usage.recipes, hasLength(kIngredientUsageDisplayLimit));
      expect(usage.hasMore, isTrue);
    });

    test('aucune valeur : aucune lecture', () async {
      final usage = await IngredientUsageRepository(
        firestore: _BrokenFirestore(),
        errorReportService: errors,
      ).fetchRecipesUsing(const []);
      expect(usage.recipes, isEmpty);
      expect(errors.features, isEmpty);
    });

    test('échec : signalé au rapport d\'erreurs, puis relancé', () async {
      final broken = IngredientUsageRepository(
        firestore: _BrokenFirestore(),
        errorReportService: errors,
      );
      await expectLater(
        broken.fetchRecipesUsing(const ['sel']),
        throwsA(isA<StateError>()),
      );
      expect(errors.features, ['ingredientUsage.fetchRecipesUsing']);
    });
  });

  group('NutritionIngredientsScreen — Recettes qui l\'utilisent', () {
    late FakeFirebaseFirestore firestore;
    late _CountingRepository repo;
    late List<String> visited;

    setUp(() {
      firestore = FakeFirebaseFirestore();
      repo = _CountingRepository(firestore);
      visited = [];
    });

    Future<void> pumpScreen(WidgetTester tester) async {
      final router = GoRouter(
        initialLocation: '/admin/nutrition-ingredients',
        routes: [
          GoRoute(
            path: '/admin/nutrition-ingredients',
            builder: (_, _) => const NutritionIngredientsScreen(),
          ),
          GoRoute(
            path: '/drafts/:id',
            builder: (_, state) {
              visited.add(state.uri.path);
              return const Text('relecture');
            },
          ),
          GoRoute(
            path: '/recipes/:id',
            builder: (_, state) {
              visited.add(state.uri.path);
              return const Text('fiche');
            },
            routes: [
              GoRoute(
                path: 'edit',
                builder: (_, state) {
                  visited.add(state.uri.path);
                  return const Text('éditeur');
                },
              ),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          retry: (_, _) => null,
          overrides: [
            appUserProvider.overrideWith(
              (ref) => Stream.value(testUser(role: UserRole.admin)),
            ),
            allNutritionIngredientsProvider.overrideWith(
              (ref) => Stream.value(const [_papier]),
            ),
            ingredientUsageRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> toggle(WidgetTester tester) async {
      await tester.tap(find.text('papier_sulfurise'));
      await tester.pumpAndSettle();
    }

    testWidgets('aucune lecture tant que la fiche est repliée', (tester) async {
      await pumpScreen(tester);
      expect(repo.calls, 0);
      expect(find.textContaining('Recettes qui l\'utilisent'), findsNothing);
    });

    testWidgets('chargement, puis liste avec compteur et sous-titres', (
      tester,
    ) async {
      await firestore
          .collection('recipes')
          .doc('a')
          .set(_recipe('Tarte', ['papier sulfurisé'], book: 'Livre de Mamie'));
      await firestore
          .collection('recipes')
          .doc('b')
          .set(
            _recipe(
              'Cake',
              ['feuille de papier cuisson'],
              book: 'Carnet',
              isPrivate: true,
            ),
          );
      await firestore
          .collection('recipes')
          .doc('c')
          .set(
            _recipe('Brouillon de pain', ['papier sulfurise'], status: 'draft'),
          );
      repo.gate = Completer<void>();
      await pumpScreen(tester);

      await tester.tap(find.text('papier_sulfurise'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Recettes qui l\'utilisent'), findsOneWidget);

      repo.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Recettes qui l\'utilisent (3)'), findsOneWidget);
      expect(find.text('Livre de Mamie'), findsOneWidget);
      expect(find.text('Privée · Carnet'), findsOneWidget);
      expect(find.text('Brouillon'), findsOneWidget);
      // Le crayon est masqué pour le brouillon seul.
      expect(find.byTooltip('Ouvrir dans l\'éditeur'), findsNWidgets(2));
      final pencil = tester.getSize(
        find.ancestor(
          of: find.byTooltip('Ouvrir dans l\'éditeur').first,
          matching: find.byType(IconButton),
        ),
      );
      expect(pencil.width, greaterThanOrEqualTo(48));
      expect(pencil.height, greaterThanOrEqualTo(48));
      expect(repo.calls, 1);
    });

    testWidgets('aucune recette', (tester) async {
      await pumpScreen(tester);
      await toggle(tester);
      expect(find.text('Recettes qui l\'utilisent (0)'), findsOneWidget);
      expect(
        find.text('Aucune recette n\'utilise cet ingrédient.'),
        findsOneWidget,
      );
    });

    testWidgets('plus de 20 : « (20+) » et la ligne d\'explication', (
      tester,
    ) async {
      for (var i = 0; i < 21; i++) {
        await firestore
            .collection('recipes')
            .doc('r$i')
            .set(_recipe('Recette $i', ['papier sulfurisé']));
      }
      await pumpScreen(tester);
      await toggle(tester);
      expect(find.text('Recettes qui l\'utilisent (20+)'), findsOneWidget);
      expect(find.text('20 premières recettes affichées.'), findsOneWidget);
      expect(find.byIcon(Icons.restaurant_menu_outlined), findsNWidgets(20));
    });

    testWidgets('erreur, puis Réessayer relit', (tester) async {
      repo.fail = true;
      await pumpScreen(tester);
      await toggle(tester);
      expect(find.text('Impossible de charger les recettes.'), findsOneWidget);
      expect(repo.calls, 1);

      repo.fail = false;
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(repo.calls, 2);
      expect(
        find.text('Aucune recette n\'utilise cet ingrédient.'),
        findsOneWidget,
      );
    });

    testWidgets('replier puis déplier relit', (tester) async {
      await pumpScreen(tester);
      await toggle(tester);
      expect(repo.calls, 1);
      await toggle(tester);
      await toggle(tester);
      expect(repo.calls, 2);
    });

    testWidgets('la ligne ouvre la fiche, le crayon l\'éditeur', (
      tester,
    ) async {
      await firestore
          .collection('recipes')
          .doc('tarte')
          .set(_recipe('Tarte', ['papier sulfurisé']));
      await pumpScreen(tester);
      await toggle(tester);

      await tester.tap(find.text('Tarte'));
      await tester.pumpAndSettle();
      expect(visited.last, '/recipes/tarte');
      // `push` : l'écran du référentiel reste dessous.
      final router = GoRouter.of(tester.element(find.text('fiche')));
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Ouvrir dans l\'éditeur'));
      await tester.pumpAndSettle();
      expect(visited.last, '/recipes/tarte/edit');
      final editorRouter = GoRouter.of(tester.element(find.text('éditeur')));
      expect(editorRouter.canPop(), isTrue);
      // Au retour, la liste est relue.
      final before = repo.calls;
      editorRouter.pop();
      await tester.pumpAndSettle();
      expect(repo.calls, before + 1);
      expect(find.text('Tarte'), findsOneWidget);
    });

    testWidgets('un brouillon s\'ouvre dans sa relecture, sans crayon', (
      tester,
    ) async {
      await firestore
          .collection('recipes')
          .doc('pain')
          .set(_recipe('Pain', ['papier sulfurisé'], status: 'inReview'));
      await pumpScreen(tester);
      await toggle(tester);
      expect(find.byTooltip('Ouvrir dans l\'éditeur'), findsNothing);

      await tester.tap(find.text('Pain'));
      await tester.pumpAndSettle();
      expect(visited.last, '/drafts/pain');
      expect(find.text('relecture'), findsOneWidget);

      final before = repo.calls;
      GoRouter.of(tester.element(find.text('relecture'))).pop();
      await tester.pumpAndSettle();
      expect(repo.calls, before + 1);
    });
  });
}
