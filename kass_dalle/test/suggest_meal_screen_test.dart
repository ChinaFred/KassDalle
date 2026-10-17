import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/data/meal_suggestion_repository.dart';
import 'package:kass_dalle/features/planning/domain/meal_suggestion.dart';
import 'package:kass_dalle/features/planning/presentation/meal_suggestion_providers.dart';
import 'package:kass_dalle/features/planning/presentation/suggest_meal_screen.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

class _FakeRepo implements MealSuggestionRepository {
  final drafts = <MealSuggestionDraft>[];
  Object? failWith;

  @override
  Future<String> suggest(MealSuggestionDraft draft, String authorUid) async {
    if (failWith != null) throw failWith!;
    drafts.add(draft);
    return 'id';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Recipe _recipe(String id, String titre, {bool isPrivate = false}) => Recipe(
  id: id,
  titre: titre,
  langue: 'fr',
  rawCooklang: '',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'marie',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  isPrivate: isPrivate,
);

final _family = FamilyGroup(
  id: 'gd',
  name: 'Famille Dupont',
  ownerId: 'marie',
  memberIds: const ['marie', 'leo'],
  createdAt: DateTime(2026, 1, 1),
);

final _user = AppUser(
  uid: 'leo',
  email: 'leo@example.com',
  displayName: 'Léo',
  role: UserRole.reader,
  createdAt: DateTime(2026, 1, 1),
  lastSeenAt: DateTime(2026, 1, 1),
);

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  Future<_FakeRepo> open(
    WidgetTester tester, {
    Recipe? recipe,
    bool recipesFail = false,
    List<Recipe>? recipes,
  }) async {
    final repo = _FakeRepo();
    final day = DateTime(2026, 10, 20);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mealSuggestionRepositoryProvider.overrideWithValue(repo),
          appUserProvider.overrideWith((ref) => Stream.value(_user)),
          memberNameProvider.overrideWith((ref, uid) => 'Marie'),
          suggestableRecipesProvider.overrideWith((ref) async {
            if (recipesFail) throw StateError('lecture impossible');
            return recipes ??
                [_recipe('r1', 'Lasagnes'), _recipe('r2', 'Frites maison')];
          }),
        ],
        child: MaterialApp(
          // L'application garde `appUserProvider` ouvert (routeur) ; ici, c'est
          // ce `Consumer` qui l'écoute.
          home: Consumer(
            builder: (context, ref, child) {
              ref.watch(appUserProvider);
              return child!;
            },
            child: SuggestMealScreen(
              args: SuggestMealArgs(
                groups: [_family],
                group: recipe == null ? _family : null,
                day: recipe == null ? day : null,
                recipe: recipe,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  FilledButton sendButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Envoyer la suggestion'),
  );

  testWidgets('vide : bouton inactif et phrase qui dit pourquoi', (
    tester,
  ) async {
    await open(tester);
    expect(sendButton(tester).onPressed, isNull);
    expect(
      find.text('Tapez un plat ou choisissez une recette.'),
      findsOneWidget,
    );
    expect(find.text('Famille Dupont · mardi 20 octobre'), findsOneWidget);
  });

  testWidgets('un nom libre suffit à envoyer, sans recette', (tester) async {
    final repo = await open(tester);
    await tester.enterText(find.byType(TextField).first, 'des frites');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNotNull);
    expect(find.text('Utiliser « des frites »'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(FilledButton, 'Envoyer la suggestion'),
    );
    await tester.pumpAndSettle();
    expect(repo.drafts, hasLength(1));
    expect(repo.drafts.single.recipeId, isNull);
    expect(repo.drafts.single.title, 'des frites');
  });

  testWidgets('une recette de la liste remplace le nom libre', (tester) async {
    final repo = await open(tester);
    await tester.enterText(find.byType(TextField).first, 'frites');
    await tester.pump();
    await tester.tap(find.text('Frites maison'));
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Envoyer la suggestion'),
    );
    await tester.pumpAndSettle();
    expect(repo.drafts.single.recipeId, 'r2');
    expect(repo.drafts.single.title, 'Frites maison');
  });

  testWidgets('retoucher le texte d\'une recette choisie la rend libre', (
    tester,
  ) async {
    final repo = await open(tester, recipe: _recipe('r1', 'Lasagnes'));
    // Depuis une fiche recette : groupe unique, jour à choisir.
    expect(find.text('Jour'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Lasagnes végé');
    await tester.pump();
    expect(find.text('Utiliser « Lasagnes végé »'), findsOneWidget);
    expect(repo.drafts, isEmpty);
    expect(
      find.text('Choisissez un jour.'),
      findsOneWidget,
      reason: 'le jour manque : la phrase le dit',
    );
  });

  testWidgets('nom trop long : message et bouton inactif', (tester) async {
    await open(tester);
    await tester.enterText(
      find.byType(TextField).first,
      'x' * (kSuggestionFreeTitleMax + 1),
    );
    await tester.pump();
    expect(sendButton(tester).onPressed, isNull);
    expect(
      find.text(
        'Le nom ne doit pas dépasser $kSuggestionFreeTitleMax caractères.',
      ),
      findsWidgets,
    );
  });

  testWidgets('recettes illisibles : le nom libre reste utilisable', (
    tester,
  ) async {
    await open(tester, recipesFail: true);
    expect(
      find.text(
        'Les recettes n\'ont pas pu être lues. Un nom libre reste possible.',
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField).first, 'des frites');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('quota atteint : message, saisie conservée', (tester) async {
    final repo = await open(tester);
    repo.failWith = const SuggestionLimitReached();
    await tester.enterText(find.byType(TextField).first, 'des frites');
    await tester.pump();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Envoyer la suggestion'),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Vous avez déjà fait $kSuggestionsPerAuthorPerDay suggestions pour ce '
        'jour.',
      ),
      findsWidgets,
    );
    expect(find.text('des frites'), findsOneWidget);
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('quitter avec une saisie demande confirmation', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, 'des frites');
    await tester.pump();
    final popped = await tester.binding.handlePopRoute();
    expect(popped, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Abandonner la suggestion ?'), findsOneWidget);
    await tester.tap(find.text('Rester'));
    await tester.pumpAndSettle();
    expect(find.text('Abandonner la suggestion ?'), findsNothing);
    expect(find.text('des frites'), findsOneWidget);
  });
}
