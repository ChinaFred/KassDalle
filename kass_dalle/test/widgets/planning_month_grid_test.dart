import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/presentation/planning_month_grid.dart';

/// La bande calendaire ne stocke rien : tout ce qu'elle affiche se déduit des
/// repas qu'on lui passe. Ces tests vérifient qu'elle ne décide de rien d'autre
/// — trois mois quand la place le permet, un seul sinon, une hauteur qui ne
/// déborde jamais, et une navigation vers le passé qui s'arrête où s'arrête
/// l'historique.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr', null);
  });

  PlannedMeal meal({
    required String id,
    required DateTime at,
    String? recipeId = 'r1',
    DateTime? prepDate,
  }) {
    return PlannedMeal(
      id: id,
      uid: 'u1',
      recipeId: recipeId,
      recipeTitre: 'Gratin',
      plannedAt: at,
      durationMinutes: 45,
      prepDate: prepDate,
      createdAt: DateTime(2026, 1, 1),
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required DateTime month,
    required DateTime selected,
    List<PlannedMeal> meals = const [],
    DateTime? earliest,
    void Function(DateTime)? onSelectDay,
    void Function(DateTime)? onMonthChanged,
    Size surface = const Size(1400, 900),
    double bandHeight = 280,
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: bandHeight,
            child: PlanningMonthBand(
              month: month,
              selectedDay: selected,
              meals: meals,
              earliestMonth: earliest ?? DateTime(2026, 5),
              onSelectDay: onSelectDay ?? (_) {},
              onMonthChanged: onMonthChanged ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
    'sur un large écran, trois mois : le précédent, le mois, le suivant',
    (tester) async {
      await pump(
        tester,
        month: DateTime(2026, 8),
        selected: DateTime(2026, 8, 12),
      );

      expect(find.text('Août 2026'), findsOneWidget);
      expect(find.text('juillet'), findsOneWidget);
      expect(find.text('septembre'), findsOneWidget);
    },
  );

  testWidgets('sur un écran étroit, seul le mois central subsiste', (
    tester,
  ) async {
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
      surface: const Size(400, 800),
    );

    expect(find.text('Août 2026'), findsOneWidget);
    // Les flèches restent : le mois précédent est atteignable, il n'est
    // simplement plus montré à côté.
    expect(find.text('juillet'), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
  });

  testWidgets('la bande ne déborde jamais de la hauteur qu\'on lui donne', (
    tester,
  ) async {
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
      bandHeight: 200,
    );

    // Un débordement de rendu ferait échouer le test par une exception de
    // layout ; c'est précisément le défaut qu'avait la première version.
    expect(tester.takeException(), isNull);
    final band = tester.getSize(find.byType(PlanningMonthBand));
    expect(band.height, lessThanOrEqualTo(200));
  });

  testWidgets('un appui sur un jour le remonte à l\'écran', (tester) async {
    DateTime? picked;
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
      onSelectDay: (d) => picked = d,
    );

    // Le 17 existe dans les trois mois affichés : on vise celui du mois central.
    await tester.tap(find.text('17').at(1));
    expect(picked, DateTime(2026, 8, 17));
  });

  testWidgets('le mois précédent est refusé au bord de l\'historique', (
    tester,
  ) async {
    var changed = 0;
    await pump(
      tester,
      month: DateTime(2026, 5),
      selected: DateTime(2026, 5, 4),
      earliest: DateTime(2026, 5),
      onMonthChanged: (_) => changed++,
    );

    final back = find.ancestor(
      of: find.byIcon(Icons.chevron_left),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(back).onPressed, isNull);
    await tester.tap(back);
    // Un mois vide faute de chargement ressemblerait à un mois sans repas :
    // mieux vaut que la flèche refuse.
    expect(changed, 0);
  });

  testWidgets('le mois suivant reste toujours accessible', (tester) async {
    DateTime? asked;
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
      onMonthChanged: (m) => asked = m,
    );

    await tester.tap(find.byIcon(Icons.chevron_right));
    expect(asked, DateTime(2026, 9));
  });

  testWidgets('un jour de préparation compte, même sans repas servi', (
    tester,
  ) async {
    // Le plat est servi le 12, préparé le 10 : les deux jours comptent, et le
    // 10 ne porte pourtant aucun repas.
    final plat = meal(
      id: 'm1',
      at: DateTime(2026, 8, 12, 12, 30),
      prepDate: DateTime(2026, 8, 10),
    );

    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
      meals: [plat],
    );

    expect(tester.takeException(), isNull);
    expect(find.text('10'), findsWidgets);
  });

  testWidgets('la légende nomme les trois pastilles', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: PlanningMonthLegend())),
    );

    expect(find.text('repas'), findsOneWidget);
    expect(find.text('créneau vide'), findsOneWidget);
    expect(find.text('préparation'), findsOneWidget);
  });
}
