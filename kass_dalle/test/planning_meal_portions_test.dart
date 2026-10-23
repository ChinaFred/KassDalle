import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/presentation/planning_config_screen.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';

import 'support/test_backend.dart';

/// « Changer les parts » : menu ⋮ d'un repas planifié. Seul le repas reçoit
/// `target_portions` ; la recette n'est pas écrite.
void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  Future<TestBackend> pumpPlanning(
    WidgetTester tester, {
    int? basePortions,
    int? targetPortions,
  }) async {
    final backend = TestBackend(planningWrites: true);
    final now = DateTime.now();
    await backend.firestore
        .collection('planned_meals')
        .doc('m1')
        .set(
          PlannedMeal(
            id: 'm1',
            uid: backend.user.uid,
            recipeTitre: 'Friterie',
            plannedAt: DateTime(now.year, now.month, now.day, 19),
            durationMinutes: 45,
            basePortions: basePortions,
            targetPortions: targetPortions,
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
        ],
        child: const MaterialApp(locale: Locale('fr'), home: PlanningScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return backend;
  }

  Future<Map<String, dynamic>> stored(TestBackend backend) async =>
      (await backend.firestore.collection('planned_meals').doc('m1').get())
          .data()!;

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Changer les parts'));
    await tester.pumpAndSettle();
  }

  testWidgets('les parts saisies sont écrites sur le repas', (tester) async {
    final backend = await pumpPlanning(
      tester,
      basePortions: 4,
      targetPortions: 4,
    );
    await openDialog(tester);
    expect(find.text('Nombre de portions'), findsOneWidget);
    expect(find.widgetWithText(TextField, '4'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '6');
    await tester.tap(find.widgetWithText(FilledButton, 'Valider'));
    await tester.pumpAndSettle();

    final data = await stored(backend);
    expect(data['target_portions'], 6);
    expect(data['base_portions'], 4);
    expect(find.textContaining('6 parts'), findsOneWidget);
  });

  testWidgets('« Annuler » ne change rien', (tester) async {
    final backend = await pumpPlanning(
      tester,
      basePortions: 4,
      targetPortions: 4,
    );
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), '6');
    await tester.tap(find.widgetWithText(TextButton, 'Annuler'));
    await tester.pumpAndSettle();
    expect((await stored(backend))['target_portions'], 4);
  });

  testWidgets('une saisie hors bornes est refusée', (tester) async {
    final backend = await pumpPlanning(tester);
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Valider'));
    await tester.pumpAndSettle();
    expect(
      find.text('Le nombre de portions doit être entre 1 et 99.'),
      findsOneWidget,
    );
    expect((await stored(backend)).containsKey('target_portions'), isFalse);
  });

  group('Préférences : « Parts des groupes »', () {
    Future<TestBackend> pumpConfig(
      WidgetTester tester, {
      Map<String, int> groupPortions = const {},
    }) async {
      final user = testUser();
      final backend = TestBackend(
        user: user,
        planningWrites: true,
        groups: [
          FamilyGroup(
            id: 'g1',
            name: 'La maison',
            ownerId: user.uid,
            memberIds: const ['a', 'b'],
            createdAt: DateTime.utc(2026),
          ),
        ],
      );
      if (groupPortions.isNotEmpty) {
        await backend.firestore.collection('planning_config').doc(user.uid).set(
          {'group_portions': groupPortions},
        );
      }
      const size = Size(420, 1400);
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
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PlanningConfigScreen(),
                  ),
                ),
                child: const Text('Ouvrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();
      return backend;
    }

    Future<Map<String, dynamic>> config(TestBackend backend) async =>
        (await backend.firestore
                .collection('planning_config')
                .doc(backend.user.uid)
                .get())
            .data() ??
        const {};

    Finder field() => find.byKey(const ValueKey('group-portions-g1'));

    testWidgets('vide : une part par membre, et la saisie est enregistrée', (
      tester,
    ) async {
      final backend = await pumpConfig(tester);
      expect(find.text('Parts des groupes'), findsOneWidget);
      expect(find.text('3 (une par membre)'), findsOneWidget);
      await tester.enterText(field(), '6');
      await tester.tap(find.widgetWithText(TextButton, 'Enregistrer'));
      await tester.pumpAndSettle();
      expect((await config(backend))['group_portions'], {'g1': 6});
    });

    testWidgets('vider le champ retire la valeur enregistrée', (tester) async {
      final backend = await pumpConfig(tester, groupPortions: {'g1': 6});
      expect(find.widgetWithText(TextFormField, '6'), findsOneWidget);
      await tester.enterText(field(), '');
      await tester.tap(find.widgetWithText(TextButton, 'Enregistrer'));
      await tester.pumpAndSettle();
      final portions = (await config(backend))['group_portions'] as Map?;
      expect(portions?.containsKey('g1') ?? false, isFalse);
    });
  });
}
