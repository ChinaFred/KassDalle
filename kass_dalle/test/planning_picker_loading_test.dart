import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/planning/presentation/meal_staples_providers.dart';
import 'package:kass_dalle/features/planning/presentation/picker_loading_sheet.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/side_picker_sheet.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

import 'support/test_backend.dart';

/// « Compléter » et « Choisir » ouvrent leur feuille dès l'appui, et disent
/// qu'ils lisent recettes et garnitures (#177).
class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

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
    return 'report';
  }
}

/// Un planning dont « mes recettes validées » répondent quand le test le
/// décide.
class _SlowPlanningRepository extends PlanningRepository {
  _SlowPlanningRepository(super.db, super.uid);

  final pending = <Completer<List<Recipe>>>[];

  @override
  Future<List<Recipe>> getValidatedRecipes() {
    final c = Completer<List<Recipe>>();
    pending.add(c);
    return c.future;
  }
}

const _loadingLabel = 'Lecture des recettes et des garnitures…';

Recipe _recipe(
  String id,
  String titre, {
  String? role,
  List<String>? contains,
}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: 'Cuire.',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(mealRole: role, contains: contains ?? const ['proteine']),
    ingredientsIndex: const [],
    createdBy: 'uid-test',
    createdAt: t,
    updatedAt: t,
  );
}

UserStaple _staple(String id, String name, StapleCategory category) =>
    UserStaple(
      staple: MealStaple(
        id: id,
        name: name,
        category: category,
        quantityPerPortion: 30,
      ),
      isOwn: false,
      isOverridden: false,
      hidden: false,
    );

final _staples = [
  _staple('riz', 'Riz', StapleCategory.feculent),
  _staple('haricots_verts', 'Haricots verts', StapleCategory.legume),
  _staple('comte', 'Comté', StapleCategory.fromage),
];

void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  group('feuille de chargement', () {
    late _RecordingErrorReportService reporter;

    setUp(() => reporter = _RecordingErrorReportService());

    Future<void> pumpSheet(
      WidgetTester tester, {
      required Future<List<Recipe>> Function() loadRecipes,
      required AsyncValue<List<UserStaple>> staples,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUserProvider.overrideWith((ref) => Stream.value(testUser())),
            myStaplesProvider.overrideWithValue(staples),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showModalBottomSheet<SidePickerResult>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => PickerLoadingSheet(
                      loadRecipes: loadRecipes,
                      errorReporter: reporter,
                      builder: (_, recipes, staples) => SidePickerSheet(
                        main: _recipe('main', 'Poulet rôti', role: 'plat'),
                        candidates: sideCandidatesFrom(
                          staples: staples,
                          recipes: recipes,
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Ouvrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ouvrir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('recettes en cours de lecture : le dire, puis la feuille', (
      tester,
    ) async {
      final recipes = Completer<List<Recipe>>();
      await pumpSheet(
        tester,
        loadRecipes: () => recipes.future,
        staples: AsyncValue.data(_staples),
      );
      expect(find.text(_loadingLabel), findsOneWidget);
      expect(find.byType(SidePickerSheet), findsNothing);

      recipes.complete(const []);
      await tester.pumpAndSettle();
      expect(find.text(_loadingLabel), findsNothing);
      expect(find.byType(SidePickerSheet), findsOneWidget);
      expect(find.text('Haricots verts'), findsOneWidget);
    });

    testWidgets('garnitures pas encore lues : jamais « Aucune garniture »', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        loadRecipes: () async => const [],
        staples: const AsyncValue.loading(),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_loadingLabel), findsOneWidget);
      expect(find.textContaining('Aucune garniture'), findsNothing);
      expect(find.byType(SidePickerSheet), findsNothing);
    });

    testWidgets('recettes illisibles : le titre, et « Réessayer » relance '
        'la lecture dans la feuille', (tester) async {
      var calls = 0;
      await pumpSheet(
        tester,
        loadRecipes: () async {
          calls++;
          if (calls == 1) throw StateError('réseau');
          return const [];
        },
        staples: AsyncValue.data(_staples),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Les recettes n\'ont pas pu être lues.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.byType(SidePickerSheet), findsOneWidget);
    });

    testWidgets('garnitures illisibles : le titre, signalé une fois', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        loadRecipes: () async => const [],
        staples: AsyncValue.error(StateError('réseau'), StackTrace.empty),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Vos garnitures n\'ont pas pu être lues.'),
        findsOneWidget,
      );
      expect(find.text('Réessayer'), findsOneWidget);
      expect(find.textContaining('Aucune garniture'), findsNothing);
      expect(reporter.features, ['planningScreen.pickerSheet.loadStaples']);
    });
  });

  group('planning', () {
    Future<(TestBackend, _SlowPlanningRepository)> pumpPlanning(
      WidgetTester tester, {
      required List<MealComponent> components,
      required MealKind kind,
    }) async {
      late _SlowPlanningRepository repo;
      final backend = TestBackend(
        planningWrites: true,
        planningFactory: (db, uid) => repo = _SlowPlanningRepository(db, uid),
      );
      await backend.seedRecipe(
        _recipe('main', 'Poulet rôti', role: 'plat', contains: ['proteine']),
      );
      final now = DateTime.now();
      await backend.firestore
          .collection('planned_meals')
          .doc('m1')
          .set(
            PlannedMeal(
              id: 'm1',
              uid: backend.user.uid,
              recipeId: 'main',
              recipeTitre: 'Poulet rôti',
              plannedAt: DateTime(now.year, now.month, now.day, 19),
              durationMinutes: 60,
              mealKind: kind,
              components: components,
              createdAt: now,
            ).toFirestore(),
          );
      const size = Size(420, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          retry: appProviderRetry,
          overrides: [
            ...backend.overrides,
            planningReachProvider.overrideWith(
              (ref) => Stream.value(
                const PlanningReach(uids: {}, groupIds: {}, maskedGroupIds: {}),
              ),
            ),
            myStaplesProvider.overrideWithValue(AsyncValue.data(_staples)),
          ],
          child: const MaterialApp(
            locale: Locale('fr'),
            home: PlanningScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (backend, repo);
    }

    testWidgets('« Compléter » : la feuille s\'ouvre tout de suite, dit '
        'qu\'elle lit, puis propose les garnitures', (tester) async {
      final (_, repo) = await pumpPlanning(
        tester,
        components: const [],
        kind: MealKind.plat,
      );
      await tester.tap(find.text('Compléter'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_loadingLabel), findsOneWidget);
      expect(find.textContaining('Aucune garniture'), findsNothing);

      repo.pending.single.complete(const []);
      await tester.pumpAndSettle();
      expect(find.text(_loadingLabel), findsNothing);
      expect(find.byType(SidePickerSheet), findsOneWidget);
    });

    testWidgets('« Choisir » un fromage : échec de lecture, puis '
        '« Réessayer » dans la feuille', (tester) async {
      final (_, repo) = await pumpPlanning(
        tester,
        components: [
          MealComponent.fromMap({
            'role': 'plat',
            'label': 'Poulet rôti',
            'id': 'main',
          }),
          MealComponent.fromMap({'role': 'fromage', 'label': ''}),
        ],
        kind: MealKind.menu,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Choisir'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(_loadingLabel), findsOneWidget);

      repo.pending.single.completeError(StateError('réseau'));
      await tester.pumpAndSettle();
      expect(
        find.text('Les recettes n\'ont pas pu être lues.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Réessayer'));
      await tester.pump();
      expect(repo.pending.length, 2);
      repo.pending.last.complete(const []);
      await tester.pumpAndSettle();
      expect(find.text('Comté'), findsOneWidget);
    });
  });
}
