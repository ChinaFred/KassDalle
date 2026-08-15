import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planning_slot_rules.dart';

/// Règles de créneau du planning côté Dart.
///
/// Le serveur applique les mêmes règles pour composer le prompt et
/// dédoublonner la réponse du modèle ; le client les rejoue comme filet de
/// sécurité. Un écart ne casse aucun écran : il laisse passer un dessert d'un
/// côté, décale un jour de préparation de l'autre. Les cas viennent donc de
/// `test-fixtures/`, rejoués par les deux suites.
void main() {
  final file = File('test-fixtures/planning_slot_rules.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  List<Map<String, dynamic>> casesOf(String key) =>
      (fixture[key] as List).cast<Map<String, dynamic>>();

  group('demande explicite de sucré', () {
    final cases = casesOf('asks_for_dessert');

    test('la fixture partagée est non vide', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('« ${c['global']} » / « ${c['notes']} » (${c['why']})', () {
        expect(
          planningAsksForDessert(c['global'] as String, c['notes'] as String),
          c['expected'],
        );
      });
    }
  });

  group('recette sucrée', () {
    final cases = casesOf('is_dessert');

    test('la fixture partagée est non vide', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      final attributes = (c['attributes'] as List).cast<String>();
      test('${attributes.join(' · ')} (${c['why']})', () {
        expect(planningIsDessertBag(attributes), c['expected']);
      });
    }
  });

  group('nature du créneau', () {
    final cases = casesOf('slot_kind');

    test('la fixture partagée est non vide', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('jour ${c['slot_weekday']} (${c['why']})', () {
        expect(
          planningSlotKind(
            slotWeekday: c['slot_weekday'] as int,
            isReheatConstraint: c['is_reheat_constraint'] as bool,
            batchCookingDay: c['batch_cooking_day'] as int?,
          ),
          c['expected'],
        );
      });
    }
  });

  group('jour de préparation à l\'avance', () {
    final cases = casesOf('prep_date');

    test('la fixture partagée est non vide', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test(
        '${c['slot_date']} depuis le jour ${c['batch_weekday']} (${c['why']})',
        () {
          final slotDate = DateTime.parse(c['slot_date'] as String);
          final result = planningPrepDate(slotDate, c['batch_weekday'] as int);
          expect(_isoDay(result), c['expected']);
        },
      );
    }
  });
}

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
