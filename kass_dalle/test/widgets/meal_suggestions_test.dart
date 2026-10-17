import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/meal_suggestion.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/presentation/meal_suggestion_providers.dart';
import 'package:kass_dalle/features/planning/presentation/meal_suggestions_window.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/suggest_meal_screen.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

import '../support/test_backend.dart';

/// Suggestions de repas, vues de l'écran du planning : le membre suggère et
/// retire, le propriétaire lit le repère et la fenêtre.
void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  FamilyGroup dupont({String owner = 'marie'}) => FamilyGroup(
    id: 'gd',
    name: 'Famille Dupont',
    ownerId: owner,
    memberIds: {owner, 'uid-test', 'marie'}.toList(),
    createdAt: DateTime.utc(2026),
  );

  Future<TestBackend> pump(
    WidgetTester tester, {
    required UserRole role,
    required FamilyGroup group,
    List<Map<String, dynamic>> suggestions = const [],
    List<Recipe> recipes = const [],
    List<PlannedMeal> mine = const [],
  }) async {
    final backend = TestBackend(
      user: testUser(role: role),
      groups: [group],
      plannedMeals: mine,
    );
    for (final s in suggestions) {
      await backend.firestore.collection('meal_suggestions').add(s);
    }
    const size = Size(400, 900);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        retry: appProviderRetry,
        overrides: [
          ...backend.overrides,
          planningReachProvider.overrideWith(
            (ref) => Stream.value(
              const PlanningReach(groupIds: {'gd'}, maskedGroupIds: {}),
            ),
          ),
          groupPlannedMealsProvider.overrideWith(
            (ref, key) => Stream.value(const []),
          ),
          memberNameProvider.overrideWith(
            (ref, uid) => uid == 'marie' ? 'Marie' : 'Léo',
          ),
          suggestableRecipesProvider.overrideWith((ref) async => recipes),
        ],
        child: MaterialApp.router(
          locale: const Locale('fr'),
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: '/',
                builder: (context, state) => const PlanningScreen(),
              ),
              GoRoute(
                path: '/planning/suggest',
                builder: (context, state) =>
                    SuggestMealScreen(args: state.extra! as SuggestMealArgs),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return backend;
  }

  Map<String, dynamic> lasagnes({
    String author = 'uid-test',
    String owner = 'marie',
  }) => {
    'group_id': 'gd',
    'group_owner_id': owner,
    'author_uid': author,
    'day': mealSuggestionDayKey(today),
    'recipe_id': 'r1',
    'recipe_titre': 'Lasagnes',
    'note': 'Pour l\'anniversaire de Léo',
    'created_at': Timestamp.fromDate(today),
  };

  testWidgets('le membre lecteur suggère un plat sur un jour à venir', (
    tester,
  ) async {
    await pump(tester, role: UserRole.reader, group: dupont());

    expect(tester.takeException(), isNull);
    expect(find.text('Suggérer un plat'), findsWidgets);
    expect(find.byTooltip('Mes suggestions'), findsOneWidget);
    expect(find.byTooltip('Suggestions des membres'), findsNothing);
  });

  testWidgets('l\'écran envoie une recette privée, et prévient', (
    tester,
  ) async {
    final backend = await pump(
      tester,
      role: UserRole.reader,
      group: dupont(),
      recipes: [testRecipe(id: 'r1', titre: 'Lasagnes', isPrivate: true)],
    );

    await tester.tap(find.text('Suggérer un plat').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Famille Dupont · '), findsOneWidget);
    final send = find.widgetWithText(FilledButton, 'Envoyer la suggestion');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);

    await tester.enterText(find.byType(TextField).first, 'Lasa');
    await tester.pump();
    await tester.tap(find.text('Lasagnes'));
    await tester.pumpAndSettle();
    expect(
      find.text('Recette privée : Marie ne verra que son titre.'),
      findsOneWidget,
    );
    expect(find.text('Un mot pour Marie (facultatif)'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Pour Léo');
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(find.text('Suggestion envoyée à Marie.'), findsOneWidget);
    final docs = await backend.firestore.collection('meal_suggestions').get();
    final doc = docs.docs.single;
    expect(doc.id, startsWith('gd_uid-test_'));
    expect(doc.id, endsWith('_0'));
    final data = doc.data();
    expect(data['recipe_id'], 'r1');
    expect(data['recipe_titre'], 'Lasagnes');
    expect(data['group_owner_id'], 'marie');
    expect(data['author_uid'], 'uid-test');
    expect(data['note'], 'Pour Léo');
  });

  testWidgets('l\'auteur voit sa suggestion et la retire', (tester) async {
    final backend = await pump(
      tester,
      role: UserRole.reader,
      group: dupont(),
      suggestions: [lasagnes()],
    );

    expect(find.text('Votre suggestion : Lasagnes'), findsOneWidget);
    await tester.ensureVisible(find.byTooltip('Retirer ma suggestion'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Retirer ma suggestion'));
    await tester.pumpAndSettle();
    expect(find.text('Suggestion retirée.'), findsOneWidget);
    final docs = await backend.firestore.collection('meal_suggestions').get();
    expect(docs.docs, isEmpty);
  });

  testWidgets('le propriétaire lit le repère, le badge et la fenêtre', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.editor,
      group: dupont(owner: 'uid-test'),
      suggestions: [lasagnes(author: 'marie', owner: 'uid-test')],
      // Un repas à soi : sans aucun repas, l'éditeur lit l'état vide du
      // planning, pas la liste des jours.
      mine: [
        PlannedMeal(
          id: 'own',
          uid: 'uid-test',
          recipeTitre: 'Gratin',
          plannedAt: today.add(const Duration(hours: 19)),
          durationMinutes: 30,
          createdAt: today,
        ),
      ],
    );

    expect(find.byTooltip('Suggestions des membres'), findsOneWidget);
    expect(find.text('1 suggestion'), findsOneWidget);
    // Pas de « Suggérer un plat » dans son propre groupe.
    expect(find.text('Suggérer un plat'), findsNothing);

    await tester.ensureVisible(find.text('1 suggestion'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 suggestion'));
    await tester.pumpAndSettle();
    expect(find.text('Lasagnes'), findsOneWidget);
    expect(find.textContaining('Proposé par Marie'), findsOneWidget);
    expect(find.text('« Pour l\'anniversaire de Léo »'), findsOneWidget);
    expect(find.text('Rien de prévu ce jour-là'), findsOneWidget);
    expect(find.text('Planifier ce jour-là'), findsOneWidget);
    // Aucun jour passé : « Voir les plus anciennes » vient directement.
    expect(find.textContaining('Jours passés'), findsNothing);
    expect(find.text('Voir les plus anciennes'), findsOneWidget);
    await tester.tap(find.text('Voir les plus anciennes'));
    await tester.pumpAndSettle();
    expect(find.text('Aucune suggestion plus ancienne.'), findsOneWidget);
  });

  testWidgets('« Mes suggestions » retire, et le dit dans la fenêtre', (
    tester,
  ) async {
    final backend = await pump(
      tester,
      role: UserRole.reader,
      group: dupont(),
      suggestions: [lasagnes()],
    );

    await tester.tap(find.byTooltip('Mes suggestions'));
    await tester.pumpAndSettle();
    final window = find.byType(MealSuggestionsView);
    expect(
      find.descendant(of: window, matching: find.text('Lasagnes')),
      findsOneWidget,
    );
    await tester.tap(
      find.descendant(
        of: window,
        matching: find.byTooltip('Retirer ma suggestion'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: window, matching: find.text('Suggestion retirée.')),
      findsOneWidget,
    );
    final docs = await backend.firestore.collection('meal_suggestions').get();
    expect(docs.docs, isEmpty);
  });

  testWidgets('le propriétaire sans suggestion lit l\'état vide', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.editor,
      group: dupont(owner: 'uid-test'),
    );

    await tester.tap(find.byTooltip('Suggestions des membres'));
    await tester.pumpAndSettle();
    expect(find.text('Aucune suggestion pour l\'instant.'), findsOneWidget);
  });
}
