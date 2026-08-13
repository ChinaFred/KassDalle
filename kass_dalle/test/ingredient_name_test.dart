import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/ingredient_name.dart';

/// Tests de la normalisation des noms d'ingrédients côté Dart.
///
/// Les identifiants produits ici servent à retrouver les mêmes documents
/// `nutrition_ingredients` que côté backend : les cas viennent donc de
/// `test-fixtures/`, rejoués par les deux suites.
void main() {
  final file = File('test-fixtures/ingredient_names.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('la fixture partagée est non vide', () {
    expect(cases, isNotEmpty);
  });

  for (final c in cases) {
    final input = c['input'] as String;
    final why = c['why'] as String;

    group('« $input »  ($why)', () {
      test('identifiant strict', () {
        expect(normalizeIngredientStrictId(input), c['strict']);
      });

      test('identifiant canonique', () {
        expect(normalizeIngredientCanonicalId(input), c['canonical']);
      });

      test('identifiant singularisé', () {
        expect(normalizeIngredientSingularId(input), c['singular']);
      });

      test('identifiants de recherche', () {
        expect(
          buildIngredientLookupIds(input),
          (c['lookup'] as List).cast<String>(),
        );
      });
    });
  }

  group('propriétés hors fixture', () {
    test('les accents décomposés sont traités comme les précomposés', () {
      // « é » précomposé (U+00E9) vs « e » + accent combinant (U+0065 U+0301).
      expect(
        normalizeIngredientStrictId('crème'),
        normalizeIngredientStrictId('crème'),
      );
    });

    test('la normalisation est idempotente', () {
      const raw = 'Persil Haché Finement';
      final once = normalizeIngredientStrictId(raw);
      expect(normalizeIngredientStrictId(once), once);
    });

    test('stripAccentsPreservingWords garde les espaces', () {
      expect(
        stripAccentsPreservingWords('crème fraîche'),
        'crème fraîche'.replaceAll('è', 'e').replaceAll('î', 'i'),
      );
    });
  });
}
