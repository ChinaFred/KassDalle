import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_composition.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';
import 'package:kass_dalle/features/planning/presentation/meal_composer.dart';
import 'package:kass_dalle/features/planning/presentation/meal_staples_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

import 'support/test_backend.dart';

/// Palier « Menu » : l'éditeur en plat ou en menu, la tuile d'un menu, et
/// « Repasser en plat » depuis le planning.
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

Recipe _recipe(String id, String titre, {String? role}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: 'Cuire.',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(mealRole: role, contains: const ['proteine']),
    ingredientsIndex: const [],
    createdBy: 'uid',
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

final _blanquette = _recipe('blanquette', 'Blanquette de veau', role: 'plat');

MealComponent _c(String role, String label, {String? id, String? sideOf}) =>
    MealComponent.fromMap({
      'role': role,
      'label': label,
      'id': ?id,
      'side_of': ?sideOf,
    });

void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  group('éditeur : plat ou menu', () {
    Future<List<MealComposerResult>> pumpComposer(
      WidgetTester tester, {
      List<MealComponent> sides = const [],
      MealComposition? initial,
      MealKind? initialKind,
      DateTime? mealDate,
    }) async {
      final saved = <MealComposerResult>[];
      const size = Size(500, 1600);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myStaplesProvider.overrideWithValue(AsyncValue.data(_staples)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showMealComposer(
                    context,
                    load: () async => MealComposerData(
                      main: _blanquette,
                      recipes: [_blanquette],
                    ),
                    sides: sides,
                    initial: initial,
                    initialKind: initialKind,
                    mealDate: mealDate,
                    onSave: (c) async => saved.add(c),
                    errorReporter: _RecordingErrorReportService(),
                  ),
                  child: const Text('Ouvrir'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();
      return saved;
    }

    List<String> roles(MealComposerResult r) => [
      for (final c in r.componentsFor('Blanquette de veau'))
        c.isMainMarker ? 'main' : '${c.role.name}:${c.label}',
    ];

    Future<void> courseAction(
      WidgetTester tester,
      String type,
      String action, {
      int at = 0,
    }) async {
      await tester.tap(find.byTooltip('Actions sur « $type »').at(at));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }

    testWidgets('titre : le jour du repas', (tester) async {
      await pumpComposer(tester, mealDate: DateTime(2026, 10, 25, 12));
      expect(find.text('Repas du dimanche 25 oct.'), findsOneWidget);
    });

    testWidgets('plat → menu : modèle d\'office, services à choisir', (
      tester,
    ) async {
      final saved = await pumpComposer(
        tester,
        sides: [MealComponent.staple(_staples.first.staple)],
      );
      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Entrée'), findsOneWidget);
      expect(find.text('Dessert'), findsOneWidget);
      expect(find.text('à choisir'), findsNWidgets(2));
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Entrée, plat, dessert'),
      );
      expect(chip.selected, isTrue);

      await tester.tap(find.text('Plat et dessert'));
      await tester.pumpAndSettle();
      expect(find.text('Entrée'), findsNothing);

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(saved.single.kind, MealKind.menu);
      expect(roles(saved.single), ['main', 'accompagnement:Riz', 'dessert:']);
    });

    testWidgets('« Passer en menu » ouvre l\'éditeur en mode menu', (
      tester,
    ) async {
      await pumpComposer(tester, initialKind: MealKind.menu);
      expect(find.text('Entrée, plat, dessert'), findsOneWidget);
      expect(find.text('Entrée'), findsOneWidget);
    });

    testWidgets('menu → plat : services retirés à l\'enregistrement, '
        'revenir les rend', (tester) async {
      final saved = await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('entree', 'Velouté'),
          _c('accompagnement', 'Riz'),
          _c('dessert', 'Tarte'),
        ]),
      );
      expect(find.text('Velouté'), findsOneWidget);
      await tester.tap(find.text('Plat').first);
      await tester.pumpAndSettle();
      expect(
        find.text('2 services seront retirés à l\'enregistrement'),
        findsOneWidget,
      );
      expect(find.text('Velouté'), findsNothing);

      await tester.tap(find.text('Menu'));
      await tester.pumpAndSettle();
      expect(find.text('Velouté'), findsOneWidget);

      await tester.tap(find.text('Plat').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(saved.single.kind, MealKind.plat);
      expect(roles(saved.single), ['accompagnement:Riz']);
    });

    testWidgets('Monter et Descendre', (tester) async {
      final saved = await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('entree', 'Velouté'),
          _c('fromage', 'Comté'),
          _c('dessert', 'Tarte'),
        ]),
      );
      await courseAction(tester, 'Dessert', 'Monter');
      await courseAction(tester, 'Entrée', 'Descendre');
      // Le premier service n'a pas « Monter », le dernier pas « Descendre ».
      await tester.tap(find.byTooltip('Actions sur « Plat »'));
      await tester.pumpAndSettle();
      expect(find.text('Monter'), findsNothing);
      expect(find.text('Retirer'), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(roles(saved.single), [
        'main',
        'entree:Velouté',
        'dessert:Tarte',
        'fromage:Comté',
      ]);
    });

    testWidgets('à deux services, « Retirer » devient « Repasser en plat »', (
      tester,
    ) async {
      await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('plat', 'Blanquette de veau', id: 'main'),
          _c('dessert', 'Tarte'),
        ]),
      );
      await tester.tap(find.byTooltip('Actions sur « Dessert »'));
      await tester.pumpAndSettle();
      expect(find.text('Retirer'), findsNothing);
      await tester.tap(find.text('Repasser en plat'));
      await tester.pumpAndSettle();
      expect(
        find.text('1 service sera retiré à l\'enregistrement'),
        findsOneWidget,
      );
    });

    testWidgets('le plat principal ne se retire pas, un plat secondaire oui', (
      tester,
    ) async {
      final saved = await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('entree', 'Velouté'),
          _c('plat', 'Blanquette de veau', id: 'main'),
          _c('plat', 'Gratin', id: 'p2'),
          _c('accompagnement', 'Salade', sideOf: 'p2'),
        ]),
      );
      expect(find.text('Gratin'), findsOneWidget);
      expect(find.text('Salade'), findsOneWidget);
      await courseAction(tester, 'Plat', 'Retirer', at: 1);
      expect(find.text('Gratin'), findsNothing);
      expect(find.text('Salade'), findsNothing);
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(roles(saved.single), ['entree:Velouté', 'main']);
    });

    testWidgets('dix services au plus', (tester) async {
      await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          for (var i = 0; i < 7; i++) _c('autre', 'Service $i'),
          _c('dessert', 'Tarte'),
        ]),
      );
      await tester.scrollUntilVisible(
        find.text('Ajouter un service'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Ajouter un service'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fromage').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('10 services au plus'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('10 services au plus'), findsOneWidget);
      expect(find.text('Ajouter un service'), findsNothing);
    });

    testWidgets('« Autre… » : un service nommé', (tester) async {
      final saved = await pumpComposer(tester, initialKind: MealKind.menu);
      await tester.tap(find.text('Ajouter un service'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Autre…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Trou normand');
      await tester.tap(find.text('Valider'));
      await tester.pumpAndSettle();
      expect(find.text('Trou normand'), findsOneWidget);
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      final last = saved.single.componentsFor('Blanquette').last;
      expect(last.role, MealComponentRole.autre);
      expect(last.courseLabel, 'Trou normand');
    });

    testWidgets('choisir le fromage : garnitures fromage, avec leur part', (
      tester,
    ) async {
      final saved = await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('plat', 'Blanquette de veau', id: 'main'),
          _c('fromage', ''),
        ]),
      );
      await tester.tap(find.widgetWithText(TextButton, 'Choisir'));
      await tester.pumpAndSettle();
      expect(find.text('Fromage'), findsWidgets);
      expect(find.text('Riz'), findsNothing);
      expect(find.text('30 g par part'), findsOneWidget);
      await tester.tap(find.text('Comté'));
      await tester.pumpAndSettle();
      expect(find.text('à choisir'), findsNothing);
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      final fromage = saved.single.componentsFor('Blanquette').last;
      expect(fromage.role, MealComponentRole.fromage);
      expect(fromage.stapleId, 'comte');
    });

    testWidgets('mode menu : la ligne d\'apport sous chaque plat', (
      tester,
    ) async {
      await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('entree', 'Velouté'),
          _c('plat', 'Blanquette de veau', id: 'main'),
          _c('plat', 'Gratin', id: 'p2'),
        ]),
      );
      expect(find.text('Apporte : Protéine'), findsOneWidget);
      expect(find.text('Apports du plat inconnus'), findsOneWidget);
    });

    testWidgets('« Passer en menu » puis Annuler : pas de question', (
      tester,
    ) async {
      final saved = await pumpComposer(tester, initialKind: MealKind.menu);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(find.text('Abandonner les modifications ?'), findsNothing);
      expect(saved, isEmpty);
    });

    testWidgets('« Passer en menu » puis Enregistrer : le menu proposé est '
        'créé', (tester) async {
      final saved = await pumpComposer(tester, initialKind: MealKind.menu);
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(saved.single.kind, MealKind.menu);
    });

    testWidgets('un plat secondaire qui change de type : « 2 accompagnements '
        'retirés. » avec « Annuler »', (tester) async {
      await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('plat', 'Blanquette de veau', id: 'main'),
          _c('plat', 'Gratin', id: 'p2'),
          _c('accompagnement', 'Salade', sideOf: 'p2'),
          _c('accompagnement', 'Pain', sideOf: 'p2'),
        ]),
      );
      await courseAction(tester, 'Plat', 'Changer le type', at: 1);
      await tester.tap(find.text('Dessert'));
      await tester.pumpAndSettle();
      expect(find.text('Salade'), findsNothing);
      expect(find.text('2 accompagnements retirés.'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Annuler'));
      await tester.pumpAndSettle();
      expect(find.text('Salade'), findsOneWidget);
      expect(find.text('Pain'), findsOneWidget);
    });

    testWidgets('un plat secondaire à choisir n\'a pas encore '
        '« Ajouter un accompagnement »', (tester) async {
      await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('plat', 'Blanquette de veau', id: 'main'),
          _c('plat', '', id: 'p2'),
        ]),
      );
      expect(find.text('Ajouter un accompagnement'), findsOneWidget);
    });

    testWidgets('six accompagnements au plus pour un plat du menu', (
      tester,
    ) async {
      await pumpComposer(
        tester,
        initial: MealComposition.fromComponents([
          _c('entree', 'Velouté'),
          for (var i = 0; i < kMaxSidesPerDish; i++)
            _c('accompagnement', 'Côté $i'),
        ]),
      );
      await tester.scrollUntilVisible(
        find.text('6 accompagnements au plus'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('6 accompagnements au plus'), findsOneWidget);
      expect(find.text('Ajouter un accompagnement'), findsNothing);
    });
  });

  group('tuile d\'un menu', () {
    PlannedMeal menuMeal({List<MealComponent>? components}) => PlannedMeal(
      id: 'm1',
      uid: 'uid',
      recipeId: 'blanquette',
      recipeTitre: 'Blanquette de veau',
      plannedAt: DateTime(2030, 1, 6, 12),
      durationMinutes: 60,
      mealKind: MealKind.menu,
      components:
          components ??
          [
            _c('entree', 'Velouté'),
            _c('plat', 'Blanquette de veau', id: 'main'),
            _c('accompagnement', 'Riz'),
            _c('accompagnement', 'Haricots verts'),
            _c('fromage', ''),
            MealComponent.fromMap({
              'role': 'dessert',
              'label': 'Tarte de Marie',
              'recipe_id': 'tarte',
            }),
          ],
      createdAt: DateTime(2026, 1, 1),
    );

    Future<void> pumpTile(WidgetTester tester, Widget tile) async {
      await tester.binding.setSurfaceSize(const Size(500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ListView(children: [tile])),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('les services dans l\'ordre, le vide en « à choisir »', (
      tester,
    ) async {
      final chosen = <int>[];
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(),
          isPast: false,
          aiLoading: false,
          isWide: false,
          onDelete: () {},
          onChooseCourse: chosen.add,
        ),
      );
      expect(find.text('Blanquette de veau'), findsOneWidget);
      expect(find.text('Menu · 4 services'), findsOneWidget);
      expect(find.text('Entrée : Velouté'), findsOneWidget);
      // Le plat principal, puis ses accompagnements en retrait.
      expect(find.text('Plat'), findsOneWidget);
      expect(find.text('+ Riz'), findsOneWidget);
      expect(find.text('+ Haricots verts'), findsOneWidget);
      expect(find.text('Fromage : à choisir'), findsOneWidget);
      expect(find.text('Dessert : Tarte de Marie'), findsOneWidget);
      final text = tester.widget<Text>(find.text('Fromage : à choisir'));
      final scheme = Theme.of(
        tester.element(find.text('Fromage : à choisir')),
      ).colorScheme;
      expect(text.style?.color, scheme.error);
      await tester.tap(find.widgetWithText(TextButton, 'Choisir'));
      expect(chosen, [2]);
    });

    testWidgets('une recette non partagée garde son cadenas', (tester) async {
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(),
          isPast: false,
          aiLoading: false,
          isWide: false,
          readOnly: true,
          lockedRecipeIds: const {'tarte'},
          onChooseCourse: (_) {},
        ),
      );
      expect(
        find.text('Dessert : Tarte de Marie · Recette non partagée'),
        findsOneWidget,
      );
      // Lecture seule : ni [Choisir], ni menu ⋮.
      expect(find.widgetWithText(TextButton, 'Choisir'), findsNothing);
      expect(find.byType(PopupMenuButton<PlanningMealAction>), findsNothing);
    });

    testWidgets('menu ⋮ : « Repasser en plat » sur un menu', (tester) async {
      var switched = false;
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(),
          isPast: false,
          aiLoading: false,
          isWide: false,
          onCompose: () {},
          onSwitchToMenu: () {},
          onSwitchToDish: () => switched = true,
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      expect(find.text('Composer le menu'), findsOneWidget);
      expect(find.text('Passer en menu'), findsNothing);
      await tester.tap(find.text('Repasser en plat'));
      await tester.pumpAndSettle();
      expect(switched, isTrue);
    });

    testWidgets('un accompagnement-recette verrouillé garde son cadenas', (
      tester,
    ) async {
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(
            components: [
              _c('entree', 'Velouté'),
              _c('plat', 'Blanquette de veau', id: 'main'),
              MealComponent.fromMap({
                'role': 'accompagnement',
                'label': 'Purée',
                'recipe_id': 'puree',
              }),
              MealComponent.fromMap({
                'role': 'plat',
                'id': 'p2',
                'label': 'Gratin',
                'recipe_id': 'gratin',
              }),
            ],
          ),
          isPast: false,
          aiLoading: false,
          isWide: false,
          readOnly: true,
          lockedRecipeIds: const {'puree', 'gratin'},
          onComponentTap: (_) {},
        ),
      );
      expect(find.text('+ Purée · Recette non partagée'), findsOneWidget);
      // La mention désigne le plat secondaire, sur sa propre ligne.
      expect(find.text('Plat : Gratin · Recette non partagée'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(2));
    });

    testWidgets('un accompagnement-recette lisible s\'ouvre d\'un appui', (
      tester,
    ) async {
      final opened = <String>[];
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(
            components: [
              _c('entree', 'Velouté'),
              _c('plat', 'Blanquette de veau', id: 'main'),
              MealComponent.fromMap({
                'role': 'accompagnement',
                'label': 'Purée',
                'recipe_id': 'puree',
              }),
            ],
          ),
          isPast: false,
          aiLoading: false,
          isWide: false,
          readOnly: true,
          onComponentTap: (c) => opened.add(c.recipeId!),
        ),
      );
      await tester.tap(find.text('+ Purée'));
      expect(opened, ['puree']);
    });

    testWidgets('[Choisir] porte un libellé pour lecteur d\'écran', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(),
          isPast: false,
          aiLoading: false,
          isWide: false,
          onChooseCourse: (_) {},
        ),
      );
      expect(find.bySemanticsLabel('Choisir le fromage'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('pas de « Passer en menu » sur un dessert', (tester) async {
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: PlannedMeal(
            id: 'm3',
            uid: 'uid',
            recipeId: 'tarte',
            recipeTitre: 'Tarte aux pommes',
            plannedAt: DateTime(2030, 1, 6, 12),
            durationMinutes: 60,
            createdAt: DateTime(2026, 1, 1),
          ),
          isPast: false,
          aiLoading: false,
          isWide: false,
          sideStatus: const DishSideStatus(DishSideState.notApplicable),
          onDelete: () {},
          onCompose: () {},
          onSwitchToMenu: () {},
        ),
      );
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      expect(find.text('Passer en menu'), findsNothing);
      expect(find.text('Composer le repas'), findsNothing);
    });

    testWidgets('menu ⋮ : « Passer en menu » sur un plat', (tester) async {
      var switched = false;
      await pumpTile(
        tester,
        PlanningMealTile(
          meal: menuMeal(components: [_c('accompagnement', 'Riz')]),
          isPast: false,
          aiLoading: false,
          isWide: false,
          onSwitchToMenu: () => switched = true,
          onSwitchToDish: () {},
        ),
      );
      // `meal_kind` noté menu, mais plus rien d'autre qu'un accompagnement :
      // le repas reste un menu tant qu'on ne le repasse pas en plat.
      expect(find.text('Menu · 1 service'), findsOneWidget);

      await pumpTile(
        tester,
        PlanningMealTile(
          meal: PlannedMeal(
            id: 'm2',
            uid: 'uid',
            recipeId: 'blanquette',
            recipeTitre: 'Blanquette de veau',
            plannedAt: DateTime(2030, 1, 6, 12),
            durationMinutes: 60,
            components: [_c('accompagnement', 'Riz')],
            createdAt: DateTime(2026, 1, 1),
          ),
          isPast: false,
          aiLoading: false,
          isWide: false,
          onSwitchToMenu: () => switched = true,
          onSwitchToDish: () {},
        ),
      );
      expect(find.text('Accompagnement : Riz'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      expect(find.text('Repasser en plat'), findsNothing);
      await tester.tap(find.text('Passer en menu'));
      await tester.pumpAndSettle();
      expect(switched, isTrue);
    });
  });

  group('Nouveau planning : carte d\'un créneau en menu', () {
    Future<void> pumpSlot(
      WidgetTester tester, {
      MealComponent? starter,
      List<MealCourse> extra = const [],
      VoidCallback? onCompose,
      ValueChanged<int>? onChooseExtraCourse,
    }) async {
      await tester.binding.setSurfaceSize(const Size(500, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BatchSlotTile(
                index: 0,
                date: DateTime(2026, 10, 25),
                recipe: _blanquette,
                slotTime: const TimeOfDay(hour: 12, minute: 0),
                isGenerating: false,
                dayConstraint: const DayConstraint(
                  mealFormat: MealFormat.entreePlat,
                ),
                isBatchDay: false,
                onAssign: () {},
                onRemove: () {},
                onDelete: () {},
                onTimeChanged: (_) {},
                onMaxPrepChanged: (_) {},
                onTargetPortionsChanged: (_) {},
                onReheatChanged: (_) {},
                onNotesChanged: (_) {},
                onFormatChanged: (_) {},
                starter: starter,
                extraCourses: extra,
                onCompose: onCompose,
                onChooseExtraCourse: onChooseExtraCourse,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('une entrée « à choisir » posée par l\'éditeur est un '
        'avertissement', (tester) async {
      await pumpSlot(tester, starter: _c('entree', ''));
      expect(find.text('Entrée : à choisir'), findsOneWidget);
      expect(find.text('Entrée : '), findsNothing);
    });

    testWidgets('les autres services dans « Détails », « Composer le menu » '
        'dans ⋮', (tester) async {
      var composed = 0;
      final chosen = <int>[];
      final courses = MealComposition.fromComponents([
        _c('entree', 'Velouté'),
        _c('plat', 'Blanquette de veau', id: 'main'),
        _c('plat', 'Gratin', id: 'p2'),
        _c('accompagnement', 'Salade', sideOf: 'p2'),
        _c('fromage', ''),
      ]).courses;
      await pumpSlot(
        tester,
        starter: _c('entree', 'Velouté'),
        extra: [courses[2], courses[3]],
        onCompose: () => composed++,
        onChooseExtraCourse: chosen.add,
      );
      // Le pli « Détails » s'ouvre d'un appui.
      await tester.tap(find.text('Détails'));
      await tester.pumpAndSettle();
      expect(find.text('Plat : Gratin + Salade'), findsOneWidget);
      expect(find.text('Fromage : à choisir'), findsOneWidget);
      // [Choisir] ouvre la feuille du type, pas l'éditeur.
      await tester.tap(find.widgetWithText(TextButton, 'Choisir'));
      expect(chosen, [1]);
      expect(composed, 0);
      expect(
        find.byIcon(Icons.rice_bowl_outlined),
        findsNothing,
        reason: 'un service vide porte l\'icône de son type',
      );

      await tester.tap(find.byTooltip('Plus d\'actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Composer le menu'));
      await tester.pumpAndSettle();
      expect(composed, 1);
    });

    test('le format du repas se lit « Menu : … »', () {
      expect(
        MealFormat.entreePlatDessert.label,
        'Menu : entrée, plat, dessert',
      );
      expect(MealFormat.entreePlat.label, 'Menu : entrée et plat');
      expect(MealFormat.platDessert.label, 'Menu : plat et dessert');
      expect(MealFormat.plat.label, 'Plat seul');
      expect(MealFormat.leger.label, 'Léger');
    });
  });

  group('planning : « Repasser en plat »', () {
    Future<TestBackend> pumpPlanning(
      WidgetTester tester,
      List<MealComponent> components, {
      UserRole role = UserRole.editor,
      AsyncValue<List<UserStaple>>? staples,
    }) async {
      final backend = TestBackend(
        user: testUser(role: role),
        planningWrites: true,
      );
      final now = DateTime.now();
      await backend.firestore
          .collection('planned_meals')
          .doc('menu1')
          .set(
            PlannedMeal(
              id: 'menu1',
              uid: backend.user.uid,
              recipeTitre: 'Blanquette de veau',
              plannedAt: DateTime(now.year, now.month, now.day, 19),
              durationMinutes: 60,
              mealKind: MealKind.menu,
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
            if (staples != null) myStaplesProvider.overrideWithValue(staples),
          ],
          child: const MaterialApp(
            locale: Locale('fr'),
            home: PlanningScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return backend;
    }

    Future<Map<String, dynamic>> stored(TestBackend backend) async =>
        (await backend.firestore.collection('planned_meals').doc('menu1').get())
            .data()!;

    Future<void> openSwitch(WidgetTester tester) async {
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repasser en plat'));
      await tester.pumpAndSettle();
    }

    testWidgets('un service rempli : la question, puis « Annuler » rend le '
        'menu', (tester) async {
      final backend = await pumpPlanning(tester, [
        _c('entree', 'Velouté'),
        _c('plat', 'Blanquette de veau', id: 'main'),
        _c('accompagnement', 'Riz'),
        _c('fromage', ''),
      ]);
      expect(find.text('Menu · 3 services'), findsOneWidget);
      await openSwitch(tester);
      expect(find.text('Repasser en plat ?'), findsOneWidget);
      expect(find.text('Seront retirés : Entrée : Velouté.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Repasser en plat'));
      await tester.pumpAndSettle();

      var data = await stored(backend);
      expect(data['meal_kind'], 'plat');
      expect(data['components'], [
        {'role': 'accompagnement', 'label': 'Riz'},
      ]);
      expect(find.text('Repassé en plat.'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Accompagnement : Riz'), findsOneWidget);

      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      data = await stored(backend);
      expect(data['meal_kind'], 'menu');
      expect((data['components'] as List).length, 4);
    });

    testWidgets('« Annuler » de la question ne change rien', (tester) async {
      final backend = await pumpPlanning(tester, [
        _c('entree', 'Velouté'),
        _c('accompagnement', 'Riz'),
      ]);
      await openSwitch(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Annuler'));
      await tester.pumpAndSettle();
      expect((await stored(backend))['meal_kind'], 'menu');
      expect(find.text('Repassé en plat.'), findsNothing);
    });

    testWidgets('[Choisir] sans garnitures lisibles : le dire, avec '
        '« Réessayer »', (tester) async {
      await pumpPlanning(tester, [
        _c('entree', 'Velouté'),
        _c('plat', 'Blanquette de veau', id: 'main'),
        _c('fromage', ''),
      ], staples: AsyncValue.error(StateError('réseau'), StackTrace.empty));
      await tester.tap(find.widgetWithText(TextButton, 'Choisir'));
      await tester.pumpAndSettle();
      expect(
        find.text('Vos garnitures n\'ont pas pu être lues.'),
        findsOneWidget,
      );
      expect(find.text('Réessayer'), findsOneWidget);
      expect(find.textContaining('Aucune garniture ni recette'), findsNothing);
    });

    testWidgets('services tous vides : pas de question', (tester) async {
      final backend = await pumpPlanning(tester, [
        _c('entree', ''),
        _c('plat', 'Blanquette de veau', id: 'main'),
        _c('dessert', ''),
      ]);
      await openSwitch(tester);
      expect(find.text('Repasser en plat ?'), findsNothing);
      expect((await stored(backend))['meal_kind'], 'plat');
      expect(find.text('Repassé en plat.'), findsOneWidget);
    });

    testWidgets('le lecteur lit le menu partagé, sans geste d\'édition', (
      tester,
    ) async {
      final backend = TestBackend(user: testUser(role: UserRole.reader));
      final now = DateTime.now();
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
                const PlanningReach(
                  uids: {'marie'},
                  groupIds: {},
                  maskedGroupIds: {},
                ),
              ),
            ),
            sharedPlannedMealsProvider.overrideWith(
              (ref, uid) => Stream.value([
                PlannedMeal(
                  id: 'm1',
                  uid: 'marie',
                  recipeId: 'r1',
                  recipeTitre: 'Poulet basquaise',
                  plannedAt: DateTime(now.year, now.month, now.day, 19),
                  durationMinutes: 60,
                  mealKind: MealKind.menu,
                  components: [_c('entree', 'Velouté'), _c('fromage', '')],
                  createdAt: now,
                ),
              ]),
            ),
            memberNameProvider.overrideWith((ref, uid) => 'Marie'),
          ],
          child: const MaterialApp(
            locale: Locale('fr'),
            home: PlanningScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Poulet basquaise'), findsOneWidget);
      expect(find.text('Menu · 3 services'), findsOneWidget);
      expect(find.text('Fromage : à choisir'), findsOneWidget);
      expect(find.byType(PopupMenuButton<PlanningMealAction>), findsNothing);
      expect(find.widgetWithText(TextButton, 'Choisir'), findsNothing);
    });
  });
}
