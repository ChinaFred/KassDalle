import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';

/// La ligne « 4 parts » d'un repas du planning (v0.24.79) : elle ouvre
/// « Changer les parts » d'un appui sur un repas à soi, et reste un texte en
/// lecture seule ou sans action. L'entrée du menu ⋮ reste.
void main() {
  PlannedMeal meal({String? recipeId = 'blanquette', int? portions = 4}) =>
      PlannedMeal(
        id: 'm1',
        uid: 'uid',
        recipeId: recipeId,
        recipeTitre: 'Blanquette de veau',
        plannedAt: DateTime(2026, 11, 20, 19),
        durationMinutes: 35,
        targetPortions: portions,
        createdAt: DateTime(2026, 11, 1),
      );

  Future<void> pumpTile(
    WidgetTester tester,
    PlannedMeal m, {
    bool readOnly = false,
    VoidCallback? onChangePortions,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanningMealTile(
            meal: m,
            isPast: false,
            aiLoading: false,
            isWide: false,
            readOnly: readOnly,
            onChangePortions: onChangePortions,
            onDelete: () {},
          ),
        ),
      ),
    );
  }

  // L'InkWell de la ligne, sous son infobulle : la tuile entière en a un
  // autre, qui ouvre le plat.
  Finder portionsButton() => find.descendant(
    of: find.byTooltip(kChangePortionsLabel),
    matching: find.ancestor(
      of: find.text('4 parts'),
      matching: find.byType(InkWell),
    ),
  );

  testWidgets('un repas à moi : « 4 parts » ouvre « Changer les parts »', (
    tester,
  ) async {
    var opened = 0;
    await pumpTile(tester, meal(), onChangePortions: () => opened++);

    expect(find.text('35 min · '), findsOneWidget);
    expect(find.byTooltip(kChangePortionsLabel), findsOneWidget);
    expect(portionsButton(), findsOneWidget);
    // Cible de 48 px au moins.
    expect(tester.getSize(portionsButton()).height, greaterThanOrEqualTo(48));
    // L'icône de l'entrée du menu, dans la zone appuyable.
    expect(
      find.descendant(
        of: portionsButton(),
        matching: find.byIcon(Icons.people_outline),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('4 parts'));
    await tester.pump();
    expect(opened, 1);

    // L'entrée du menu ⋮ reste.
    await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
    await tester.pumpAndSettle();
    expect(find.text(kChangePortionsLabel), findsOneWidget);
  });

  testWidgets('lecture seule : la ligne reste un texte', (tester) async {
    var opened = 0;
    await pumpTile(
      tester,
      meal(),
      readOnly: true,
      onChangePortions: () => opened++,
    );

    expect(find.text('35 min · 4 parts'), findsOneWidget);
    expect(find.byTooltip(kChangePortionsLabel), findsNothing);
    expect(portionsButton(), findsNothing);
    // Le texte simple ne porte pas l'icône.
    expect(find.byIcon(Icons.people_outline), findsNothing);

    await tester.tap(find.text('35 min · 4 parts'));
    await tester.pump();
    expect(opened, 0);
  });

  testWidgets('texte à 200 % sur 360 px : « 4 parts » passe à la ligne', (
    tester,
  ) async {
    const size = Size(360, 800);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final m = PlannedMeal(
      id: 'm3',
      uid: 'uid',
      recipeId: 'blanquette',
      recipeTitre: 'Blanquette de veau',
      plannedAt: DateTime(2026, 11, 20, 19),
      durationMinutes: 0,
      prepMinutes: 25,
      cookMinutes: 90,
      targetPortions: 4,
      createdAt: DateTime(2026, 11, 1),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: PlanningMealTile(
              meal: m,
              isPast: false,
              aiLoading: false,
              isWide: false,
              onChangePortions: () {},
              onDelete: () {},
            ),
          ),
        ),
      ),
    );

    // Ni les temps, ni « 4 parts » ne débordent.
    expect(tester.takeException(), isNull);
    final timing = find.text('25min prép · 90min cuisson · ');
    expect(timing, findsOneWidget);
    // « 4 parts » ne partage plus la ligne des temps : il descend sous eux.
    expect(
      tester.getTopLeft(find.text('4 parts')).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(timing).dy),
    );
  });

  testWidgets('sans action fournie : la ligne reste un texte', (tester) async {
    await pumpTile(tester, meal());

    expect(find.text('35 min · 4 parts'), findsOneWidget);
    expect(find.byTooltip(kChangePortionsLabel), findsNothing);
  });

  testWidgets('créneau vide, sans recette ni accompagnement : pas d\'appui, '
      'comme dans le menu', (tester) async {
    await pumpTile(tester, meal(recipeId: null), onChangePortions: () {});

    expect(find.text('35 min · 4 parts'), findsOneWidget);
    expect(find.byTooltip(kChangePortionsLabel), findsNothing);
  });

  testWidgets('parts seules, sans temps : « 4 parts » s\'ouvre aussi', (
    tester,
  ) async {
    var opened = 0;
    await pumpTile(
      tester,
      PlannedMeal(
        id: 'm2',
        uid: 'uid',
        recipeId: 'blanquette',
        recipeTitre: 'Blanquette de veau',
        plannedAt: DateTime(2026, 11, 20, 19),
        durationMinutes: 0,
        targetPortions: 4,
        createdAt: DateTime(2026, 11, 1),
      ),
      onChangePortions: () => opened++,
    );

    await tester.tap(find.text('4 parts'));
    await tester.pump();
    expect(opened, 1);
  });
}
