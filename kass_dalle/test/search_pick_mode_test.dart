import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_providers.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/core/widgets/readable_width.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_filter.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/search/domain/search_models.dart';
import 'package:kass_dalle/features/search/presentation/search_providers.dart';
import 'package:kass_dalle/features/search/presentation/search_screen.dart';

/// L'Explorer en mode choix : ouvert depuis une suggestion du planning, il
/// rend la recette touchée au lieu d'ouvrir la fiche.
class _FakeService extends GeminiService {
  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);
}

Recipe _recipe(String id, String titre, ReviewStatus status) => Recipe(
  id: id,
  titre: titre,
  langue: 'fr',
  rawCooklang: '',
  imageUrls: const [],
  reviewStatus: status,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'moi',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

final _corpus = ExploreCorpus(
  myUid: 'moi',
  recipes: [
    _recipe('l1', 'Lasagnes', ReviewStatus.validated),
    _recipe('l2', 'Lasagnes brouillon', ReviewStatus.draft),
    _recipe('g1', 'Gratin', ReviewStatus.validated),
  ],
);

Future<ProviderContainer> _open(
  WidgetTester tester,
  ValueChanged<ExploreChoice?> onResult,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        canEditProvider.overrideWithValue(true),
        exploreCorpusProvider.overrideWith((ref, params) async => _corpus),
        myRatingProvider.overrideWith((ref, id) => Stream.value(null)),
        geminiServiceProvider.overrideWithValue(_FakeService()),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  final choice = await Navigator.of(context)
                      .push<ExploreChoice>(
                        MaterialPageRoute(
                          builder: (_) => const SearchScreen(
                            pick: ExplorePick(
                              initialQuery: 'Lasagnes',
                              banner: 'Recette pour lundi 5 janvier, Dupont',
                            ),
                          ),
                        ),
                      );
                  onResult(choice);
                },
                child: const Text('ouvrir'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(SearchScreen)));
}

void main() {
  testWidgets('champ pré-rempli, bandeau, recherche déjà lancée', (
    tester,
  ) async {
    await _open(tester, (_) {});
    expect(find.text('Recette pour lundi 5 janvier, Dupont'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Lasagnes'), findsOneWidget);
    expect(find.text('Gratin'), findsNothing);
    expect(find.text('Lasagnes brouillon'), findsOneWidget);
  });

  testWidgets('une recette validée est rendue avec sa recette', (tester) async {
    ExploreChoice? result;
    await _open(tester, (c) => result = c);
    await tester.tap(find.text('Lasagnes').last);
    await tester.pumpAndSettle();
    expect(find.byType(SearchScreen), findsNothing);
    expect(result?.title, 'Lasagnes');
    expect(result?.recipe?.id, 'l1');
  });

  testWidgets('un brouillon de la bibliothèque est rendu en texte libre', (
    tester,
  ) async {
    ExploreChoice? result;
    await _open(tester, (c) => result = c);
    await tester.tap(find.text('Lasagnes brouillon'));
    await tester.pumpAndSettle();
    expect(result?.title, 'Lasagnes brouillon');
    expect(result?.recipe, isNull);
  });

  testWidgets('les filtres du mode choix ne touchent pas la préférence', (
    tester,
  ) async {
    final container = await _open(tester, (_) {});
    final pick = container.read(explorePickPreferencesProvider.notifier);
    pick.apply(ExplorePreferences.defaults.copyWith(sort: RecipeSort.title));
    expect(
      container.read(explorePickPreferencesProvider).value?.sort,
      RecipeSort.title,
    );
    // La préférence enregistrée n'est ni lue ni modifiée.
    expect(container.exists(explorePreferencesProvider), isFalse);
  });

  testWidgets('sur un écran de 2 000 px, la liste reste bornée à 1 200 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _open(tester, (_) {});
    // La barre garde toute la largeur ; le contenu est borné par
    // `ReadableWidth`, que le shell ne pose pas sur une page poussée.
    expect(tester.getSize(find.byType(AppBar)).width, 2000);
    final content = find
        .descendant(
          of: find.byType(ReadableWidth),
          matching: find.byType(MediaQuery),
        )
        .first;
    expect(tester.getSize(content).width, kReadableMaxWidth);
    expect(
      tester.getSize(find.text('Lasagnes brouillon')).width,
      lessThanOrEqualTo(kReadableMaxWidth),
    );
    expect(
      tester.getTopLeft(find.text('Recette pour lundi 5 janvier, Dupont')).dx,
      greaterThanOrEqualTo((2000 - kReadableMaxWidth) / 2),
    );
  });
}
