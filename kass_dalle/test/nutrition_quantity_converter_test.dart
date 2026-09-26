import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/nutrition_quantity_converter.dart';

/// Tests du convertisseur de quantités côté Dart.
///
/// Les cas nominaux viennent de `test-fixtures/`, partagés avec la suite
/// TypeScript des Cloud Functions (`functions/src/tests/`). Les deux
/// implémentations sont des portages l'une de l'autre : ce fichier partagé est
/// le seul mécanisme qui détecte leur divergence.
Map<String, dynamic> _loadFixture(String name) {
  final file = File('test-fixtures/$name');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void main() {
  group('parseQuantity — cas partagés Dart/TypeScript', () {
    final fixture = _loadFixture('quantity_parsing.json');
    final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

    test('la fixture partagée est non vide', () {
      expect(cases, isNotEmpty);
    });

    for (final c in cases) {
      final input = c['input'] as String;
      final expected = (c['expected'] as num?)?.toDouble();
      final why = c['why'] as String;

      test('« $input » → ${expected ?? 'null'}  ($why)', () {
        final actual = NutritionQuantityConverter.parseQuantity(input);
        if (expected == null) {
          expect(actual, isNull);
        } else {
          expect(actual, isNotNull);
          expect(actual!, closeTo(expected, 1e-9));
        }
      });
    }
  });

  group('toGrams — cas partagés Dart/TypeScript', () {
    final fixture = _loadFixture('unit_to_grams.json');
    final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

    for (final c in cases) {
      final ingredient = c['ingredient'] as String;
      final qty = c['qty'] as String;
      final unit = c['unit'] as String;
      final expected = (c['grams'] as num?)?.toDouble();
      final why = c['why'] as String;

      test('$qty $unit de $ingredient → ${expected ?? 'null'} g  ($why)', () {
        final actual = NutritionQuantityConverter.toGrams(
          ingredientName: ingredient,
          qty: qty,
          unit: unit,
        );
        if (expected == null) {
          expect(actual, isNull);
        } else {
          expect(actual, isNotNull);
          expect(actual!, closeTo(expected, 1e-6));
        }
      });
    }
  });

  group('resolveUnitFactorToGrams — cas partagés Dart/TypeScript', () {
    final fixture = _loadFixture('unit_to_grams.json');
    final cases = (fixture['referential'] as List).cast<Map<String, dynamic>>();

    for (final c in cases) {
      final ingredient = c['ingredient'] as String;
      final qty = c['qty'] as String;
      final unit = c['unit'] as String;
      final rawOverride = c['override'] as Map<String, dynamic>?;
      final rawIngredientOverride =
          c['ingredientOverride'] as Map<String, dynamic>?;
      final expected = (c['grams'] as num?)?.toDouble();
      final why = c['why'] as String;
      final label = rawOverride == null
          ? 'sans référentiel'
          : 'avec référentiel';

      test(
        '$qty $unit de $ingredient, $label → ${expected ?? 'null'} g  ($why)',
        () {
          final override = rawOverride == null
              ? null
              : ReferentialUnitOverride(
                  measurementType: rawOverride['measurementType'] as String?,
                  gramsPerUnit: (rawOverride['gramsPerUnit'] as num?)
                      ?.toDouble(),
                  volumeMlPerUnit: (rawOverride['volumeMlPerUnit'] as num?)
                      ?.toDouble(),
                );
          final ingredientOverride = rawIngredientOverride == null
              ? null
              : IngredientWeightOverride(
                  gramsPerPiece:
                      (rawIngredientOverride['gramsPerPiece'] as num?)
                          ?.toDouble(),
                  gramsPerUnit:
                      ((rawIngredientOverride['gramsPerUnit']
                                  as Map<String, dynamic>?) ??
                              const {})
                          .map(
                            (key, value) =>
                                MapEntry(key, (value as num).toDouble()),
                          ),
                );
          final actual = NutritionQuantityConverter.toGrams(
            ingredientName: ingredient,
            qty: qty,
            unit: unit,
            override: override,
            ingredientOverride: ingredientOverride,
          );
          if (expected == null) {
            expect(actual, isNull);
          } else {
            expect(actual, isNotNull);
            expect(actual!, closeTo(expected, 1e-6));
          }
        },
      );
    }
  });

  group('portion usuelle — cas partagés Dart/TypeScript', () {
    final fixture = _loadFixture('unit_to_grams.json');
    final cases = (fixture['usual_portion'] as List)
        .cast<Map<String, dynamic>>();

    test('la section usual_portion de la fixture n\'est pas vide', () {
      expect(cases, isNotEmpty);
    });

    for (final c in cases) {
      final ingredient = c['ingredient'] as String;
      final qty = c['qty'] as String;
      final unit = c['unit'] as String;
      final portion = (c['usualPortionGrams'] as num?)?.toDouble();
      final expected = (c['grams'] as num?)?.toDouble();
      final why = c['why'] as String;

      test('$qty $unit de $ingredient, portion ${portion ?? 'absente'} → '
          '${expected ?? 'null'} g  ($why)', () {
        final actual = NutritionQuantityConverter.toGrams(
          ingredientName: ingredient,
          qty: qty,
          unit: unit,
          ingredientOverride: IngredientWeightOverride(
            usualPortionGrams: portion,
          ),
        );
        if (expected == null) {
          expect(actual, isNull);
        } else {
          expect(actual, isNotNull);
          expect(actual!, closeTo(expected, 1e-6));
        }
      });
    }
  });

  group('toGrams — divergences connues avec le référentiel TypeScript', () {
    final fixture = _loadFixture('unit_to_grams.json');
    final divergences = (fixture['divergences'] as List)
        .cast<Map<String, dynamic>>();

    for (final d in divergences) {
      final ingredient = d['ingredient'] as String;
      final qty = d['qty'] as String;
      final unit = d['unit'] as String;
      final dartExpected = (d['dart'] as num?)?.toDouble();
      final tsExpected = (d['ts'] as num?)?.toDouble();

      test('ÉCART — $qty $unit de $ingredient : Dart=${dartExpected ?? 'null'} '
          'vs TS=${tsExpected ?? 'null'}', () {
        final actual = NutritionQuantityConverter.toGrams(
          ingredientName: ingredient,
          qty: qty,
          unit: unit,
        );
        if (dartExpected == null) {
          expect(
            actual,
            isNull,
            reason:
                'Si ce test échoue, c\'est que Dart connaît désormais cette '
                'unité : retirer l\'entrée de `divergences` et l\'ajouter à '
                '`cases` dans test-fixtures/unit_to_grams.json.',
          );
        } else {
          expect(actual, closeTo(dartExpected, 1e-6));
        }
      });
    }
  });

  group('parseQuantity — propriétés hors fixture', () {
    test('accepte les grandes valeurs sans perte', () {
      expect(NutritionQuantityConverter.parseQuantity('10000'), 10000);
    });

    test('deux fractions Unicode dans la même chaîne s\'additionnent', () {
      // Comportement actuel, documenté ici pour qu'un changement soit conscient.
      expect(
        NutritionQuantityConverter.parseQuantity('½¼'),
        closeTo(0.75, 1e-9),
      );
    });
  });

  group('toGrams — sensibilité au nom de l\'ingrédient', () {
    test('la densité dépend du nom, pas seulement de l\'unité', () {
      final huile = NutritionQuantityConverter.toGrams(
        ingredientName: 'huile de tournesol',
        qty: '100',
        unit: 'ml',
      );
      final eau = NutritionQuantityConverter.toGrams(
        ingredientName: 'eau',
        qty: '100',
        unit: 'ml',
      );
      expect(huile, closeTo(92, 1e-6));
      expect(eau, closeTo(100, 1e-6));
    });

    test('les accents et majuscules du nom sont normalisés', () {
      final avec = NutritionQuantityConverter.toGrams(
        ingredientName: "Huile d'Olive Extra",
        qty: '1',
        unit: 'cs',
      );
      final sans = NutritionQuantityConverter.toGrams(
        ingredientName: 'huile',
        qty: '1',
        unit: 'cs',
      );
      expect(avec, sans);
    });

    test('un ingrédient inconnu en volume garde la densité 1', () {
      expect(
        NutritionQuantityConverter.toGrams(
          ingredientName: 'substance mystérieuse',
          qty: '200',
          unit: 'ml',
        ),
        closeTo(200, 1e-6),
      );
    });
  });
}
