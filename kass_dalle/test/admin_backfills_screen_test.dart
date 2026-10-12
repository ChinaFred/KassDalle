import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/backfill_status.dart';
import 'package:kass_dalle/features/admin/presentation/admin_backfills_screen.dart';
import 'package:kass_dalle/features/admin/presentation/billing_providers.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Map<String, BackfillRunState> runs,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backfillRunsProvider.overrideWith((ref) => Stream.value(runs)),
        backfillSchedulesProvider.overrideWith(
          (ref) => Stream.value(
            const BackfillSchedules({
              'nutrition': {
                'enabled': true,
                'days': [1, 2, 3, 4, 5, 6, 7],
                'hour': 5,
              },
            }),
          ),
        ),
      ],
      child: const MaterialApp(home: AdminBackfillsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  final runs = {
    'estimated_times': BackfillRunState.fromMap('estimated_times', {
      'termine_le': DateTime.utc(2026, 10, 10, 10),
      'termine_version': '0.23.30',
      'termine_par': 'auto',
      'dernier_passage_statut': 'termine',
      'dernier_passage_le': DateTime.utc(2026, 10, 10, 10),
    }),
  };

  testWidgets('téléphone : trois sections, nutrition programmée par défaut', (
    tester,
  ) async {
    await _pump(tester, size: const Size(400, 3000), runs: runs);
    expect(find.text('Récurrents (5)'), findsOneWidget);
    expect(find.text('Ponctuels à lancer (4)'), findsOneWidget);
    expect(find.text('Ponctuels terminés (1)'), findsOneWidget);
    expect(
      find.text('Programmation : Tous les jours à 5 h'),
      findsOneWidget,
      reason: 'le défaut semé par le serveur est lu tel quel',
    );
    expect(find.text('Relancer quand même'), findsOneWidget);
    expect(
      find.textContaining('Dernier passage — terminé'),
      findsOneWidget,
      reason: 'tuile terminée : la seconde ligne dit de quoi elle parle',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('large : deux colonnes sans débordement', (tester) async {
    await _pump(tester, size: const Size(1200, 2400), runs: runs);
    expect(find.text('Programmer'), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'avant le premier passage horaire : défaut de la nutrition affiché',
    (tester) async {
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backfillRunsProvider.overrideWith(
              (ref) => Stream.value(const <String, BackfillRunState>{}),
            ),
            backfillSchedulesProvider.overrideWith(
              (ref) => Stream.value(BackfillSchedules.empty),
            ),
          ],
          child: const MaterialApp(home: AdminBackfillsScreen()),
        ),
      );
      await tester.pump();
      expect(
        find.text('Programmation : Tous les jours à 5 h (par défaut)'),
        findsOneWidget,
      );
      expect(find.text('Programmation : Non programmé'), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chargement : tuiles neutres, ponctuels non rangés', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backfillRunsProvider.overrideWith(
            (ref) => const Stream<Map<String, BackfillRunState>>.empty(),
          ),
          backfillSchedulesProvider.overrideWith(
            (ref) => const Stream<BackfillSchedules>.empty(),
          ),
        ],
        child: const MaterialApp(home: AdminBackfillsScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Ponctuels'), findsOneWidget);
    expect(find.textContaining('Ponctuels à lancer'), findsNothing);
    expect(find.text('État inconnu'), findsNothing);
    expect(find.text('Programmation : …'), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });
}
