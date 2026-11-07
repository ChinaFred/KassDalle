import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/books/data/book_repository.dart';
import 'package:kass_dalle/features/recipes/data/recipe_repository.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/search/data/meal_workshop_draft_repository.dart';
import 'package:kass_dalle/features/search/data/meal_workshop_functions.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_freeze.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';
import 'package:kass_dalle/features/search/presentation/meal_workshop/meal_workshop_providers.dart';
import 'package:kass_dalle/features/search/presentation/meal_workshop/meal_workshop_screen.dart';

/// L'atelier repas, grand écran : un tour, le panneau, « Figer le repas »
/// actif ou non avec sa raison, la boîte de figement, le figement complet,
/// partiel, et le doublon de titre lié. Les appels sont simulés : rien ne
/// part, rien ne s'écrit.
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

Recipe _recipe(String id, String titre, {String? book, int? portions}) =>
    Recipe(
      id: id,
      titre: titre,
      bookTitre: book,
      langue: 'fr',
      rawCooklang: '>> portions: 4\nCuire.',
      imageUrls: const [],
      reviewStatus: ReviewStatus.validated,
      tags: const RecipeTags(),
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

WorkshopTurnResult _turnResult(
  List<Map<String, dynamic>> courses, {
  int turn = 1,
  int remaining = 29,
}) => WorkshopTurnResult.fromJson({
  'reponse': 'Je vous propose ceci.',
  'menu': {'portions': 4, 'courses': courses},
  'control': const <String, dynamic>{},
  'turn': turn,
  'quota': {'limit': 30, 'remaining': remaining},
});

class _FakeFunctions extends MealWorkshopFunctions {
  _FakeFunctions() : super(GeminiService());

  /// Ce que rend chaque tour, dans l'ordre : une réponse, ou une erreur.
  final turns = <Object>[];
  final turnKinds = <MealKind>[];

  /// Ce que rend chaque rédaction, dans l'ordre : une recette, ou une erreur.
  final writes = <Object>[];
  final written = <String>[];

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
    turnKinds.add(kind);
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
    written.add(titre);
    final next = writes.removeAt(0);
    if (next is Recipe) return next;
    throw next;
  }
}

class _FakeDrafts extends MealWorkshopDraftRepository {
  _FakeDrafts()
    : super(
        recipes: RecipeRepository(firestore: FakeFirebaseFirestore()),
        // Le livre par défaut exigerait l'App Firebase : un Firestore en
        // mémoire à la place, jamais lu puisque `findOrCreateBook` est simulé.
        books: BookRepository(firestore: FakeFirebaseFirestore()),
        errorReportService: _errors,
      );

  final created = <String>[];
  final books = <MealWorkshopBook>[];

  @override
  Future<({String id, String titre})> findOrCreateBook(
    MealWorkshopBook book, {
    required String uid,
    required String displayName,
  }) async {
    books.add(book);
    return (id: 'b-${book.name}', titre: book.label);
  }

  @override
  Future<String> createDraft({
    required Recipe recipe,
    required String uid,
    required ({String id, String titre}) book,
    required int portions,
  }) async {
    created.add(recipe.titre);
    return 'd${created.length}';
  }

  @override
  Future<Recipe?> readLinked(String recipeId) async => switch (recipeId) {
    'r1' => _recipe('r1', 'Blanquette de veau'),
    'r2' => _recipe('r2', 'Tarte aux poires'),
    _ => null,
  };
}

final _errors = _RecordingErrorReportService();

Future<({_FakeFunctions functions, _FakeDrafts drafts})> _pump(
  WidgetTester tester, {
  WorkshopQuota? quota = const WorkshopQuota(limit: 30, remaining: 30),
  String initialMessage = '',
  bool phone = false,
}) async {
  tester.view.physicalSize = phone
      ? const Size(400, 1200)
      : const Size(1100, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final functions = _FakeFunctions();
  final drafts = _FakeDrafts();
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => MealWorkshopScreen(initialMessage: initialMessage),
      ),
      GoRoute(
        path: '/drafts/:id',
        builder: (_, state) =>
            Scaffold(body: Text('brouillon:${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        isAdminProvider.overrideWithValue(false),
        errorReportServiceProvider.overrideWithValue(_errors),
        mealWorkshopFunctionsProvider.overrideWithValue(functions),
        mealWorkshopDraftRepositoryProvider.overrideWithValue(drafts),
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
            quota: quota,
          ),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return (functions: functions, drafts: drafts);
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
}

void main() {
  setUp(_errors.features.clear);

  testWidgets('ouverture : périmètre, compteur du jour, rien à figer', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('Périmètre : 2 recettes · 0 garniture'), findsOneWidget);
    expect(find.text('Dites ce que vous voulez manger'), findsOneWidget);
    expect(find.text('Plat en cours'), findsOneWidget);
    expect(find.text('Pas encore de plat'), findsOneWidget);
    expect(
      find.text(
        'Périmètre : 2 recettes · 20 tours au plus par conversation · Il vous '
        'reste 30 tours aujourd\'hui.',
      ),
      findsOneWidget,
    );
    final freeze = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Figer le repas'),
    );
    expect(freeze.onPressed, isNull);
    expect(find.text('Pas encore de plat.'), findsOneWidget);
    // Rien ne part tout seul.
    final send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('un tour : bulles, panneau, compteur, « Figer » actif', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      _turnResult([
        _course('Bar rôti', sides: const ['riz', 'carottes glacées']),
      ]),
    );
    await _send(tester, 'un plat de poisson');
    expect(fakes.functions.turnKinds, [MealKind.plat]);
    expect(find.text('un plat de poisson'), findsOneWidget);
    expect(find.text('Je vous propose ceci.'), findsOneWidget);
    expect(find.text('Plat mis à jour'), findsOneWidget);
    expect(find.text('Bar rôti'), findsOneWidget);
    expect(find.text('À rédiger'), findsOneWidget);
    expect(find.text('Modifié'), findsOneWidget);
    expect(find.text('riz'), findsOneWidget);
    expect(
      find.text('Tour 1 sur 20 · Il vous reste 29 tours aujourd\'hui.'),
      findsOneWidget,
    );
    expect(find.text('1 plat à rédiger · 0 recette liée'), findsOneWidget);
    final freeze = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Figer le repas'),
    );
    expect(freeze.onPressed, isNotNull);
    expect(find.text('Nouvelle conversation'), findsOneWidget);
  });

  testWidgets('recettes liées seules : « Poser dans le planning » prend la '
      'place de « Figer », la raison', (tester) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      _turnResult([_course('Blanquette de veau', recipeId: 'r1')]),
    );
    await _send(tester, 'la blanquette');
    expect(
      find.text('Le Grand Livre · recette pour 6, repas pour 4'),
      findsOneWidget,
    );
    // Palier 2 (v0.24.78) : rien à rédiger, « Poser » relit les recettes
    // liées puis ouvre la boîte (`meal_workshop_pose_screen_test.dart`).
    expect(find.text('Figer le repas'), findsNothing);
    final pose = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Poser dans le planning'),
    );
    expect(pose.onPressed, isNotNull);
    expect(
      find.text('Rien à rédiger : les recettes seront liées telles quelles.'),
      findsOneWidget,
    );
  });

  testWidgets('figer : la boîte, puis un brouillon créé et le champ fermé', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      _turnResult([
        _course('Bar rôti', sides: const ['riz', 'carottes glacées']),
      ]),
    );
    fakes.functions.writes.add(_recipe('', 'Bar rôti'));
    await _send(tester, 'un plat de poisson');

    await tester.tap(find.text('Figer le repas'));
    await tester.pumpAndSettle();
    expect(find.text('Figer le repas'), findsNWidgets(2));
    expect(
      find.text('1 plat sera rédigé par l\'IA, pour 4 parts : un appel.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Accompagnements cités dans la recette du plat, sans recette à part : '
        'riz, carottes glacées.',
      ),
      findsOneWidget,
    );
    expect(find.text('Livre des brouillons'), findsOneWidget);
    expect(find.text('Mes créations Kass\'Dalle ✨'), findsOneWidget);
    expect(find.text('Mes recettes libres'), findsOneWidget);
    expect(find.text('Titres déjà dans votre bibliothèque'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Figer'));
    await tester.pumpAndSettle();

    expect(fakes.functions.written, ['Bar rôti']);
    expect(fakes.drafts.books, [MealWorkshopBook.kassDalle]);
    expect(fakes.drafts.created, ['Bar rôti']);
    expect(find.text('Brouillon créé ·'), findsOneWidget);
    expect(find.text('Ouvrir'), findsOneWidget);
    expect(find.text('1 brouillon créé · 0 recette liée'), findsOneWidget);
    expect(
      find.text('1 brouillon créé dans « Mes créations Kass\'Dalle ✨ ».'),
      findsOneWidget,
    );
    expect(find.text('Repas figé.'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Figer le repas'), findsNothing);
    expect(_errors.features, isEmpty);

    await tester.tap(find.text('Ouvrir'));
    await tester.pumpAndSettle();
    expect(find.text('brouillon:d1'), findsOneWidget);
  });

  testWidgets('figer : plafond d\'IA au second plat, le premier reste', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      _turnResult([
        _course('Velouté', role: 'entree'),
        _course('Bar rôti'),
        _course('Mousse', role: 'dessert'),
      ]),
    );
    fakes.functions.writes
      ..add(_recipe('', 'Velouté'))
      ..add(
        GeminiCallableException(
          'resource-exhausted',
          'Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui.',
          {'scope': 'ai_budget', 'reason': 'cost'},
        ),
      );
    await _send(tester, 'un dîner');
    await _freeze(tester);

    // Le troisième plat n'est pas tenté.
    expect(fakes.functions.written, ['Velouté', 'Bar rôti']);
    expect(fakes.drafts.created, ['Velouté']);
    expect(find.text('Brouillon créé ·'), findsOneWidget);
    expect(find.text('Non rédigée — plafond atteint'), findsNWidgets(2));
    expect(find.text('Réessayer'), findsNothing);
    expect(
      find.text(
        'Recette non rédigée. Limite d\'utilisation de l\'IA atteinte pour '
        'aujourd\'hui.',
      ),
      findsOneWidget,
    );
    expect(find.text('1 brouillon créé · 0 recette liée'), findsOneWidget);
    expect(find.text('Repas figé.'), findsOneWidget);
    expect(_errors.features, ['mealWorkshop.freeze.write']);
  });

  testWidgets('figer : un échec réseau se rejoue, la ligne seule', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(_turnResult([_course('Bar rôti')]));
    fakes.functions.writes
      ..add(GeminiCallableException('unavailable', 'down', null))
      ..add(_recipe('', 'Bar rôti'));
    await _send(tester, 'un plat de poisson');
    await _freeze(tester);

    expect(find.text('Non rédigée —'), findsOneWidget);
    expect(find.text('1 plat non rédigé. 0 brouillon créé.'), findsOneWidget);
    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(fakes.functions.written, ['Bar rôti', 'Bar rôti']);
    expect(find.text('Brouillon créé ·'), findsOneWidget);
    expect(fakes.drafts.created, ['Bar rôti']);
  });

  testWidgets('doublon de titre : « Figer » attend la décision, lier ne '
      'rédige pas', (tester) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      _turnResult([_course('blanquette de veau'), _course('Bar rôti')]),
    );
    fakes.functions.writes.add(_recipe('', 'Bar rôti'));
    await _send(tester, 'deux plats');

    await tester.tap(find.text('Figer le repas'));
    await tester.pumpAndSettle();
    expect(find.text('Titres déjà dans votre bibliothèque'), findsOneWidget);
    expect(
      find.text('« Blanquette de veau » existe dans Le Grand Livre'),
      findsOneWidget,
    );
    expect(find.text('Choisissez pour chaque doublon.'), findsOneWidget);
    var figer = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Figer'),
    );
    expect(figer.onPressed, isNull);
    expect(
      find.text(
        '2 plats seront rédigés par l\'IA, pour 4 parts : un appel '
        'chacun.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Lier la recette existante'));
    await tester.pumpAndSettle();
    expect(find.text('Choisissez pour chaque doublon.'), findsNothing);
    // La phrase recompte : un plat de moins à rédiger, une recette liée.
    expect(
      find.text(
        '1 plat sera rédigé par l\'IA, pour 4 parts : un appel. 1 recette '
        'existante reste liée telle quelle, avec ses propres parts.',
      ),
      findsOneWidget,
    );
    figer = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Figer'),
    );
    expect(figer.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Figer'));
    await tester.pumpAndSettle();

    expect(fakes.functions.written, ['Bar rôti']);
    expect(find.text('Recette liée ·'), findsOneWidget);
    expect(find.text('Brouillon créé ·'), findsOneWidget);
    expect(find.text('1 brouillon créé · 1 recette liée'), findsOneWidget);
    expect(find.text('Blanquette de veau'), findsOneWidget);
  });

  testWidgets('tous les doublons liés : ni appel, ni livre, repas figé', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      _turnResult([
        _course('blanquette de veau'),
        _course('tarte aux poires', role: 'dessert'),
      ]),
    );
    await _send(tester, 'un plat et un dessert');

    await tester.tap(find.text('Figer le repas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lier la recette existante').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lier la recette existante').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Aucun plat ne sera rédigé : 2 recettes existantes seront liées.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Figer'));
    await tester.pumpAndSettle();

    expect(fakes.functions.written, isEmpty);
    expect(fakes.drafts.books, isEmpty);
    expect(fakes.drafts.created, isEmpty);
    expect(find.text('Recette liée ·'), findsNWidgets(2));
    expect(find.text('2 recettes liées'), findsOneWidget);
    expect(find.text('Repas figé : 2 recettes liées.'), findsOneWidget);
    expect(find.text('Repas figé.'), findsOneWidget);
    expect(_errors.features, isEmpty);
  });

  testWidgets('téléphone : figer depuis la feuille, le snack attend sa '
      'fermeture', (tester) async {
    final fakes = await _pump(tester, phone: true);
    fakes.functions.turns.add(_turnResult([_course('Bar rôti')]));
    fakes.functions.writes.add(_recipe('', 'Bar rôti'));
    await _send(tester, 'un plat de poisson');
    const done = '1 brouillon créé dans « Mes créations Kass\'Dalle ✨ ».';

    // Le bandeau ouvre la feuille ; « Figer le repas » y est.
    await tester.tap(find.text('Plat · Bar rôti · 4 parts · modifié'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Figer le repas'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Figer'));
    await tester.pumpAndSettle();

    // Le figement s'est déroulé dans la feuille verrouillée, encore ouverte :
    // le brouillon est là, le compte rendu attend.
    expect(fakes.drafts.created, ['Bar rôti']);
    expect(find.text('Brouillon créé ·'), findsOneWidget);
    expect(find.text('1 brouillon créé · 0 recette liée'), findsOneWidget);
    expect(find.byTooltip('Fermer'), findsOneWidget);
    expect(find.text(done), findsNothing);

    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text(done), findsOneWidget);
    expect(find.text('Plat · Bar rôti · 4 parts · figé'), findsOneWidget);
    expect(find.text('Repas figé.'), findsOneWidget);
  });

  testWidgets('30 tours faits : champ et Envoyer fermés, la phrase', (
    tester,
  ) async {
    await _pump(
      tester,
      quota: const WorkshopQuota(limit: 30, remaining: 0),
      initialMessage: 'un plat',
    );
    expect(
      find.text(
        'Vous avez fait vos 30 tours d\'aujourd\'hui. Le compteur repart '
        'demain.',
      ),
      findsOneWidget,
    );
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isFalse);
    final send = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );
    expect(send.onPressed, isNull);
  });

  testWidgets('réponse illisible : carte, « Réessayer », tour compté', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns
      ..add(
        GeminiCallableException(
          'internal',
          'L\'IA n\'a pas rendu de réponse lisible.',
          {
            'reason': kWorkshopUnreadableReason,
            'quota': {'limit': 30, 'remaining': 29},
          },
        ),
      )
      ..add(_turnResult([_course('Bar rôti')], remaining: 28));
    await _send(tester, 'un plat');

    expect(find.text('Réponse illisible, plat inchangé.'), findsOneWidget);
    expect(
      find.text('L\'IA n\'a pas rendu de réponse lisible.'),
      findsOneWidget,
    );
    // Facturé et compté : 29, pas 30. Le texte reste dans le champ.
    expect(
      find.textContaining('Il vous reste 29 tours aujourd\'hui.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextField, 'un plat'), findsOneWidget);
    expect(find.text('Pas encore de plat'), findsOneWidget);
    expect(_errors.features, ['mealWorkshop.turn']);

    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(find.text('Réponse illisible, plat inchangé.'), findsNothing);
    expect(find.text('Plat mis à jour'), findsOneWidget);
    expect(
      find.text('Tour 1 sur 20 · Il vous reste 28 tours aujourd\'hui.'),
      findsOneWidget,
    );
  });

  testWidgets('budget d\'IA sur un tour : carte sans « Réessayer »', (
    tester,
  ) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(
      GeminiCallableException(
        'resource-exhausted',
        'Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui.',
        {'scope': 'ai_budget', 'reason': 'cost'},
      ),
    );
    await _send(tester, 'un plat');
    expect(find.text('Réponse non reçue.'), findsOneWidget);
    expect(
      find.text('Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui.'),
      findsOneWidget,
    );
    expect(find.text('Réessayer'), findsNothing);
  });

  testWidgets('quitter avec une conversation : la question', (tester) async {
    final fakes = await _pump(tester);
    fakes.functions.turns.add(_turnResult([_course('Bar rôti')]));
    await _send(tester, 'un plat');
    final popScope = tester.widget<PopScope<dynamic>>(
      find.byWidgetPredicate((w) => w is PopScope).first,
    );
    expect(popScope.canPop, isFalse);
    popScope.onPopInvokedWithResult!(false, null);
    await tester.pumpAndSettle();
    expect(find.text('Quitter sans enregistrer ?'), findsOneWidget);
    expect(
      find.text('Le plat et la conversation seront perdus.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Rester'));
    await tester.pumpAndSettle();
    expect(find.text('Bar rôti'), findsOneWidget);
  });
}
