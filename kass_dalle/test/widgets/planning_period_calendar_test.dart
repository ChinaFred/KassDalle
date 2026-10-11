import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_week.dart';
import 'package:kass_dalle/features/planning/presentation/planning_period_calendar.dart';

/// Le calendrier du planning ne stocke rien : il choisit une période. Ces
/// tests vérifient que la grille va du lundi au dimanche, qu'un appui choisit
/// la semaine du cycle, qu'un appui long puis un appui choisissent une période
/// libre, que le bandeau replié tient sur un téléphone, et que la navigation
/// vers le passé s'arrête où s'arrête l'historique.
void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr', null);
  });

  final today = DateTime(2026, 10, 10);
  final period = planningWeekOf(today, cycleStartDay: DateTime.friday);

  PlannedMeal meal(String id, DateTime at, {DateTime? prepDate}) => PlannedMeal(
    id: id,
    uid: 'u1',
    recipeId: 'r1',
    recipeTitre: 'Gratin',
    plannedAt: at,
    durationMinutes: 45,
    prepDate: prepDate,
    createdAt: DateTime(2026, 1, 1),
  );

  Future<void> pump(
    WidgetTester tester, {
    PlanningPeriod? selected,
    DateTime? rangeStart,
    ValueChanged<DateTime>? onRangeStart,
    VoidCallback? onRangeTooLong,
    bool expanded = false,
    DateTime? month,
    DateTime? earliestDay,
    List<PlannedMeal> meals = const [],
    ValueChanged<PlanningPeriod>? onSelectPeriod,
    ValueChanged<DateTime>? onMonthChanged,
    ValueChanged<DateTime>? onTapDay,
    VoidCallback? onToggleExpanded,
    Size surface = const Size(360, 800),
  }) async {
    await tester.binding.setSurfaceSize(surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PlanningPeriodCalendar(
              period: selected ?? period,
              cycleStartDay: DateTime.friday,
              meals: meals,
              expanded: expanded,
              month: month ?? DateTime(2026, 10),
              earliestDay: earliestDay ?? DateTime(2024, 10, 10),
              onSelectPeriod: onSelectPeriod ?? (_) {},
              onMonthChanged: onMonthChanged ?? (_) {},
              onTapDay: onTapDay,
              rangeStart: rangeStart,
              onRangeStart: onRangeStart ?? (_) {},
              onRangeCancel: () {},
              onRangeTooLong: onRangeTooLong ?? () {},
              onToggleExpanded: onToggleExpanded,
              now: today,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('la grille va du lundi au dimanche', (tester) async {
    await pump(tester);

    final initials = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .where((d) => d != null && RegExp(r'^[A-Z]$').hasMatch(d))
        .toList();
    expect(initials, ['L', 'M', 'M', 'J', 'V', 'S', 'D']);
  });

  testWidgets('replié : le titre et les deux lignes qui portent la semaine', (
    tester,
  ) async {
    await pump(tester, onToggleExpanded: () {});

    expect(find.text('Cette semaine'), findsOneWidget);
    expect(find.text('ven. 9 – jeu. 15 oct.'), findsOneWidget);
    // Du vendredi 9 au jeudi 15 : les lignes du lundi 5 et du lundi 12.
    for (var d = 5; d <= 18; d++) {
      expect(find.text('$d'), findsOneWidget);
    }
    expect(find.text('4'), findsNothing);
    expect(find.text('19'), findsNothing);
    expect(
      tester.getSemantics(find.text('9')).value,
      contains('dans la période choisie'),
    );
    expect(
      tester.getSemantics(find.text('8')).value,
      isNot(contains('dans la période choisie')),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('replié, un appui sur un jour le désigne à la liste', (
    tester,
  ) async {
    DateTime? tapped;
    await pump(tester, onTapDay: (d) => tapped = d);

    await tester.tap(find.text('13'));
    expect(tapped, DateTime(2026, 10, 13));
  });

  testWidgets('déplié, un appui sur un jour choisit toute sa semaine', (
    tester,
  ) async {
    PlanningPeriod? picked;
    await pump(tester, expanded: true, onSelectPeriod: (w) => picked = w);

    // Le mardi 20 octobre appartient à la semaine du vendredi 16 au jeudi 22.
    await tester.tap(find.text('20'));
    expect(picked, PlanningWeek(DateTime(2026, 10, 16)));
  });

  testWidgets('déplié, le mois tient sur un téléphone de 360 px', (
    tester,
  ) async {
    await pump(tester, expanded: true, onToggleExpanded: () {});

    expect(tester.takeException(), isNull);
    expect(find.text('Octobre 2026'), findsOneWidget);
    expect(find.text('préparation'), findsOneWidget);
    // Cinq lignes : du lundi 28 septembre au dimanche 1er novembre.
    expect(find.text('28'), findsNWidgets(2));
    expect(find.text('1'), findsNWidgets(2));
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('les cases font 48 px sur un téléphone', (tester) async {
    await pump(tester);

    final cell = tester.getSize(
      find.ancestor(of: find.text('12'), matching: find.byType(SizedBox)).first,
    );
    expect(cell.width, 48);
  });

  testWidgets('les flèches changent de semaine, replié', (tester) async {
    PlanningPeriod? picked;
    await pump(tester, onSelectPeriod: (w) => picked = w);

    await tester.tap(find.byIcon(Icons.chevron_right));
    expect(picked, period.next);
    await tester.tap(find.byIcon(Icons.chevron_left));
    expect(picked, period.previous);
  });

  testWidgets('la semaine précédente est refusée au bord de l\'historique', (
    tester,
  ) async {
    var changed = 0;
    await pump(
      tester,
      earliestDay: period.start,
      onSelectPeriod: (_) => changed++,
    );

    final back = find.ancestor(
      of: find.byIcon(Icons.chevron_left),
      matching: find.byType(IconButton),
    );
    expect(tester.widget<IconButton>(back).onPressed, isNull);
    await tester.tap(back);
    expect(changed, 0);
  });

  testWidgets(
    '« Revenir à aujourd\'hui » est inactif sur la semaine en cours',
    (tester) async {
      await pump(tester);
      final todayButton = find.ancestor(
        of: find.byIcon(Icons.today_outlined),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(todayButton).onPressed, isNull);
    },
  );

  testWidgets('« Revenir à aujourd\'hui » ramène à la semaine du jour', (
    tester,
  ) async {
    PlanningPeriod? picked;
    await pump(
      tester,
      selected: period.next.next,
      onSelectPeriod: (w) => picked = w,
    );

    expect(find.text('Semaine du 23 octobre'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.today_outlined));
    expect(picked, period);
  });

  testWidgets('un jour de préparation compte, même sans repas servi', (
    tester,
  ) async {
    await pump(
      tester,
      meals: [
        meal(
          'm1',
          DateTime(2026, 10, 12, 12, 30),
          prepDate: DateTime(2026, 10, 10),
        ),
      ],
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSemantics(find.text('10')).value,
      contains('jour de préparation'),
    );
  });

  testWidgets('replié, un jour hors de la semaine choisit la sienne', (
    tester,
  ) async {
    PlanningPeriod? picked;
    DateTime? tapped;
    await pump(
      tester,
      onSelectPeriod: (w) => picked = w,
      onTapDay: (d) => tapped = d,
    );

    // Le lundi 5 est sur la ligne, mais dans la semaine du vendredi 2.
    await tester.tap(find.text('5'));
    expect(tapped, isNull);
    expect(picked, PlanningWeek(DateTime(2026, 10, 2)));
  });

  testWidgets('un appui long commence une période libre', (tester) async {
    DateTime? started;
    await pump(tester, expanded: true, onRangeStart: (d) => started = d);

    await tester.longPress(find.text('20'));
    expect(started, DateTime(2026, 10, 20));
  });

  testWidgets('pendant le choix, l\'appui suivant fixe la fin', (tester) async {
    PlanningPeriod? picked;
    await pump(
      tester,
      expanded: true,
      rangeStart: DateTime(2026, 10, 9),
      onSelectPeriod: (p) => picked = p,
    );

    expect(find.text('Annuler'), findsOneWidget);
    expect(find.textContaining('touchez le dernier jour'), findsOneWidget);
    await tester.tap(find.text('14'));
    expect(
      picked,
      PlanningPeriod(DateTime(2026, 10, 9), DateTime(2026, 10, 14)),
    );
  });

  testWidgets('une fin avant le début inverse les bornes', (tester) async {
    PlanningPeriod? picked;
    await pump(
      tester,
      expanded: true,
      rangeStart: DateTime(2026, 10, 14),
      onSelectPeriod: (p) => picked = p,
    );

    await tester.tap(find.text('6'));
    expect(
      picked,
      PlanningPeriod(DateTime(2026, 10, 6), DateTime(2026, 10, 14)),
    );
  });

  testWidgets('plus de 31 jours : rien n\'est appliqué', (tester) async {
    PlanningPeriod? picked;
    var tooLong = 0;
    await pump(
      tester,
      expanded: true,
      month: DateTime(2026, 11),
      rangeStart: DateTime(2026, 10, 1),
      onSelectPeriod: (p) => picked = p,
      onRangeTooLong: () => tooLong++,
    );

    await tester.tap(find.text('20'));
    expect(picked, isNull);
    expect(tooLong, 1);
  });

  testWidgets('une période libre se titre par ses dates et sa longueur', (
    tester,
  ) async {
    await pump(
      tester,
      selected: PlanningPeriod(DateTime(2026, 9, 28), DateTime(2026, 10, 5)),
      onToggleExpanded: () {},
    );

    expect(find.text('Du lun. 28 sept. au lun. 5 oct.'), findsOneWidget);
    expect(find.text('8 jours'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('libellés de semaine', () {
    String title(PlanningPeriod w) => PlanningPeriodCalendar.periodTitle(
      w,
      today: today,
      cycleStartDay: DateTime.friday,
    );
    expect(title(period), 'Cette semaine');
    expect(title(period.next), 'Semaine prochaine');
    expect(title(period.previous), 'Semaine dernière');
    expect(
      PlanningPeriodCalendar.periodRange(PlanningWeek(DateTime(2026, 10, 30))),
      'ven. 30 oct. – jeu. 5 nov.',
    );
  });
}
