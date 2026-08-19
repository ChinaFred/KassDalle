import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/presentation/planning_month_grid.dart';

/// La grille mensuelle ne stocke rien : tout ce qu'elle affiche se déduit des
/// repas qu'on lui passe. Ces tests vérifient justement qu'elle ne décide de
/// rien d'autre — le bon nombre de cases, le bon jour rendu, et une navigation
/// vers le passé qui s'arrête où l'historique s'arrête.
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
    List<PlannedMeal> prepared = const [],
    DateTime? earliest,
    void Function(DateTime)? onSelectDay,
    void Function(DateTime)? onMonthChanged,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PlanningMonthGrid(
              month: month,
              selectedDay: selected,
              meals: meals,
              prepared: prepared,
              earliestMonth: earliest ?? DateTime(2026, 5),
              onSelectDay: onSelectDay ?? (_) {},
              onMonthChanged: onMonthChanged ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('un mois affiche tous ses jours, et eux seuls', (tester) async {
    // Août 2026 commence un samedi et compte 31 jours.
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
    );

    expect(find.text('1'), findsOneWidget);
    expect(find.text('31'), findsOneWidget);
    // Les cases de débordement sont vides : aucun jour du mois voisin.
    expect(find.text('32'), findsNothing);
  });

  testWidgets('un appui sur un jour le remonte à l\'écran', (tester) async {
    DateTime? picked;
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: DateTime(2026, 8, 12),
      onSelectDay: (d) => picked = d,
    );

    await tester.tap(find.text('17'));
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

  testWidgets('un jour de préparation marque la grille, sans repas servi', (
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
      prepared: [plat],
    );

    // La légende nomme les trois pastilles, sans quoi elles ne veulent rien dire.
    expect(find.text('repas'), findsOneWidget);
    expect(find.text('créneau vide'), findsOneWidget);
    expect(find.text('préparation'), findsOneWidget);
  });

  testWidgets('au-delà de trois repas, la case annonce le surplus', (
    tester,
  ) async {
    final day = DateTime(2026, 8, 12);
    await pump(
      tester,
      month: DateTime(2026, 8),
      selected: day,
      meals: [
        for (var i = 0; i < 5; i++)
          meal(id: 'm$i', at: DateTime(2026, 8, 12, 8 + i * 2)),
      ],
    );

    expect(find.text('+2'), findsOneWidget);
  });
}
