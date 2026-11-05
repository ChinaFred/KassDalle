import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/domain/planning_target.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';

import 'support/test_backend.dart';

/// Parts d'un repas de groupe : les « Parts à préparer » du jour si elles
/// sont réglées, sinon les parts du groupe (« Parts des groupes », sinon une
/// part par membre). Le planning personnel ne passe pas par là.
void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  FamilyGroup familyGroup({
    String owner = 'moi',
    List<String> members = const ['moi', 'marie', 'paul'],
  }) => FamilyGroup(
    id: 'g1',
    name: 'La maison',
    ownerId: owner,
    memberIds: members,
    createdAt: DateTime.utc(2026),
  );

  group('groupMealPortions', () {
    test('un jour réglé garde ses parts', () {
      expect(
        groupMealPortions(
          dayConstraint: const DayConstraint(targetPortions: 8),
          groupPortions: const {'g1': 6},
          group: familyGroup(),
        ),
        8,
      );
    });

    test('un jour sans parts prend celles réglées pour le groupe', () {
      expect(
        groupMealPortions(
          dayConstraint: const DayConstraint(targetPortions: 0),
          groupPortions: const {'g1': 6},
          group: familyGroup(),
        ),
        6,
      );
      // Un jour sans contrainte du tout vaut un jour à 0.
      expect(
        groupMealPortions(
          dayConstraint: null,
          groupPortions: const {'g1': 6},
          group: familyGroup(),
        ),
        6,
      );
    });

    test(
      'sans réglage : une part par membre, propriétaire compté une fois',
      () {
        // Le propriétaire figure dans la liste des membres : 3 parts, pas 4.
        expect(
          groupMealPortions(
            dayConstraint: const DayConstraint(),
            groupPortions: const {},
            group: familyGroup(),
          ),
          3,
        );
        // Le propriétaire manque à la liste : il compte quand même.
        expect(
          groupMealPortions(
            dayConstraint: null,
            groupPortions: const {},
            group: familyGroup(members: const ['marie', 'paul']),
          ),
          3,
        );
        // Le réglage d'un autre groupe ne compte pas.
        expect(
          groupMealPortions(
            dayConstraint: null,
            groupPortions: const {'g2': 9},
            group: familyGroup(),
          ),
          3,
        );
      },
    );
  });

  group('« Nouveau planning » d\'un groupe', () {
    testWidgets('chaque créneau prend les parts du jour, sinon celles du '
        'groupe', (tester) async {
      final user = testUser();
      final backend = TestBackend(
        user: user,
        groups: [
          FamilyGroup(
            id: 'g1',
            name: 'La maison',
            ownerId: user.uid,
            memberIds: const ['a', 'b', 'c'],
            createdAt: DateTime.utc(2026),
          ),
        ],
      );
      // Grand écran, assez haut pour que les sept créneaux soient construits.
      const size = Size(1600, 1400);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          retry: appProviderRetry,
          overrides: [
            ...backend.overrides,
            planningPreferencesOnceProvider.overrideWith(
              (ref) async => const PlanningPreferences(
                cycleStartDay: DateTime.friday,
                mealsPerCycle: 7,
                dailyConstraints: {
                  DateTime.friday: DayConstraint(targetPortions: 8),
                },
                groupPortions: {'g1': 6},
              ),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('fr'),
            home: BatchPlanningScreen(groupId: 'g1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Nouveau planning — La maison'), findsOneWidget);
      final tiles = tester
          .widgetList<BatchSlotTile>(find.byType(BatchSlotTile))
          .toList();
      expect(tiles, hasLength(7));
      for (final tile in tiles) {
        // Vendredi : les 8 parts réglées pour ce jour ; les autres jours :
        // les 6 parts réglées pour le groupe, jamais ses 4 membres.
        expect(
          tile.dayConstraint.targetPortions,
          tile.date.weekday == DateTime.friday ? 8 : 6,
          reason: 'créneau ${tile.index} (${tile.date})',
        );
      }
      expect(find.text('8 parts'), findsWidgets);
      expect(find.text('6 parts'), findsWidgets);
      expect(find.text('4 parts'), findsNothing);
    });
  });
}
