import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/data/planning_refusals_repository.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/planning_refusals.dart';

/// Mémoire des refus du planning, côté client.
///
/// Le client écrit le document et l'élague ; le serveur le lit et applique la
/// pénalité. La durée et le plafond d'entrées doivent être les mêmes des deux
/// côtés : ils viennent de `test-fixtures/planning_slot_rules.json`.
void main() {
  final file = File('test-fixtures/planning_slot_rules.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final constants = fixture['constants'] as Map<String, dynamic>;

  final now = DateTime.utc(2026, 10, 10, 12);
  DateTime daysAgo(num d) =>
      now.subtract(Duration(minutes: (d * 24 * 60).round()));

  group('constantes partagées avec le serveur', () {
    test('durée de la pénalité', () {
      expect(kRefusalPenaltyDays, constants['refusal_penalty_days']);
    });
    test('plafond d\'entrées', () {
      expect(kRefusalMaxEntries, constants['refusal_max_entries']);
    });
  });

  group('ce qui compte comme un refus', () {
    test('une recette proposée, oui', () {
      expect(countsAsRefusal(MealChoiceSource.ai), isTrue);
      expect(countsAsRefusal(MealChoiceSource.rules), isTrue);
      expect(countsAsRefusal(MealChoiceSource.concept), isTrue);
    });
    test('une recette choisie à la main ou d\'origine inconnue, non', () {
      expect(countsAsRefusal(MealChoiceSource.manual), isFalse);
      expect(countsAsRefusal(null), isFalse);
    });
  });

  group('activité d\'un refus', () {
    test('21 jours pile : actif ; au-delà : expiré', () {
      expect(
        PlanningRefusal(refusedAt: daysAgo(21), count: 1).isActiveAt(now),
        isTrue,
      );
      expect(
        PlanningRefusal(refusedAt: daysAgo(21.5), count: 1).isActiveAt(now),
        isFalse,
      );
    });
  });

  group('enregistrer des refus', () {
    test('un nouveau refus part à 1', () {
      final out = PlanningRefusals.empty.record(['a'], now);
      expect(out.entries['a']!.count, 1);
      expect(out.entries['a']!.refusedAt, now);
    });

    test('un refus encore actif augmente, et sa date avance', () {
      final out = PlanningRefusals({
        'a': PlanningRefusal(refusedAt: daysAgo(5), count: 2),
      }).record(['a'], now);
      expect(out.entries['a']!.count, 3);
      expect(out.entries['a']!.refusedAt, now);
    });

    test('un refus expiré repart à 1', () {
      final out = PlanningRefusals({
        'a': PlanningRefusal(refusedAt: daysAgo(30), count: 6),
      }).record(['a'], now);
      expect(out.entries['a']!.count, 1);
    });

    test('les entrées expirées sortent à l\'écriture', () {
      final out = PlanningRefusals({
        'old': PlanningRefusal(refusedAt: daysAgo(22), count: 1),
        'kept': PlanningRefusal(refusedAt: daysAgo(3), count: 1),
      }).record(['new'], now);
      expect(out.entries.keys.toSet(), {'kept', 'new'});
    });

    test('un identifiant en double ne compte qu\'une fois', () {
      final out = PlanningRefusals.empty.record(['a', 'a', ''], now);
      expect(out.entries.keys, ['a']);
      expect(out.entries['a']!.count, 1);
    });

    test('au plus 300 entrées : les plus anciennes sortent', () {
      final full = PlanningRefusals({
        for (var i = 0; i < kRefusalMaxEntries; i++)
          'r$i': PlanningRefusal(
            refusedAt: now.subtract(Duration(minutes: i + 1)),
            count: 1,
          ),
      });
      final out = full.record(['new'], now);
      expect(out.entries.length, kRefusalMaxEntries);
      expect(out.entries.containsKey('new'), isTrue);
      expect(out.entries.containsKey('r${kRefusalMaxEntries - 1}'), isFalse);
      expect(out.entries.containsKey('r0'), isTrue);
    });

    test('compte des refus actifs', () {
      final refusals = PlanningRefusals({
        'a': PlanningRefusal(refusedAt: daysAgo(2), count: 1),
        'b': PlanningRefusal(refusedAt: daysAgo(40), count: 1),
      });
      expect(refusals.activeCount(now), 1);
    });
  });

  group('lecture du document', () {
    test('absent ou mal formé : aucune entrée', () {
      expect(PlanningRefusals.fromFirestore(null).entries, isEmpty);
      expect(PlanningRefusals.fromFirestore({'entries': 'x'}).entries, isEmpty);
    });

    test('une entrée sans date est ignorée, un compte illisible vaut 1', () {
      final out = PlanningRefusals.fromFirestore({
        'entries': {
          'a': {'refused_at': Timestamp.fromDate(now), 'count': 'x'},
          'b': {'count': 2},
          'c': 'x',
        },
      });
      expect(out.entries.keys, ['a']);
      expect(out.entries['a']!.count, 1);
    });
  });

  group('repository', () {
    late FakeFirebaseFirestore firestore;
    late PlanningRefusalsRepository repo;
    var clock = now;

    DocumentReference<Map<String, dynamic>> doc(String uid) => firestore
        .collection('users')
        .doc(uid)
        .collection('preferences')
        .doc('planning_refusals');

    setUp(() {
      firestore = FakeFirebaseFirestore();
      clock = now;
      repo = PlanningRefusalsRepository(
        firestore: firestore,
        clock: () => clock,
      );
    });

    test('écrit sous le compte, jamais ailleurs', () async {
      expect(await repo.record('u1', ['a', 'b']), isTrue);
      final data = (await doc('u1').get()).data()!;
      expect((data['entries'] as Map).keys.toSet(), {'a', 'b'});
      expect((await doc('u2').get()).exists, isFalse);
      expect((await firestore.collection('recipes').get()).docs, isEmpty);
    });

    test('élague et incrémente à l\'écriture suivante', () async {
      await repo.record('u1', ['a', 'b']);
      clock = now.add(const Duration(days: 10));
      await repo.record('u1', ['a']);
      clock = now.add(const Duration(days: 25));
      await repo.record('u1', ['c']);
      final loaded = await repo.load('u1');
      // `b` (25 j) est sorti ; `a` (15 j) reste, avec ses deux refus.
      expect(loaded.entries.keys.toSet(), {'a', 'c'});
      expect(loaded.entries['a']!.count, 2);
      expect(loaded.activeCount(clock), 2);
    });

    test('rien à écrire : aucun document', () async {
      expect(await repo.record('u1', const []), isTrue);
      expect((await doc('u1').get()).exists, isFalse);
    });

    test('« Oublier mes refus » supprime le document', () async {
      await repo.record('u1', ['a']);
      await repo.clear('u1');
      expect((await doc('u1').get()).exists, isFalse);
      expect((await repo.load('u1')).entries, isEmpty);
    });
  });
}
