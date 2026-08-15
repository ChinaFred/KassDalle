import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_storage_rules.dart';

/// Règles de conservation d'un plat préparé à l'avance, côté Dart.
///
/// Le client les applique pour afficher la consigne dans le planning, le
/// serveur pour cadrer le prompt de conservation. Un écart ne lève aucune
/// erreur : il fait dire à l'un qu'un plat tient au réfrigérateur quand
/// l'autre le fait congeler. Les cas viennent donc de `test-fixtures/`.
void main() {
  final file = File('test-fixtures/meal_storage_rules.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('la limite du réfrigérateur est la même des deux côtés', () {
    expect(kMaxFridgeDays, fixture['max_fridge_days']);
  });

  group('mode de conservation', () {
    final cases = (fixture['modes'] as List).cast<Map<String, dynamic>>();

    test('la fixture partagée est non vide', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('${c['days_ahead']} jours d\'avance (${c['why']})', () {
        expect(mealStorageMode(c['days_ahead'] as int).name, c['expected']);
      });
    }
  });

  group('délai entre préparation et repas', () {
    final cases = (fixture['days_ahead'] as List).cast<Map<String, dynamic>>();

    test('la fixture partagée est non vide', () => expect(cases, isNotEmpty));

    for (final c in cases) {
      test('${c['prep_date']} → ${c['meal_date']} (${c['why']})', () {
        expect(
          mealStorageDaysAhead(
            prepDate: DateTime.parse(c['prep_date'] as String),
            mealDate: DateTime.parse(c['meal_date'] as String),
          ),
          c['expected'],
        );
      });
    }
  });

  group('consigne affichée', () {
    test('le jour même ne parle ni de froid ni de congélation', () {
      final text = mealStorageInstruction(0).toLowerCase();
      expect(text, isNot(contains('réfrigérateur')));
      expect(text, isNot(contains('congeler')));
    });

    test('trois jours d\'avance renvoient au réfrigérateur', () {
      expect(mealStorageInstruction(3), contains('réfrigérateur'));
    });

    test('au-delà, la consigne dit de congeler et pourquoi', () {
      final text = mealStorageInstruction(6);
      expect(text, contains('congeler'));
      expect(text, contains('$kMaxFridgeDays jours'));
    });
  });
}
