import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/backfill_registry.dart';
import 'package:kass_dalle/features/admin/domain/backfill_status.dart';
import 'package:kass_dalle/features/admin/domain/move_meals_request.dart';
import 'package:kass_dalle/features/admin/presentation/move_meals_to_group_dialog.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';

FamilyGroup _group(String id, String name, String owner) => FamilyGroup(
  id: id,
  name: name,
  ownerId: owner,
  memberIds: [owner],
  createdAt: DateTime(2030, 1, 1),
);

void main() {
  group('demande', () {
    final request = MoveMealsRequest(
      groupId: 'g1',
      groupName: 'Groupe A',
      from: DateTime(2030, 3, 1, 15),
      to: DateTime(2030, 3, 7, 9),
    );

    test('jours inclusifs, bornes à minuit local', () {
      expect(request.fromDay, '2030-03-01');
      expect(request.toDay, '2030-03-07');
      expect(request.dayCount, 7);
      expect(request.startAt, DateTime(2030, 3, 1).millisecondsSinceEpoch);
      expect(request.endAt, DateTime(2030, 3, 8).millisecondsSinceEpoch);
      expect(request.toPayload(), {
        'groupId': 'g1',
        'fromDay': '2030-03-01',
        'toDay': '2030-03-07',
        'startAt': request.startAt,
        'endAt': request.endAt,
      });
    });

    test('fin de mois : le lendemain passe au mois suivant', () {
      final r = MoveMealsRequest(
        groupId: 'g',
        groupName: 'G',
        from: DateTime(2030, 12, 31),
        to: DateTime(2030, 12, 31),
      );
      expect(r.endAt, DateTime(2031, 1, 1).millisecondsSinceEpoch);
      expect(r.dayCount, 1);
    });

    test('62 jours au plus', () {
      final from = DateTime(2030, 1, 1);
      MoveMealsRequest of(int days) => MoveMealsRequest(
        groupId: 'g',
        groupName: 'G',
        from: from,
        to: DateTime(2030, 1, days),
      );
      expect(of(62).isValid, isTrue);
      expect(of(63).isValid, isFalse);
    });

    test('question de confirmation', () {
      expect(
        request.confirmQuestion,
        'Déplacer vos repas du ven. 1er au jeu. 7 mars vers « Groupe A » ?',
      );
    });
  });

  group('période courte', () {
    test('même mois, mois différents, années différentes, un seul jour', () {
      expect(
        formatShortPeriod(DateTime(2030, 3, 8), DateTime(2030, 3, 14)),
        'du ven. 8 au jeu. 14 mars',
      );
      expect(
        formatShortPeriod(DateTime(2030, 9, 30), DateTime(2030, 10, 3)),
        'du lun. 30 sept. au jeu. 3 oct.',
      );
      expect(
        formatShortPeriod(DateTime(2030, 12, 31), DateTime(2031, 1, 1)),
        'du mar. 31 déc. 2030 au mer. 1er janv. 2031',
      );
      expect(
        formatShortPeriod(DateTime(2030, 3, 8), DateTime(2030, 3, 8)),
        'du ven. 8 mars',
      );
    });
  });

  test('groupes proposés : les miens, actifs, triés par nom', () {
    final groups = [
      _group('b', 'Zèbre', 'me'),
      _group('a', 'abri', 'me'),
      _group('c', 'Autre', 'someone'),
      _group('d', 'En pause', 'me'),
    ];
    expect(ownedActiveGroups(groups, {'d'}, 'me').map((g) => g.id), ['a', 'b']);
  });

  test('registre et résumé de la tuile', () {
    final def = backfillDefinition(BackfillKeys.moveMealsToGroup)!;
    expect(def.kind, BackfillKind.ponctuel);
    expect(def.usesAi, isFalse);
    expect(def.defaultSchedule, isNull);
    expect(
      backfillReportSummary(BackfillKeys.moveMealsToGroup, {
        'deplaces': 12,
        'echoues': 0,
        'du': '2030-03-01',
        'au': '2030-03-07',
      }),
      '12 repas déplacés (2030-03-01 → 2030-03-07), 0 échec',
    );
  });

  group('boîte de paramètres', () {
    /// Ouvre la boîte ; ce qu'elle rend à sa fermeture s'ajoute à [results].
    Future<void> pump(
      WidgetTester tester, {
      required List<FamilyGroup> groups,
      Set<String> paused = const {},
      DateTimeRange? range,
      List<MoveMealsRequest?>? results,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUserProvider.overrideWith(
              (ref) => Stream.value(
                AppUser(
                  uid: 'me',
                  email: 'me@example.com',
                  displayName: 'Moi',
                  role: UserRole.admin,
                  createdAt: DateTime(2030, 1, 1),
                  lastSeenAt: DateTime(2030, 1, 1),
                ),
              ),
            ),
            myGroupsProvider.overrideWith((ref) => Stream.value(groups)),
            maskedGroupIdsProvider.overrideWith((ref) => Stream.value(paused)),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  final r = await showDialog<MoveMealsRequest>(
                    context: context,
                    builder: (_) => MoveMealsToGroupDialog(initialRange: range),
                  );
                  results?.add(r);
                },
                child: const Text('ouvrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
    }

    FilledButton continueButton(WidgetTester tester) => tester.widget(
      find.ancestor(
        of: find.text('Continuer'),
        matching: find.byType(FilledButton),
      ),
    );

    testWidgets('sans groupe à soi : état vide, Continuer désactivé', (
      tester,
    ) async {
      await pump(
        tester,
        groups: [_group('x', 'Groupe d\'un autre', 'someone')],
      );
      expect(find.text('Aucun groupe à vous'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);
    });

    testWidgets('groupe et période choisis : la demande est rendue', (
      tester,
    ) async {
      final results = <MoveMealsRequest?>[];
      await pump(
        tester,
        groups: [
          _group('g1', 'Groupe A', 'me'),
          _group('g2', 'Groupe en pause', 'me'),
          _group('g3', 'Groupe d\'un autre', 'someone'),
        ],
        paused: {'g2'},
        results: results,
        range: DateTimeRange(
          start: DateTime(2030, 3, 1),
          end: DateTime(2030, 3, 7),
        ),
      );
      expect(find.text('du ven. 1er au jeu. 7 mars'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull, reason: 'aucun groupe');

      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      expect(find.text('Groupe en pause'), findsNothing);
      expect(find.text('Groupe d\'un autre'), findsNothing);
      await tester.tap(find.text('Groupe A').last);
      await tester.pumpAndSettle();

      expect(continueButton(tester).onPressed, isNotNull);
      await tester.tap(find.text('Continuer'));
      await tester.pumpAndSettle();
      expect(find.byType(MoveMealsToGroupDialog), findsNothing);
      final request = results.single!;
      expect(request.groupId, 'g1');
      expect(request.fromDay, '2030-03-01');
      expect(request.toDay, '2030-03-07');
      expect(
        request.confirmQuestion,
        'Déplacer vos repas du ven. 1er au jeu. 7 mars vers « Groupe A » ?',
      );
    });

    testWidgets('période trop longue : message, Continuer désactivé', (
      tester,
    ) async {
      await pump(
        tester,
        groups: [_group('g1', 'Groupe A', 'me')],
        range: DateTimeRange(
          start: DateTime(2030, 1, 1),
          end: DateTime(2030, 3, 31),
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Groupe A').last);
      await tester.pumpAndSettle();
      expect(find.text('62 jours au plus.'), findsOneWidget);
      expect(continueButton(tester).onPressed, isNull);
    });
  });
}
