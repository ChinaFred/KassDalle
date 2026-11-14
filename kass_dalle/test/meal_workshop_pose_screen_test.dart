import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/core/utils/short_date_format.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/books/data/book_repository.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/recipes/data/recipe_repository.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/search/data/meal_workshop_draft_repository.dart';
import 'package:kass_dalle/features/search/data/meal_workshop_functions.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_freeze.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';
import 'package:kass_dalle/features/search/presentation/meal_workshop/meal_workshop_providers.dart';
import 'package:kass_dalle/features/search/presentation/meal_workshop/meal_workshop_screen.dart';

/// « Poser dans le planning » (palier 2) : le pied du panneau selon l'état,
/// la boîte sur grand écran et sur téléphone, la ligne « Planning » avec ou
/// sans groupe possédé, le jour occupé, un service sans recette, la pose
/// réussie et refusée avec un dépôt factice, et le panneau après la pose.
/// Rien ne part, rien ne s'écrit.
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
    return 'r';
  }
}

final _errors = _RecordingErrorReportService();

Recipe _recipe(
  String id,
  String titre, {
  String? book,
  int? portions,
  int? prep,
  int? cook,
}) => Recipe(
  id: id,
  titre: titre,
  bookTitre: book,
  langue: 'fr',
  rawCooklang: '>> portions: 4\nCuire.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: RecipeTags(prepTime: prep, cookTime: cook),
  ingredientsIndex: const [],
  createdBy: 'u1',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  portions: portions,
);

Map<String, dynamic> _course(
  String title, {
  String role = 'plat',
  String? recipeId,
  List<String> sides = const [],
}) => {
  'role': role,
  'title': title,
  'recipe_id': recipeId,
  'why': 'Parce que.',
  'sides': [
    for (final s in sides) {'label': s},
  ],
};

WorkshopTurnResult _turn(List<Map<String, dynamic>> courses) =>
    WorkshopTurnResult.fromJson({
      'reponse': 'Je vous propose ceci.',
      'menu': {'portions': 4, 'courses': courses},
      'control': const <String, dynamic>{},
      'turn': 1,
      'quota': {'limit': 30, 'remaining': 29},
    });

class _FakeFunctions extends MealWorkshopFunctions {
  _FakeFunctions() : super(GeminiService());
  final turns = <Object>[];
  final writes = <Object>[];

  @override
  Future<WorkshopTurnResult> turn({
    required String conversationId,
    required MealKind kind,
    required List<Map<String, String>> history,
    required String message,
    required List<Map<String, String>> recipes,
    required List<Map<String, String>> staples,
    required String globalConstraints,
    required int portions,
    required WorkshopMenu? menu,
  }) async {
    final next = turns.removeAt(0);
    if (next is WorkshopTurnResult) return next;
    throw next;
  }

  @override
  Future<Recipe> writeRecipe({
    required String conversationId,
    required String titre,
    required String? description,
    required List<String> sides,
    required int portions,
    required String globalConstraints,
  }) async {
    final next = writes.removeAt(0);
    if (next is Recipe) return next;
    throw next;
  }
}

class _FakeDrafts extends MealWorkshopDraftRepository {
  _FakeDrafts()
    : super(
        recipes: RecipeRepository(firestore: FakeFirebaseFirestore()),
        books: BookRepository(firestore: FakeFirebaseFirestore()),
        errorReportService: _errors,
      );

  final created = <String>[];

  /// Les recettes relues à la pose, par identifiant ; absente : introuvable.
  final forPose = <String, Recipe>{};

  /// Une erreur à lever à la relecture (réseau), une fois.
  Object? poseReadError;
  int poseReads = 0;

  @override
  Future<({String id, String titre})> findOrCreateBook(
    MealWorkshopBook book, {
    required String uid,
    required String displayName,
  }) async => (id: 'b', titre: book.label);

  @override
  Future<String> createDraft({
    required Recipe recipe,
    required String uid,
    required ({String id, String titre}) book,
    required int portions,
  }) async {
    created.add(recipe.titre);
    final id = 'd${created.length}';
    forPose[id] = _recipe(id, recipe.titre, portions: portions, prep: 20);
    return id;
  }

  @override
  Future<Recipe?> readLinked(String recipeId) async => switch (recipeId) {
    'r1' => _recipe('r1', 'Blanquette de veau', portions: 6),
    'r2' => _recipe('r2', 'Tarte aux poires'),
    _ => null,
  };

  @override
  Future<Recipe?> readForPose(String recipeId) async {
    poseReads++;
    final error = poseReadError;
    if (error != null) {
      poseReadError = null;
      throw error;
    }
    return forPose[recipeId] ??
        switch (recipeId) {
          'r1' => _recipe('r1', 'Blanquette de veau', portions: 6, cook: 90),
          'r2' => _recipe('r2', 'Tarte aux poires'),
          _ => null,
        };
  }
}

class _FakePlanning extends PlanningRepository {
  _FakePlanning()
    : super(FakeFirebaseFirestore(), 'u1', errorReportService: _errors);

  final added = <PlannedMeal>[];
  Object? addError;
  final savedDefaults = <String>[];

  @override
  Future<void> saveDefaultPlanningTarget(String key) async {
    savedDefaults.add(key);
  }

  final dayMeals = <PlannedMeal>[];
  int dayReads = 0;

  @override
  Future<String> addMeal(PlannedMeal meal) async {
    final error = addError;
    if (error != null) {
      addError = null;
      throw error;
    }
    added.add(meal);
    return 'm${added.length}';
  }

  @override
  Future<List<PlannedMeal>> getMealsBetween({
    required DateTime from,
    required DateTime to,
    String? groupId,
  }) async {
    dayReads++;
    return [
      for (final m in dayMeals)
        if (m.groupId == groupId &&
            !m.plannedAt.isBefore(from) &&
            m.plannedAt.isBefore(to.add(const Duration(days: 1))))
          m,
    ];
  }
}

PlannedMeal _meal(String titre, DateTime at, {String? groupId}) => PlannedMeal(
  id: titre,
  uid: 'u1',
  groupId: groupId,
  recipeTitre: titre,
  plannedAt: at,
  durationMinutes: 0,
  createdAt: at,
);

final _today = () {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}();

final _group = FamilyGroup(
  id: 'g1',
  name: 'Famille Dupont',
  ownerId: 'u1',
  memberIds: const ['u1', 'u2', 'u3'],
  createdAt: DateTime(2026, 1, 1),
);

Future<({_FakeFunctions functions, _FakeDrafts drafts, _FakePlanning planning})>
_pump(
  WidgetTester tester, {
  bool phone = false,
  List<FamilyGroup> ownedGroups = const [],
  PlanningPreferences prefs = const PlanningPreferences(),
  AppUser? user,
}) async {
  tester.view.physicalSize = phone
      ? const Size(400, 1200)
      : const Size(1100, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final functions = _FakeFunctions();
  final drafts = _FakeDrafts();
  final planning = _FakePlanning();
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const MealWorkshopScreen()),
      GoRoute(
        path: '/planning',
        builder: (_, state) =>
            Scaffold(body: Text('planning:${state.uri.query}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(user)),
        canEditProvider.overrideWithValue(user?.canEdit ?? false),
        isAdminProvider.overrideWithValue(false),
        errorReportServiceProvider.overrideWithValue(_errors),
        mealWorkshopFunctionsProvider.overrideWithValue(functions),
        mealWorkshopDraftRepositoryProvider.overrideWithValue(drafts),
        planningRepositoryProvider.overrideWithValue(planning),
        planningPreferencesProvider.overrideWith((ref) => Stream.value(prefs)),
        ownedPlanningGroupsProvider.overrideWith(
          (ref) => AsyncData(ownedGroups),
        ),
        mealWorkshopContextProvider.overrideWith(
          (ref) async => MealWorkshopContext(
            myUid: 'u1',
            displayName: 'Utilisateur',
            summaries: const [
              {'id': 'r1', 'titre': 'Blanquette de veau'},
              {'id': 'r2', 'titre': 'Tarte aux poires'},
            ],
            recipesById: {
              'r1': _recipe(
                'r1',
                'Blanquette de veau',
                book: 'Le Grand Livre',
                portions: 6,
              ),
              'r2': _recipe('r2', 'Tarte aux poires', book: 'Desserts'),
            },
            staples: const [],
            globalConstraints: '',
            defaultPortions: 4,
            quota: const WorkshopQuota(limit: 30, remaining: 30),
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (functions: functions, drafts: drafts, planning: planning);
}

Future<void> _send(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Envoyer'));
  await tester.pumpAndSettle();
}

Future<void> _freeze(WidgetTester tester) async {
  await tester.tap(find.text('Figer le repas'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Figer'));
  await tester.pumpAndSettle();
  // Le compte rendu du figement, en bas de l'écran, recouvre le pied du
  // panneau le temps de son affichage.
  await _snackGone(tester);
}

/// Attend que les messages en file soient passés : après une première pose,
/// celui du planning par défaut suit celui de la pose.
Future<void> _snackGone(WidgetTester tester) async {
  for (var i = 0; i < 3 && find.byType(SnackBar).evaluate().isNotEmpty; i++) {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }
}

Future<void> _menuMode(WidgetTester tester) async {
  await tester.tap(find.text('Menu'));
  await tester.pumpAndSettle();
}

/// Une ligne du récapitulatif : le type en gras, puis le titre et son suffixe.
Finder _recap(String type, String rest) =>
    find.text('$type  $rest', findRichText: true);

Finder get _poseButton =>
    find.widgetWithText(FilledButton, 'Poser dans le planning');

Finder get _poseConfirm => find.widgetWithText(FilledButton, 'Poser');

bool _enabled(WidgetTester tester, Finder finder) =>
    tester.widget<FilledButton>(finder).onPressed != null;

void main() {
  setUp(_errors.features.clear);

  testWidgets('avant un figement : « Figer », pas de « Poser » ; après : '
      '« Poser dans le planning » actif', (tester) async {
    final env = await _pump(tester);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'un plat de bœuf');
    expect(find.text('Figer le repas'), findsOneWidget);
    expect(_poseButton, findsNothing);

    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    expect(find.text('Figer le repas'), findsNothing);
    expect(_poseButton, findsOneWidget);
    expect(_enabled(tester, _poseButton), isTrue);
    expect(find.text('Un repas planifié a besoin d\'un plat.'), findsNothing);
  });

  testWidgets('figé sans plat : inactif, « Un repas planifié a besoin d\'un '
      'plat. »', (tester) async {
    final env = await _pump(tester);
    await _menuMode(tester);
    env.functions.turns.add(
      _turn([
        _course('Velouté', role: 'entree'),
        _course('Tarte aux poires', role: 'dessert', recipeId: 'r2'),
      ]),
    );
    await _send(tester, 'entrée et dessert');
    env.functions.writes.add(_recipe('x', 'Velouté'));
    await _freeze(tester);
    expect(_poseButton, findsOneWidget);
    expect(_enabled(tester, _poseButton), isFalse);
    expect(find.text('Un repas planifié a besoin d\'un plat.'), findsOneWidget);
  });

  testWidgets('recette plus accessible sans réponse : inactif, la raison', (
    tester,
  ) async {
    final env = await _pump(tester);
    await _menuMode(tester);
    env.functions.turns.add(
      _turn([
        _course('Velouté', role: 'entree'),
        _course('Plat perdu', recipeId: 'r9'),
      ]),
    );
    await _send(tester, 'un dîner');
    env.functions.writes.add(_recipe('x', 'Velouté'));
    await _freeze(tester);
    expect(find.text('Recette plus accessible'), findsOneWidget);
    expect(_enabled(tester, _poseButton), isFalse);
    expect(
      find.text(
        '1 recette plus accessible : rédigez à la place ou retirez-la du '
        'repas.',
      ),
      findsOneWidget,
    );
    // « Retirer du repas » retire le plat : il n'y a plus de plat.
    await tester.tap(find.text('Retirer du repas'));
    await tester.pumpAndSettle();
    expect(find.text('Un repas planifié a besoin d\'un plat.'), findsOneWidget);
  });

  testWidgets('rien à rédiger : « Poser » remplace « Figer », un appui relit '
      'puis ouvre la boîte', (tester) async {
    final env = await _pump(tester);
    env.functions.turns.add(
      _turn([_course('Blanquette de veau', recipeId: 'r1')]),
    );
    await _send(tester, 'la blanquette');
    expect(find.text('Figer le repas'), findsNothing);
    expect(_enabled(tester, _poseButton), isTrue);
    expect(
      find.text('Rien à rédiger : les recettes seront liées telles quelles.'),
      findsOneWidget,
    );

    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    // Relecture faite : « Recette liée », champ fermé, boîte ouverte.
    expect(find.text('Recette liée ·'), findsOneWidget);
    expect(find.text('Repas figé.'), findsOneWidget);
    expect(find.text('Plat · Blanquette de veau'), findsOneWidget);
    expect(
      _recap('Plat', 'Blanquette de veau · Le Grand Livre'),
      findsOneWidget,
    );
    // Recette liée pour 6, menu pour 4 : la phrase.
    expect(
      find.text(
        'Recette pour 6 : les quantités seront recalculées pour ce repas, la '
        'recette ne change pas.',
      ),
      findsOneWidget,
    );
    expect(env.drafts.poseReads, 1);
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    final meal = env.planning.added.single;
    expect(meal.recipeId, 'r1');
    expect(meal.basePortions, 6);
    expect(meal.targetPortions, 4);
    expect(meal.cookMinutes, 90);
  });

  testWidgets('la boîte, grand écran : sans groupe, pas de ligne Planning ; '
      'date, heure du jour, parts ; pose réussie, le repas et le pied', (
    tester,
  ) async {
    // L'heure du jour de semaine d'aujourd'hui : 12:15.
    final prefs = PlanningPreferences(
      dailyConstraints: {
        _today.weekday: const DayConstraint(mealHour: 12, mealMinute: 15),
      },
    );
    final env = await _pump(tester, prefs: prefs);
    await _menuMode(tester);
    env.functions.turns.add(
      _turn([
        _course('Velouté', role: 'entree'),
        _course('Bœuf bourguignon', sides: const ['Riz', 'Salade']),
        _course('Tarte aux poires', role: 'dessert', recipeId: 'r2'),
      ]),
    );
    await _send(tester, 'un dîner');
    env.functions.writes
      ..add(_recipe('x', 'Velouté'))
      ..add(_recipe('y', 'Bœuf bourguignon'));
    await _freeze(tester);

    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    expect(find.text('Poser dans le planning'), findsNWidgets(2));
    expect(find.text('Planning'), findsNothing);
    expect(find.text('Date'), findsOneWidget);
    expect(find.text(formatShortDate(_today)), findsOneWidget);
    expect(find.text('Heure de début'), findsOneWidget);
    expect(find.textContaining('12:15'), findsOneWidget);
    expect(find.text('4, parts du menu'), findsOneWidget);
    expect(find.text('Menu · 3 services'), findsOneWidget);
    expect(_recap('Entrée', 'Velouté · brouillon'), findsOneWidget);
    expect(_recap('Plat', 'Bœuf bourguignon · brouillon'), findsOneWidget);
    expect(find.text('· Riz, Salade'), findsOneWidget);
    expect(_recap('Dessert', 'Tarte aux poires · Desserts'), findsOneWidget);
    expect(find.text('Poser'), findsOneWidget);
    expect(env.planning.dayReads, 1);

    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    // La lecture du jour est rejouée avant l'écriture (P2-11).
    expect(env.planning.dayReads, 2);
    final meal = env.planning.added.single;
    expect(meal.uid, 'u1');
    expect(meal.groupId, isNull);
    expect(meal.recipeId, 'd2');
    expect(meal.recipeTitre, 'Bœuf bourguignon');
    expect(
      meal.plannedAt,
      DateTime(_today.year, _today.month, _today.day, 12, 15),
    );
    expect(meal.prepMinutes, 20);
    expect(meal.basePortions, 4);
    expect(meal.targetPortions, 4);
    expect(meal.justification, 'Parce que.');
    expect(meal.choiceSource, MealChoiceSource.workshop);
    expect(meal.mealKind, MealKind.menu);
    expect(meal.components.map((c) => c.label).toList(), [
      'Velouté',
      'Bœuf bourguignon',
      'Riz',
      'Salade',
      'Tarte aux poires',
    ]);
    expect(meal.components[0].recipeId, 'd1');
    expect(meal.components[4].recipeId, 'r2');

    // Le pied après la pose, le message, le panneau figé pour de bon.
    final posed = 'Posé le ${formatShortDay(_today)} dans Mon planning';
    expect(find.text('$posed.'), findsOneWidget);
    expect(find.text(posed), findsOneWidget);
    expect(find.text('Voir le planning'), findsOneWidget);
    expect(find.text('Poser à une autre date'), findsOneWidget);
    expect(_poseButton, findsNothing);

    // « Voir le planning » : /planning?date=AAAA-MM-JJ.
    await tester.tap(find.text('Voir le planning'));
    await tester.pumpAndSettle();
    final d = _today;
    String two(int n) => n < 10 ? '0$n' : '$n';
    expect(
      find.text('planning:date=${d.year}-${two(d.month)}-${two(d.day)}'),
      findsOneWidget,
    );
  });

  testWidgets('groupe possédé : ligne Planning, parts du jour du groupe, '
      'brouillons validés, repas de groupe, jour occupé du groupe', (
    tester,
  ) async {
    final prefs = PlanningPreferences(groupPortions: const {'g1': 7});
    final env = await _pump(tester, ownedGroups: [_group], prefs: prefs);
    env.planning.dayMeals.add(
      _meal(
        'Gratin',
        DateTime(_today.year, _today.month, _today.day, 19, 30),
        groupId: 'g1',
      ),
    );
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();

    expect(find.text('Planning'), findsOneWidget);
    expect(find.text('Mon planning'), findsOneWidget);
    // Jour personnel libre : « Poser ».
    expect(find.text('Poser'), findsOneWidget);
    expect(find.textContaining('a déjà un repas'), findsNothing);

    await tester.tap(find.byTooltip('Choisir le planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Famille Dupont').last);
    await tester.pumpAndSettle();

    expect(
      find.text('Famille Dupont cuisine d\'habitude pour 7 ce jour-là.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Les brouillons ne s\'ouvrent pour les membres qu\'une fois validés.',
      ),
      findsOneWidget,
    );
    // Le jour du groupe est occupé : la carte, « Ajouter quand même ».
    expect(
      find.text(
        '${capitalizeFirst(formatShortDay(_today))} a déjà un repas : Gratin, 19:30.',
      ),
      findsOneWidget,
    );
    expect(find.text('Choisir une autre date'), findsOneWidget);
    expect(find.text('Poser'), findsNothing);
    final confirm = find.widgetWithText(FilledButton, 'Ajouter quand même');
    expect(confirm, findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    final meal = env.planning.added.single;
    expect(meal.groupId, 'g1');
    expect(meal.uid, 'u1');
    expect(meal.targetPortions, 4);
    expect(
      find.text('Posé le ${formatShortDay(_today)} dans Famille Dupont'),
      findsOneWidget,
    );
  });

  testWidgets('groupe par défaut : la ligne Planning en part, la pose ne '
      'change pas le défaut', (tester) async {
    final prefs = PlanningPreferences(defaultPlanningTarget: 'g1');
    final env = await _pump(tester, ownedGroups: [_group], prefs: prefs);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();

    expect(find.text('Planning'), findsOneWidget);
    expect(find.text('Mon planning'), findsNothing);
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();

    expect(env.planning.added.single.groupId, 'g1');
    expect(env.planning.savedDefaults, isEmpty);
  });

  testWidgets('sans défaut : le premier planning posé devient le défaut, '
      'annoncé une fois', (tester) async {
    final env = await _pump(
      tester,
      ownedGroups: [_group],
      user: AppUser(
        uid: 'u1',
        email: 'u1@example.com',
        displayName: 'Utilisateur',
        role: UserRole.editor,
        createdAt: DateTime(2026),
        lastSeenAt: DateTime(2026),
      ),
    );
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Choisir le planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Famille Dupont').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Poser'));
    await tester.pumpAndSettle();

    expect(env.planning.added.single.groupId, 'g1');
    expect(env.planning.savedDefaults, ['g1']);
    // Le message de la pose d'abord, puis celui du défaut.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(
      find.text(
        '« Famille Dupont » sera proposé par défaut pour planifier. '
        'Modifiable dans Groupes familiaux.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('plat principal sans recette : la phrase, recipe_id nul', (
    tester,
  ) async {
    final env = await _pump(tester);
    await _menuMode(tester);
    env.functions.turns.add(
      _turn([_course('Bœuf bourguignon'), _course('Comté', role: 'fromage')]),
    );
    await _send(tester, 'un dîner');
    env.functions.writes
      ..add(WorkshopNoRecipeException())
      ..add(WorkshopNoRecipeException());
    await _freeze(tester);
    expect(
      find.text('Non rédigée. L\'IA n\'a pas rendu de recette.'),
      findsNWidgets(2),
    );
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Le plat principal n\'a pas de recette : le repas sera posé par son '
        'titre, sans courses ni nutrition. Vous pourrez le concevoir depuis '
        'le planning (« Concevoir avec l\'IA »).',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '1 plat sans recette sera posé par son titre : Comté. Vous pourrez '
        'lui choisir une recette depuis le planning (« Composer le menu »).',
      ),
      findsOneWidget,
    );
    expect(_recap('Plat', 'Bœuf bourguignon · sans recette'), findsOneWidget);
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    final meal = env.planning.added.single;
    expect(meal.recipeId, isNull);
    expect(meal.recipeTitre, 'Bœuf bourguignon');
    expect(meal.basePortions, isNull);
    // Un menu : le marqueur du plat principal, puis le fromage en texte.
    expect(meal.components, hasLength(2));
    expect(meal.components[0].isMainMarker, isTrue);
    expect(meal.components[1].isFree, isTrue);
    expect(meal.components[1].label, 'Comté');
    // Après la pose : plus de « Réessayer », « posée en texte ».
    expect(find.text('Réessayer'), findsNothing);
    expect(find.text('Non rédigée · posée en texte'), findsNWidgets(2));
    // « Nouvelle conversation » sans confirmation. Le message de la pose, en
    // bas de l'écran, recouvre la barre du champ le temps de son affichage.
    await _snackGone(tester);
    await tester.tap(find.text('Nouvelle conversation'));
    await tester.pumpAndSettle();
    expect(find.text('Nouvelle conversation ?'), findsNothing);
    expect(find.text('Pas encore de menu'), findsOneWidget);
  });

  testWidgets('pose refusée : message, boîte ouverte, rapport ; puis rôle '
      'retiré', (tester) async {
    final env = await _pump(tester);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();

    env.planning.addError = StateError('réseau');
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    // Le snack et la ligne de la boîte : sur téléphone, le snack passe sous
    // la feuille.
    expect(find.text('Repas non posé. Réessayez.'), findsNWidgets(2));
    expect(find.text('Poser'), findsOneWidget);
    expect(env.planning.added, isEmpty);
    expect(_errors.features, contains('mealWorkshop.pose'));

    // Le premier message doit avoir disparu : le second attend sinon.
    await _snackGone(tester);
    env.planning.addError = FirebaseException(
      plugin: 'cloud_firestore',
      code: 'permission-denied',
    );
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    expect(
      find.text('Repas non posé. La planification est réservée aux éditeurs.'),
      findsNWidgets(2),
    );
    expect(env.planning.added, isEmpty);

    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(find.text('Date'), findsNothing);
    expect(_enabled(tester, _poseButton), isTrue);
  });

  testWidgets('recette du plat illisible (réseau) : « Réessayer », « Poser » '
      'inactif', (tester) async {
    final env = await _pump(tester);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    env.drafts.poseReadError = StateError('réseau');
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    expect(
      find.text('La recette du plat n\'a pas pu être lue.'),
      findsOneWidget,
    );
    expect(_enabled(tester, _poseConfirm), isFalse);
    expect(_errors.features, contains('mealWorkshop.pose.readMain'));
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(find.text('La recette du plat n\'a pas pu être lue.'), findsNothing);
    expect(_enabled(tester, _poseConfirm), isTrue);
  });

  testWidgets('téléphone : depuis la feuille, la feuille se ferme, la boîte '
      's\'ouvre ; après la pose, « · posé »', (tester) async {
    final env = await _pump(tester, phone: true);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    expect(find.text('Plat en cours'), findsOneWidget);

    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    expect(find.text('Plat en cours'), findsNothing);
    expect(find.text('Poser dans le planning'), findsOneWidget);
    expect(find.text('Date'), findsOneWidget);
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    expect(env.planning.added, hasLength(1));
    // Le compte rendu du figement, retenu pendant que la feuille était
    // ouverte, est effacé par la pose : « Posé le … » s'affiche aussitôt.
    expect(
      find.text('1 brouillon créé dans « Mes créations Kass\'Dalle ✨ ».'),
      findsNothing,
    );
    expect(find.text('Date'), findsNothing);
    expect(find.textContaining(' · posé'), findsOneWidget);
    expect(
      find.text('Posé le ${formatShortDay(_today)} dans Mon planning.'),
      findsOneWidget,
    );
  });

  testWidgets('téléphone, pose refusée : le message dans la boîte, effacé au '
      'prochain appui sur « Poser »', (tester) async {
    final env = await _pump(tester, phone: true);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();

    env.planning.addError = StateError('réseau');
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    final inSheet = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text('Repas non posé. Réessayez.'),
    );
    expect(inSheet, findsOneWidget);
    final line = tester.widget<Text>(inSheet);
    expect(
      line.style?.color,
      Theme.of(tester.element(inSheet)).colorScheme.error,
    );
    expect(
      find.ancestor(
        of: inSheet,
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.liveRegion ?? false),
        ),
      ),
      findsWidgets,
    );

    await _snackGone(tester);
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    expect(env.planning.added, hasLength(1));
    expect(find.text('Repas non posé. Réessayez.'), findsNothing);
  });

  testWidgets('pose refusée : le message de la boîte s\'efface au changement '
      'de planning', (tester) async {
    final env = await _pump(tester, ownedGroups: [_group]);
    env.functions.turns.add(_turn([_course('Bœuf bourguignon')]));
    await _send(tester, 'du bœuf');
    env.functions.writes.add(_recipe('x', 'Bœuf bourguignon'));
    await _freeze(tester);
    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    env.planning.addError = StateError('réseau');
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    await _snackGone(tester);
    expect(find.text('Repas non posé. Réessayez.'), findsOneWidget);

    await tester.tap(find.byTooltip('Choisir le planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Famille Dupont').last);
    await tester.pumpAndSettle();
    expect(find.text('Repas non posé. Réessayez.'), findsNothing);
  });

  testWidgets('rien à rédiger, recette liée illisible : aucun compte rendu, '
      'puis « Rédiger à la place » dans « Mes créations Kass\'Dalle ✨ »', (
    tester,
  ) async {
    final env = await _pump(tester);
    env.functions.turns.add(_turn([_course('Plat perdu', recipeId: 'r9')]));
    await _send(tester, 'le plat perdu');
    expect(_enabled(tester, _poseButton), isTrue);

    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    // Le figement implicite n'annonce rien : ni « Repas figé : 0 recette
    // liée. », ni la boîte.
    expect(find.textContaining('Repas figé :'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Date'), findsNothing);
    expect(find.text('Recette plus accessible'), findsOneWidget);
    expect(_enabled(tester, _poseButton), isFalse);
    expect(
      find.text(
        '1 recette plus accessible : rédigez à la place ou retirez-la du '
        'repas.',
      ),
      findsOneWidget,
    );

    env.functions.writes.add(_recipe('x', 'Plat perdu'));
    await tester.tap(find.text('Rédiger à la place'));
    await tester.pumpAndSettle();
    expect(env.drafts.created, ['Plat perdu']);
    expect(
      find.text('1 brouillon créé dans « Mes créations Kass\'Dalle ✨ ».'),
      findsOneWidget,
    );
    expect(_enabled(tester, _poseButton), isTrue);
  });

  testWidgets('après une pose : l\'écran se quitte librement, même après un '
      'figement partiel', (tester) async {
    final env = await _pump(tester);
    await _menuMode(tester);
    env.functions.turns.add(
      _turn([_course('Bœuf bourguignon'), _course('Comté', role: 'fromage')]),
    );
    await _send(tester, 'un dîner');
    env.functions.writes
      ..add(_recipe('x', 'Bœuf bourguignon'))
      ..add(const WorkshopNoRecipeException());
    await _freeze(tester);
    PopScope<dynamic> guard() => tester.widget<PopScope<dynamic>>(
      find.byWidgetPredicate((w) => w is PopScope).first,
    );
    // Figement partiel, pas encore posé : la question.
    expect(guard().canPop, isFalse);

    await tester.tap(_poseButton);
    await tester.pumpAndSettle();
    await tester.tap(_poseConfirm);
    await tester.pumpAndSettle();
    expect(env.planning.added, hasLength(1));
    expect(guard().canPop, isTrue);
  });
}
