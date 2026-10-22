import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/domain/ranked_candidates.dart';
import 'package:kass_dalle/features/planning/domain/relaxed_criteria.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';
import 'package:kass_dalle/features/planning/presentation/meal_composer.dart';
import 'package:kass_dalle/features/planning/presentation/meal_staples_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_form_mixin.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_meta_panel.dart';

/// Palier « Plat complet » : ce que la recette apporte, corrigeable ; ce qui
/// manque à un plat, en comptant ses accompagnements, dit sur la tuile, dans
/// Nouveau planning et dans « Composer le repas » ; les critères relâchés
/// par le serveur, gardés sur le repas.
/// Enregistre les postes signalés, sans Firebase.
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

Recipe _recipe(
  String id,
  String titre, {
  String? role,
  List<String> contains = const [],
  List<String> sides = const [],
  bool containsManual = false,
}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: 'Cuire.',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(
      mealRole: role,
      contains: contains,
      containsManual: containsManual,
      suggestedSides: sides,
    ),
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
        quantityPerPortion: 70,
      ),
      isOwn: false,
      isOverridden: false,
      hidden: false,
    );

final _staples = [
  _staple('riz', 'Riz', StapleCategory.feculent),
  _staple('haricots_verts', 'Haricots verts', StapleCategory.legume),
];

final _blanquette = _recipe(
  'blanquette',
  'Blanquette de veau',
  role: 'plat',
  contains: ['proteine'],
  sides: ['riz', 'haricots verts'],
);

PlannedMeal _meal({
  List<MealComponent> components = const [],
  List<String> relaxed = const [],
}) => PlannedMeal(
  id: 'm1',
  uid: 'uid',
  recipeId: 'blanquette',
  recipeTitre: 'Blanquette de veau',
  plannedAt: DateTime(2026, 10, 20, 19),
  durationMinutes: 60,
  choiceSource: MealChoiceSource.rules,
  relaxedCriteria: relaxed,
  components: components,
  createdAt: DateTime(2026, 10, 1),
);

// ── Formulaire de recette ──────────────────────────────────────────────────

class _FormHost extends ConsumerStatefulWidget {
  final Recipe recipe;
  const _FormHost(this.recipe);

  @override
  ConsumerState<_FormHost> createState() => _FormHostState();
}

class _FormHostState extends ConsumerState<_FormHost>
    with RecipeFormMixin<_FormHost> {
  @override
  void initState() {
    super.initState();
    initFormFromRecipe(widget.recipe);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _PanelHost extends StatefulWidget {
  final String role;
  final void Function(List<String>) onContains;
  const _PanelHost({required this.role, required this.onContains});

  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> {
  final _ctrls = List.generate(7, (_) => TextEditingController());
  List<String> contains = const ['proteine'];

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: RecipeMetaPanel(
      titleCtrl: _ctrls[0],
      portionsCtrl: _ctrls[1],
      difficultyCtrl: _ctrls[2],
      prepTimeCtrl: _ctrls[3],
      cookTimeCtrl: _ctrls[4],
      restTimeCtrl: _ctrls[5],
      pageNumberCtrl: _ctrls[6],
      saving: false,
      selectedBookId: null,
      onBookChanged: (_, _) {},
      showBookSelector: false,
      cuisines: const [],
      onCuisinesChanged: (_) {},
      dishTypes: const [],
      onDishTypesChanged: (_) {},
      mealRole: widget.role,
      onMealRoleChanged: (_) {},
      mainStarch: null,
      onMainStarchChanged: (_) {},
      mealContains: contains,
      onMealContainsChanged: (v) {
        setState(() => contains = v);
        widget.onContains(v);
      },
    ),
  );
}

Future<void> _pumpPanel(WidgetTester tester, Widget host) async {
  await tester.binding.setSurfaceSize(const Size(500, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        targetBooksProvider.overrideWithValue(const AsyncValue.data(<Book>[])),
      ],
      child: MaterialApp(home: Scaffold(body: host)),
    ),
  );
  await tester.pump();
}

void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  group('ce que la recette apporte : panneau et formulaire', () {
    testWidgets('trois pastilles pour un plat, avec leur aide', (tester) async {
      List<String>? last;
      await _pumpPanel(
        tester,
        _PanelHost(role: 'plat', onContains: (v) => last = v),
      );
      expect(find.text('Ce que la recette apporte'), findsOneWidget);
      expect(find.text(kMealContainsHelper), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, 'Légume'));
      await tester.pump();
      expect(last, ['proteine', 'legume']);
      await tester.tap(find.widgetWithText(FilterChip, 'Protéine'));
      await tester.pump();
      expect(last, ['legume']);
    });

    testWidgets('absentes pour un dessert', (tester) async {
      await _pumpPanel(tester, _PanelHost(role: 'dessert', onContains: (_) {}));
      expect(find.text('Ce que la recette apporte'), findsNothing);
    });

    testWidgets('le féculent principal coche et décoche Féculent', (
      tester,
    ) async {
      final recipe = _blanquette;
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: _FormHost(recipe))),
      );
      final form = tester.state<_FormHostState>(find.byType(_FormHost));
      expect(form.containsManual, isFalse);
      form.setMainStarch('riz');
      expect(form.selectedContains, ['proteine', 'feculent']);
      expect(form.containsManual, isTrue);
      form.setMainStarch('aucun');
      expect(form.selectedContains, ['proteine']);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.contains, ['proteine']);
      expect(tags.toMap()['contains_manual'], isTrue);
    });

    testWidgets('sans correction, la carte n\'a pas de marqueur', (
      tester,
    ) async {
      final recipe = _blanquette;
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: _FormHost(recipe))),
      );
      final form = tester.state<_FormHostState>(find.byType(_FormHost));
      final map = form.buildTagsFromForm(recipe.tags).toMap();
      expect(map['contains'], ['proteine']);
      expect(map.containsKey('contains_manual'), isFalse);
    });

    testWidgets('une correction lue en base reste marquée', (tester) async {
      final recipe = _recipe(
        'r',
        'Gratin',
        role: 'plat',
        contains: ['legume'],
        containsManual: true,
      );
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp(home: _FormHost(recipe))),
      );
      final form = tester.state<_FormHostState>(find.byType(_FormHost));
      expect(form.containsManual, isTrue);
      form.setContains(['legume', 'proteine']);
      expect(form.selectedContains, ['proteine', 'legume']);
    });
  });

  group('critères relâchés', () {
    test('lus dans la liste classée, gardés sur le repas', () {
      final ranking = SlotRanking.fromMap({
        'plats': const [],
        'relaxed': ['in_cycle', 3, '', 'variety_window'],
      });
      expect(ranking.relaxed, ['in_cycle', 'variety_window']);

      final meal = _meal(relaxed: const ['rating', 'futur']);
      final map = meal.toFirestore();
      expect(map['relaxed_criteria'], ['rating', 'futur']);
      final back = PlannedMeal.fromFirestore('m1', {
        ...map,
        'planned_at': Timestamp.fromDate(meal.plannedAt),
      });
      expect(back.relaxedCriteria, ['rating', 'futur']);
      expect(back.extra.containsKey('relaxed_criteria'), isFalse);
      expect(_meal().toFirestore().containsKey('relaxed_criteria'), isFalse);
    });

    test('une clé inconnue ne s\'affiche pas', () {
      expect(RelaxedCriterion.listFrom(['futur', 'in_cycle', 'in_cycle']), [
        RelaxedCriterion.inCycle,
      ]);
      expect(
        RelaxedCriterion.inCycle.sentence,
        'Déjà servi dans ce cycle, faute d\'autre choix',
      );
    });

    test('style voulu relâché : lu et dit', () {
      expect(RelaxedCriterion.listFrom(['wanted_styles']), [
        RelaxedCriterion.wantedStyles,
      ]);
      expect(
        RelaxedCriterion.wantedStyles.sentence,
        'Style souhaité introuvable, faute d\'autre choix',
      );
    });

    testWidgets('la ligne d\'origine les dit après la source', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MealOriginLine.maybe(
              source: MealChoiceSource.rules,
              facts: 'volaille',
              relaxed: const ['in_cycle'],
            ),
          ),
        ),
      );
      expect(
        find.textContaining(
          'déjà servi dans ce cycle, faute d\'autre choix · volaille',
        ),
        findsOneWidget,
      );
    });
  });

  group('tuile du planning', () {
    Future<void> pumpTile(
      WidgetTester tester,
      PlannedMeal meal, {
      DishSideStatus? status,
      bool readOnly = false,
      bool isPast = false,
      ValueChanged<SideNeed>? onComplete,
      VoidCallback? onCompose,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlanningMealTile(
              meal: meal,
              isPast: isPast,
              aiLoading: false,
              isWide: false,
              readOnly: readOnly,
              sideStatus: status,
              onComplete: onComplete,
              onCompose: onCompose,
              onDelete: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('« Il manque : légume » et « Compléter »', (tester) async {
      SideNeed? asked;
      var composed = 0;
      await pumpTile(
        tester,
        _meal(),
        status: const DishSideStatus(
          DishSideState.missing,
          missing: [SideNeed.legume],
        ),
        onComplete: (n) => asked = n,
        onCompose: () => composed++,
      );
      expect(find.text('Il manque : légume'), findsOneWidget);
      await tester.tap(find.text('Compléter'));
      expect(asked, SideNeed.legume);
      await tester.tap(find.text('Il manque : légume'));
      expect(composed, 1);
    });

    testWidgets('repas passé : ni « Il manque », ni « Compléter »', (
      tester,
    ) async {
      await pumpTile(
        tester,
        _meal(),
        isPast: true,
        status: const DishSideStatus(
          DishSideState.missing,
          missing: [SideNeed.legume],
        ),
        onComplete: (_) {},
      );
      expect(find.textContaining('Il manque'), findsNothing);
      expect(find.text('Compléter'), findsNothing);
    });

    testWidgets('six accompagnements : « Compléter » disparaît', (
      tester,
    ) async {
      await pumpTile(
        tester,
        _meal(
          components: [
            for (var i = 0; i < kMaxSidesPerDish; i++)
              MealComponent.free('Côté $i'),
          ],
        ),
        status: const DishSideStatus(
          DishSideState.missing,
          missing: [SideNeed.legume],
        ),
        onComplete: (_) {},
      );
      expect(find.text('Il manque : légume'), findsOneWidget);
      expect(find.text('Compléter'), findsNothing);
    });

    testWidgets('la ligne « Il manque » : 48 px et « Composer le repas »', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpTile(
        tester,
        _meal(),
        status: const DishSideStatus(
          DishSideState.missing,
          missing: [SideNeed.legume],
        ),
        onCompose: () {},
      );
      final line = find.ancestor(
        of: find.text('Il manque : légume'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(line.first).height, greaterThanOrEqualTo(48));
      // Un nœud à part : le libellé de la tuile ne reçoit pas cette aide.
      final data = tester.getSemantics(line.first).getSemanticsData();
      expect(data.hint, 'Composer le repas');
      expect(data.label, 'Il manque : légume');
      handle.dispose();
    });

    testWidgets('un dessert ne se compose pas', (tester) async {
      await pumpTile(
        tester,
        _meal(),
        status: const DishSideStatus(DishSideState.notApplicable),
        onCompose: () {},
      );
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      expect(find.text('Composer le repas'), findsNothing);
    });

    testWidgets('plat non classé : apports inconnus, sans « Compléter »', (
      tester,
    ) async {
      await pumpTile(
        tester,
        _meal(),
        status: const DishSideStatus(DishSideState.unknown),
        onComplete: (_) {},
      );
      expect(find.text('Apports du plat inconnus'), findsOneWidget);
      expect(find.text('Compléter'), findsNothing);
    });

    testWidgets('plat complet : rien sur la tuile', (tester) async {
      await pumpTile(
        tester,
        _meal(),
        status: const DishSideStatus(DishSideState.complete),
      );
      expect(find.text('Plat complet'), findsNothing);
    });

    testWidgets('repas d\'autrui : ni « Il manque », ni « Compléter »', (
      tester,
    ) async {
      await pumpTile(
        tester,
        _meal(),
        readOnly: true,
        status: const DishSideStatus(
          DishSideState.missing,
          missing: [SideNeed.legume],
        ),
        onComplete: (_) {},
      );
      expect(find.textContaining('Il manque'), findsNothing);
      expect(find.text('Compléter'), findsNothing);
    });

    testWidgets(
      '« Composer le repas » remplace « Ajouter un accompagnement »',
      (tester) async {
        await pumpTile(tester, _meal(), onCompose: () {});
        await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
        await tester.pumpAndSettle();
        expect(find.text('Composer le repas'), findsOneWidget);
        expect(find.text('Ajouter un accompagnement'), findsNothing);
      },
    );
  });

  group('créneau de Nouveau planning', () {
    Future<void> pumpSlot(
      WidgetTester tester, {
      List<MealComponent> sides = const [],
      DishSideStatus? status,
      Set<SideNeed> without = const {},
      List<String> relaxed = const [],
      DayConstraint constraint = const DayConstraint(),
      bool noStarter = false,
      ValueChanged<SideNeed?>? onAddSide,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BatchSlotTile(
                index: 0,
                date: DateTime(2026, 10, 20),
                recipe: _blanquette,
                slotTime: const TimeOfDay(hour: 19, minute: 0),
                isGenerating: false,
                dayConstraint: constraint,
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
                sides: sides,
                sideStatus: status,
                needsWithoutCandidate: without,
                relaxed: relaxed,
                noStarterCandidate: noStarter,
                onAddSide: onAddSide ?? (_) {},
                onRemoveSide: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('un légume sans candidat : dit, avec « Choisir »', (
      tester,
    ) async {
      SideNeed? asked;
      await pumpSlot(
        tester,
        sides: [MealComponent.staple(_staples.first.staple)],
        status: const DishSideStatus(
          DishSideState.missing,
          missing: [SideNeed.legume],
        ),
        without: const {SideNeed.legume},
        onAddSide: (n) => asked = n,
      );
      expect(
        find.text(
          'Il manque un légume. Aucune garniture de légume disponible.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Choisir'));
      expect(asked, SideNeed.legume);
      // Tous les accompagnements dans la ligne de résumé.
      expect(find.textContaining('Riz'), findsWidgets);
    });

    testWidgets('une ligne par écart, sans action', (tester) async {
      await pumpSlot(tester, relaxed: const ['rating', 'in_cycle']);
      expect(
        find.text('Aucune recette assez bien notée : critère de note relâché'),
        findsOneWidget,
      );
      expect(
        find.text('Déjà servi dans ce cycle, faute d\'autre choix'),
        findsOneWidget,
      );
    });

    testWidgets('un écart ne s\'écrit qu\'une fois, pli déplié compris', (
      tester,
    ) async {
      await pumpSlot(tester, relaxed: const ['in_cycle']);
      await tester.tap(find.text('Détails'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('déjà servi dans ce cycle', findRichText: true),
        findsNothing,
      );
      expect(
        find.text('Déjà servi dans ce cycle, faute d\'autre choix'),
        findsOneWidget,
      );
    });

    testWidgets('entrée demandée, aucune recette classée en entrée', (
      tester,
    ) async {
      await pumpSlot(
        tester,
        constraint: const DayConstraint(mealFormat: MealFormat.entreePlat),
        noStarter: true,
      );
      expect(
        find.text('Entrée : à choisir. Aucune recette classée en entrée.'),
        findsOneWidget,
      );
    });
  });

  group('Composer le repas', () {
    Future<List<MealComposerResult>> pumpComposer(
      WidgetTester tester, {
      List<MealComponent> sides = const [],
      Future<MealComposerData> Function()? load,
      Future<void> Function(MealComposerResult)? onSave,
      AsyncValue<List<UserStaple>>? staples,
      ErrorReportService? reporter,
    }) async {
      final saved = <MealComposerResult>[];
      await tester.binding.setSurfaceSize(const Size(500, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            myStaplesProvider.overrideWithValue(
              staples ?? AsyncValue.data(_staples),
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showMealComposer(
                    context,
                    load:
                        load ??
                        () async => MealComposerData(
                          main: _blanquette,
                          recipes: [_blanquette],
                        ),
                    sides: sides,
                    onSave: onSave ?? (c) async => saved.add(c),
                    errorReporter: reporter ?? _RecordingErrorReportService(),
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

    testWidgets('dit ce qui manque, propose, enregistre une seule fois', (
      tester,
    ) async {
      final saved = await pumpComposer(
        tester,
        sides: [MealComponent.staple(_staples.first.staple)],
      );
      expect(find.text('Apporte : Protéine'), findsOneWidget);
      expect(find.text('Il manque : légume'), findsOneWidget);
      expect(
        find.text('Suggéré pour le légume : Haricots verts'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Ajouter'));
      await tester.pumpAndSettle();
      expect(find.text('Plat complet'), findsOneWidget);
      expect(saved, isEmpty);

      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved.single.mainChanged, isFalse);
      expect(saved.single.sides.map((s) => s.label), ['Riz', 'Haricots verts']);
      expect(find.text('Composer le repas'), findsNothing);
      expect(find.text('Repas enregistré.'), findsOneWidget);
    });

    testWidgets('fermer avec des modifications demande confirmation', (
      tester,
    ) async {
      final saved = await pumpComposer(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Ajouter').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(find.text('Abandonner les modifications ?'), findsOneWidget);
      await tester.tap(find.text('Abandonner'));
      await tester.pumpAndSettle();
      expect(find.text('Composer le repas'), findsNothing);
      expect(saved, isEmpty);
    });

    testWidgets('six accompagnements au plus', (tester) async {
      await pumpComposer(
        tester,
        sides: [
          for (var i = 0; i < kMaxSidesPerDish; i++)
            MealComponent.free('Côté $i'),
        ],
      );
      await tester.scrollUntilVisible(
        find.text('6 accompagnements au plus'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('6 accompagnements au plus'), findsOneWidget);
      expect(find.text('Ajouter un accompagnement'), findsNothing);
    });

    testWidgets('recettes illisibles : l\'erreur et « Réessayer »', (
      tester,
    ) async {
      var calls = 0;
      await pumpComposer(
        tester,
        load: () async {
          calls++;
          if (calls == 1) throw StateError('réseau');
          return MealComposerData(main: _blanquette, recipes: const []);
        },
      );
      expect(
        find.text('Les recettes n\'ont pas pu être lues.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(find.text('Blanquette de veau'), findsOneWidget);
      expect(calls, 2);
    });

    testWidgets('échec d\'enregistrement : dit dans l\'éditeur, resté ouvert', (
      tester,
    ) async {
      final reporter = _RecordingErrorReportService();
      await pumpComposer(
        tester,
        onSave: (_) async => throw StateError('réseau'),
        reporter: reporter,
      );
      await tester.tap(find.widgetWithText(TextButton, 'Ajouter').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      expect(find.text('Composer le repas'), findsOneWidget);
      final message = find.text('Repas non enregistré. Réessayez.');
      expect(message, findsOneWidget);
      // Le message est posé par le messager de l'éditeur, pas par celui de
      // l'écran sous la feuille.
      expect(
        find.ancestor(of: message, matching: find.byType(MealComposerSheet)),
        findsOneWidget,
      );
      expect(reporter.features, ['mealComposer.save']);
    });

    testWidgets('garnitures illisibles : leur propre message', (tester) async {
      await pumpComposer(
        tester,
        staples: AsyncValue.error(StateError('réseau'), StackTrace.empty),
      );
      expect(
        find.text('Vos garnitures n\'ont pas pu être lues.'),
        findsOneWidget,
      );
      expect(find.text('Les recettes n\'ont pas pu être lues.'), findsNothing);
    });

    testWidgets(
      'plat non classé : une seule ligne « Apports du plat inconnus »',
      (tester) async {
        await pumpComposer(
          tester,
          load: () async =>
              MealComposerData(main: _recipe('x', 'Ragoût'), recipes: const []),
        );
        expect(find.text('Apports du plat inconnus'), findsOneWidget);
        expect(find.textContaining('Apports inconnus'), findsNothing);
      },
    );
  });
}
