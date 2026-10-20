import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/planning/presentation/advanced_dish_search_screen.dart';
import 'package:kass_dalle/features/planning/presentation/meal_suggestion_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

Recipe _recipe(
  String id,
  String titre, {
  List<String> ingredients = const [],
  List<String> dishTypes = const [],
  bool isPrivate = false,
}) => Recipe(
  id: id,
  titre: titre,
  langue: 'fr',
  rawCooklang: '',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: RecipeTags(dishTypes: dishTypes),
  ingredientsIndex: ingredients,
  createdBy: 'marie',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  isPrivate: isPrivate,
);

void main() {
  // Nombre de lectures des titres privés du dernier `open`.
  var titlesCalls = 0;

  Future<List<AdvancedDishPick?>> open(
    WidgetTester tester, {
    String initialQuery = '',
    bool recipesFail = false,
    int titlesFailures = 0,
  }) async {
    titlesCalls = 0;
    final results = <AdvancedDishPick?>[];
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            body: TextButton(
              onPressed: () async => results.add(
                await context.push<AdvancedDishPick>(
                  '/search',
                  extra: AdvancedDishSearchArgs(initialQuery: initialQuery),
                ),
              ),
              child: const Text('ouvrir'),
            ),
          ),
        ),
        GoRoute(
          path: '/search',
          builder: (context, state) => AdvancedDishSearchScreen(
            args: state.extra! as AdvancedDishSearchArgs,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          memberNameProvider.overrideWith((ref, uid) => 'Marie'),
          suggestablePrivateTitlesProvider.overrideWith((ref) async {
            if (titlesCalls++ < titlesFailures) {
              throw StateError('titres illisibles');
            }
            return [_recipe('p1', 'Tarte aux tomates', isPrivate: true)];
          }),
          suggestableRecipesProvider.overrideWith((ref) async {
            if (recipesFail) throw StateError('lecture impossible');
            return [
              _recipe(
                'r1',
                'Pâtes carbonara',
                ingredients: ['pâtes', 'lardons'],
              ),
              _recipe(
                'r2',
                'Gratin du soir',
                ingredients: ['tomates', 'courgettes'],
                dishTypes: ['légumes'],
              ),
            ];
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    return results;
  }

  testWidgets('« pates » trouve « Pâtes carbonara », sans accent', (
    tester,
  ) async {
    await open(tester, initialQuery: 'pates');
    expect(find.text('Pâtes carbonara'), findsOneWidget);
    expect(find.text('Gratin du soir'), findsNothing);
  });

  testWidgets('un ingrédient trouve la recette et cite la raison', (
    tester,
  ) async {
    await open(tester, initialQuery: 'tomate');
    expect(find.text('Gratin du soir'), findsOneWidget);
    expect(find.text('contient : tomates'), findsOneWidget);
    // Titre seul pour une recette privée : « Tarte aux tomates » correspond
    // par son titre.
    expect(find.text('Tarte aux tomates'), findsOneWidget);
  });

  testWidgets('toucher un résultat rend la recette', (tester) async {
    final results = await open(tester, initialQuery: 'carbonara');
    await tester.tap(find.text('Pâtes carbonara'));
    await tester.pumpAndSettle();
    expect(results.single?.recipe?.id, 'r1');
  });

  testWidgets('sans résultat : message et nom libre à garder', (tester) async {
    final results = await open(tester, initialQuery: 'zzz');
    expect(find.text('Aucune recette trouvée.'), findsOneWidget);
    await tester.tap(find.text('Garder « zzz » comme nom libre'));
    await tester.pumpAndSettle();
    expect(results.single?.freeName, 'zzz');
    expect(results.single?.recipe, isNull);
  });

  testWidgets('une erreur de lecture propose de réessayer', (tester) async {
    await open(tester, recipesFail: true);
    expect(find.text('Réessayer'), findsOneWidget);
  });

  testWidgets(
    'titres privés en erreur : la liste reste, une ligne propose de réessayer',
    (tester) async {
      await open(tester, initialQuery: 'tomate', titlesFailures: 1);
      expect(find.text('Gratin du soir'), findsOneWidget);
      expect(find.text('Tarte aux tomates'), findsNothing);
      expect(
        find.text('Titres des livres privés non chargés.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(find.text('Titres des livres privés non chargés.'), findsNothing);
      expect(find.text('Tarte aux tomates'), findsOneWidget);
    },
  );

  testWidgets('le cadenas d\'un titre privé ne répète pas le sous-titre', (
    tester,
  ) async {
    await open(tester, initialQuery: 'tarte');
    expect(find.text('Seul le titre est visible'), findsOneWidget);
    final lock = tester.widget<Icon>(find.byIcon(Icons.lock_outline));
    expect(lock.semanticLabel, isNull);
  });

  testWidgets(
    'recettes en erreur : pas de ligne des titres, « Réessayer » relance tout',
    (tester) async {
      await open(tester, recipesFail: true, titlesFailures: 1);
      expect(find.text('Titres des livres privés non chargés.'), findsNothing);
      expect(find.text('Réessayer'), findsOneWidget);
      expect(titlesCalls, 1);

      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(titlesCalls, 2);
    },
  );
}
