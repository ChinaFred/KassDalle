import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/domain/planning_week.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';

import 'support/test_backend.dart';

/// `/planning?date=AAAA-MM-JJ` (v0.24.78) : la lecture du paramètre, son
/// écriture par `planningLocation`, et l'écran ouvert sur la période qui
/// contient ce jour. Paramètre absent ou illisible : la semaine en cours.
void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  group('parsePlanningDateParam', () {
    test('un jour AAAA-MM-JJ, à minuit heure locale', () {
      expect(parsePlanningDateParam('2026-11-12'), DateTime(2026, 11, 12));
    });

    test('absent ou illisible : null', () {
      expect(parsePlanningDateParam(null), isNull);
      expect(parsePlanningDateParam(''), isNull);
      expect(parsePlanningDateParam('demain'), isNull);
      expect(parsePlanningDateParam('2026-11-12T19:30'), isNull);
      expect(parsePlanningDateParam('12/11/2026'), isNull);
      // Un jour qui n'existe pas n'est pas reporté au mois suivant.
      expect(parsePlanningDateParam('2026-02-31'), isNull);
      expect(parsePlanningDateParam('2026-13-01'), isNull);
    });

    test('planningLocation écrit ce que parsePlanningDateParam relit', () {
      final location = planningLocation(date: DateTime(2026, 3, 5, 19, 30));
      expect(location, '/planning?date=2026-03-05');
      expect(
        parsePlanningDateParam(Uri.parse(location).queryParameters['date']),
        DateTime(2026, 3, 5),
      );
    });
  });

  group('PlanningScreen(initialDate)', () {
    Future<void> pump(WidgetTester tester, {DateTime? initialDate}) async {
      // Sans repas, l'écran montre son état vide, sans calendrier : un repas
      // aujourd'hui suffit à afficher la période lue.
      final now = DateTime.now();
      final backend = TestBackend(
        plannedMeals: [
          PlannedMeal(
            id: 'm1',
            uid: 'uid-test',
            recipeTitre: 'Blanquette',
            plannedAt: DateTime(now.year, now.month, now.day, 19),
            durationMinutes: 30,
            createdAt: now,
          ),
        ],
      );
      // Téléphone : le calendrier replié titre la période (« Cette semaine »,
      // « Semaine du 27 novembre ») ; déplié, il titre le mois.
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
          ],
          child: MaterialApp(
            locale: const Locale('fr'),
            home: PlanningScreen(initialDate: initialDate),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('sans date : la semaine en cours', (tester) async {
      await pump(tester);
      expect(find.text('Cette semaine'), findsOneWidget);
    });

    testWidgets('avec une date dans trois semaines : la semaine qui la '
        'contient', (tester) async {
      final now = DateTime.now();
      final target = DateTime(now.year, now.month, now.day + 21);
      await pump(tester, initialDate: target);
      final week = planningWeekOf(target, cycleStartDay: DateTime.friday);
      expect(
        find.text(
          'Semaine du ${DateFormat('d MMMM', 'fr').format(week.start)}',
        ),
        findsOneWidget,
      );
      expect(find.text('Cette semaine'), findsNothing);
    });
  });
}
