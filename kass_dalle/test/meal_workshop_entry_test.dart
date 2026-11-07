import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/core/services/gemini_providers.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/search/domain/search_models.dart';
import 'package:kass_dalle/features/search/presentation/search_providers.dart';
import 'package:kass_dalle/features/search/presentation/search_screen.dart';

/// « Composer un repas avec l'IA » dans Explorer : visible de l'éditeur sur
/// grand écran (menu « Créer avec l'IA ») et sur téléphone (« Aller plus loin »),
/// absente pour le lecteur, et l'adresse ouverte porte le texte du champ.
class _FakeService extends GeminiService {
  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);
}

final _corpus = ExploreCorpus(
  myUid: 'moi',
  recipes: [
    Recipe(
      id: 'r1',
      titre: 'Gratin',
      langue: 'fr',
      rawCooklang: '',
      imageUrls: const [],
      reviewStatus: ReviewStatus.validated,
      tags: const RecipeTags(),
      ingredientsIndex: const [],
      createdBy: 'moi',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  ],
);

const _label = 'Composer un repas avec l\'IA';

Future<void> _pump(
  WidgetTester tester, {
  bool canEdit = true,
  bool phone = false,
}) async {
  tester.view.physicalSize = phone
      ? const Size(400, 1600)
      : const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SearchScreen()),
      GoRoute(
        path: AppRoutes.mealWorkshop,
        builder: (_, state) => Scaffold(
          body: Text(
            'atelier:${state.uri.queryParameters[kMealWorkshopQueryParam] ?? ''}',
          ),
        ),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        canEditProvider.overrideWithValue(canEdit),
        exploreCorpusProvider.overrideWith((ref, params) async => _corpus),
        myRatingProvider.overrideWith((ref, id) => Stream.value(null)),
        geminiServiceProvider.overrideWithValue(_FakeService()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('grand écran', () {
    // Dans le menu « Créer avec l'IA », sans « avec l'IA » : le menu le dit.
    const wideLabel = 'Composer un repas';

    Future<void> openCreateMenu(WidgetTester tester) async {
      await tester.tap(find.text('Créer avec l\'IA'));
      await tester.pumpAndSettle();
    }

    testWidgets('éditeur : dans « Créer avec l\'IA », après « Imaginer »', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text(wideLabel), findsNothing);
      await openCreateMenu(tester);
      expect(find.text(wideLabel), findsOneWidget);
      expect(find.text(_label), findsNothing);
      expect(find.byIcon(Icons.restaurant_menu), findsOneWidget);
      final imagine = tester.getTopLeft(find.text('Imaginer 3 recettes'));
      final workshop = tester.getTopLeft(find.text(wideLabel));
      expect(workshop.dy, greaterThan(imagine.dy));
    });

    testWidgets('lecteur : ni menu ni icône', (tester) async {
      await _pump(tester, canEdit: false);
      expect(find.text('Créer avec l\'IA'), findsNothing);
      expect(find.text(wideLabel), findsNothing);
      expect(find.byIcon(Icons.restaurant_menu), findsNothing);
    });

    testWidgets('le texte du champ part dans l\'adresse, non envoyé', (
      tester,
    ) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'bar rôti pour 4');
      await tester.pumpAndSettle();
      await openCreateMenu(tester);
      await tester.tap(find.text(wideLabel));
      await tester.pumpAndSettle();
      expect(find.text('atelier:bar rôti pour 4'), findsOneWidget);
    });

    testWidgets('toujours actif, même sans texte', (tester) async {
      await _pump(tester);
      await openCreateMenu(tester);
      await tester.tap(find.text(wideLabel));
      await tester.pumpAndSettle();
      expect(find.text('atelier:'), findsOneWidget);
    });
  });

  group('téléphone', () {
    testWidgets('éditeur : deuxième ligne d\'« Aller plus loin »', (
      tester,
    ) async {
      await _pump(tester, phone: true);
      expect(find.text(_label), findsNothing);
      await tester.tap(find.text('Aller plus loin'));
      await tester.pumpAndSettle();
      expect(find.text(_label), findsOneWidget);
      expect(
        find.text(
          'Discutez d\'un plat ou d\'un menu complet. Les plats retenus '
          'deviennent des brouillons à relire.',
        ),
        findsOneWidget,
      );
      final imagine = tester.getTopLeft(find.text('Imaginer 3 recettes'));
      final workshop = tester.getTopLeft(find.text(_label));
      final web = tester.getTopLeft(find.text('Chercher sur le web'));
      expect(workshop.dy, greaterThan(imagine.dy));
      expect(web.dy, greaterThan(workshop.dy));
      await tester.tap(find.text(_label));
      await tester.pumpAndSettle();
      expect(find.text('atelier:'), findsOneWidget);
    });

    testWidgets('lecteur : pas de feuille, pas de ligne', (tester) async {
      await _pump(tester, canEdit: false, phone: true);
      expect(find.text('Aller plus loin'), findsNothing);
      expect(find.text(_label), findsNothing);
    });
  });

  test('l\'adresse encode le texte, et reste nue sans texte', () {
    expect(mealWorkshopLocation('  '), '/search/meal-workshop');
    expect(
      mealWorkshopLocation('bar rôti & riz'),
      '/search/meal-workshop?q=bar+r%C3%B4ti+%26+riz',
    );
  });
}
