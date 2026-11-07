import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/domain/planning_week.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/planning_target_sheet.dart';

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

  // `/planning/batch?start=AAAA-MM-JJ` (v0.24.79) : « Nouveau planning »
  // commence au premier jour de la période affichée.
  group('parsePlanningStartParam', () {
    final now = DateTime(2026, 11, 7, 21, 45);

    test('un jour à venir ou aujourd\'hui : ce jour, à minuit', () {
      expect(
        parsePlanningStartParam('2026-11-20', now: now),
        DateTime(2026, 11, 20),
      );
      expect(
        parsePlanningStartParam('2026-11-07', now: now),
        DateTime(2026, 11, 7),
      );
    });

    test('absent ou illisible : null', () {
      expect(parsePlanningStartParam(null, now: now), isNull);
      expect(parsePlanningStartParam('', now: now), isNull);
      expect(parsePlanningStartParam('vendredi', now: now), isNull);
      expect(parsePlanningStartParam('2026-11-20T19:00', now: now), isNull);
      expect(parsePlanningStartParam('2026-02-30', now: now), isNull);
    });

    test('un jour passé : null, le prochain cycle reste', () {
      expect(parsePlanningStartParam('2026-11-06', now: now), isNull);
      expect(parsePlanningStartParam('2025-12-31', now: now), isNull);
    });

    test('batchPlanningLocation écrit le groupe et le jour', () {
      final day = DateTime(2026, 11, 20, 19);
      expect(batchPlanningLocation(), '/planning/batch');
      expect(
        batchPlanningLocation(start: day),
        '/planning/batch?start=2026-11-20',
      );
      final both = Uri.parse(batchPlanningLocation(groupId: 'gd', start: day));
      expect(both.path, '/planning/batch');
      expect(both.queryParameters, {'group': 'gd', 'start': '2026-11-20'});
    });
  });

  group('« Nouveau planning » transmet le premier jour affiché', () {
    testWidgets('période dans trois semaines : ?start= son premier jour', (
      tester,
    ) async {
      final now = DateTime.now();
      final target = DateTime(now.year, now.month, now.day + 21);
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
      const size = Size(420, 900);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Uri? opened;
      final router = GoRouter(
        initialLocation: planningLocation(date: target),
        routes: [
          GoRoute(
            path: AppRoutes.planning,
            builder: (context, state) => PlanningScreen(
              initialDate: parsePlanningDateParam(
                state.uri.queryParameters[kPlanningDateParam],
              ),
            ),
            routes: [
              GoRoute(
                path: 'batch',
                builder: (context, state) {
                  opened = state.uri;
                  return const Scaffold(body: Text('Écran batch'));
                },
              ),
            ],
          ),
        ],
      );
      addTearDown(router.dispose);

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
          child: MaterialApp.router(
            locale: const Locale('fr'),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      // Tant que les groupes ne sont pas lus, la liste « Planifier pour… »
      // demande lequel : « Mon planning ».
      if (find.text('Planifier pour…').evaluate().isNotEmpty) {
        await tester.tap(find.text('Mon planning'));
        await tester.pumpAndSettle();
      }

      final week = planningWeekOf(target, cycleStartDay: DateTime.friday);
      expect(find.text('Écran batch'), findsOneWidget);
      expect(opened?.path, AppRoutes.batchPlanning);
      expect(
        parsePlanningStartParam(opened?.queryParameters[kPlanningStartParam]),
        week.start,
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
