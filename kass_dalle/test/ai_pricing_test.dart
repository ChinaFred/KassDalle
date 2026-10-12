import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_pricing.dart';

/// Tarification Gemini côté Dart.
///
/// La table de prix existe en double, ici et dans
/// `functions/src/gemini/pricing.ts`. Un écart entre les deux ne casse rien de
/// visible : il fait juste mentir le reporting de coûts. Les cas viennent de
/// `test-fixtures/ai_pricing.json`, rejoués par les deux suites.
void main() {
  final file = File('test-fixtures/ai_pricing.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  final table = (fixture['table'] as List).cast<Map<String, dynamic>>();
  final defaults = fixture['default'] as Map<String, dynamic>;

  /// La grille de la fixture, telle que le serveur l'ecrit dans Firestore.
  ///
  /// Le client ne porte plus de prix : il applique ces regles a la table qu'il
  /// recoit. La fixture joue donc ici le role de la grille en vigueur.
  final pricingTable = <String, AiModelPricing>{
    for (final row in table)
      row['model'] as String: AiModelPricing(
        inputPerMillion: (row['inputPerMillion'] as num).toDouble(),
        outputPerMillion: (row['outputPerMillion'] as num).toDouble(),
        imageOutputPerUnit: (row['imageOutputPerUnit'] as num).toDouble(),
        analyzedImagePerUnit: ((row['analyzedImagePerUnit'] as num?) ?? 0)
            .toDouble(),
        freeUnitsPerMonth: ((row['freeUnitsPerMonth'] as num?) ?? 0).toInt(),
        groundedSearchPerUnit: ((row['groundedSearchPerUnit'] as num?) ?? 0)
            .toDouble(),
        introductory: row['introductory'] == null
            ? null
            : AiIntroductoryPricing(
                inputPerMillion:
                    ((row['introductory'] as Map)['inputPerMillion'] as num)
                        .toDouble(),
                outputPerMillion:
                    ((row['introductory'] as Map)['outputPerMillion'] as num)
                        .toDouble(),
                untilIso: (row['introductory'] as Map)['until'] as String,
              ),
      ),
  };

  group('table des tarifs', () {
    for (final row in table) {
      final model = row['model'] as String;
      test('« $model » porte les prix de la fixture', () {
        final pricing = AiPricing.forModelIn(pricingTable, model);
        expect(
          pricing.inputPerMillion,
          (row['inputPerMillion'] as num).toDouble(),
          reason: 'entrée',
        );
        expect(
          pricing.outputPerMillion,
          (row['outputPerMillion'] as num).toDouble(),
          reason: 'sortie',
        );
        expect(
          pricing.imageOutputPerUnit,
          (row['imageOutputPerUnit'] as num).toDouble(),
          reason: 'image',
        );
        expect(
          pricing.groundedSearchPerUnit,
          ((row['groundedSearchPerUnit'] as num?) ?? 0).toDouble(),
          reason: 'recherche Google',
        );
      });
    }
  });

  group('promotion déclarée dans la table', () {
    for (final row in table) {
      final model = row['model'] as String;
      final promo = row['introductory'] as Map<String, dynamic>?;
      test(
        '« $model » ${promo == null ? 'sans promotion' : 'avec promotion'}',
        () {
          final actual = AiPricing.forModelIn(pricingTable, model).introductory;
          if (promo == null) {
            expect(actual, isNull);
            return;
          }
          expect(actual, isNotNull);
          expect(
            actual!.inputPerMillion,
            (promo['inputPerMillion'] as num).toDouble(),
          );
          expect(
            actual.outputPerMillion,
            (promo['outputPerMillion'] as num).toDouble(),
          );
          expect(actual.untilIso, promo['until'] as String);
        },
      );
    }
  });

  group('tarif en vigueur à une date', () {
    final cases = (fixture['effective'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      test('${c['model']} au ${c['at']}  (${c['why']})', () {
        final actual = AiPricing.effectiveFor(
          c['model'] as String,
          at: DateTime.parse(c['at'] as String),
          table: pricingTable,
        );
        expect(
          actual.inputPerMillion,
          (c['inputPerMillion'] as num).toDouble(),
          reason: 'entrée',
        );
        expect(
          actual.outputPerMillion,
          (c['outputPerMillion'] as num).toDouble(),
          reason: 'sortie',
        );
      });
    }
  });

  group('résolution du modèle', () {
    final cases = (fixture['resolution'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final model = c['model'] as String;
      final expected = c['expect'] as String?;
      test('« $model » → ${expected ?? '(défaut)'}  (${c['why']})', () {
        final actual = AiPricing.forModelIn(pricingTable, model);
        if (expected == null) {
          expect(
            actual.inputPerMillion,
            (defaults['inputPerMillion'] as num).toDouble(),
          );
          expect(
            actual.outputPerMillion,
            (defaults['outputPerMillion'] as num).toDouble(),
          );
          expect(
            actual.imageOutputPerUnit,
            (defaults['imageOutputPerUnit'] as num).toDouble(),
          );
          return;
        }
        final row = table.firstWhere((r) => r['model'] == expected);
        expect(
          actual.inputPerMillion,
          (row['inputPerMillion'] as num).toDouble(),
          reason: 'entrée',
        );
        expect(
          actual.outputPerMillion,
          (row['outputPerMillion'] as num).toDouble(),
          reason: 'sortie',
        );
        expect(
          actual.imageOutputPerUnit,
          (row['imageOutputPerUnit'] as num).toDouble(),
          reason: 'image',
        );
      });
    }
  });

  group('coût en USD', () {
    final cases = (fixture['cost'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      // Jetons de cache facultatifs : absents, ils valent zéro. Ce sont des
      // jetons de prompt comptés EN PLUS de l'entrée, et facturés à un autre
      // tarif — les ignorer ne lève rien, cela retire seulement du coût.
      final cacheWrite = (c['cacheCreationInputTokens'] as int?) ?? 0;
      final cacheRead = (c['cacheReadInputTokens'] as int?) ?? 0;
      final cacheLabel = cacheWrite > 0 || cacheRead > 0
          ? ' / $cacheWrite cache+ / $cacheRead cache-'
          : '';
      test('${c['model']} : ${c['inputTokens']} in / ${c['outputTokens']} out'
          '$cacheLabel / ${c['imageOutputCount']} img → ${c['usd']} \$  '
          '(${c['why']})', () {
        final actual = AiPricing.costUsd(
          model: c['model'] as String,
          inputTokens: c['inputTokens'] as int,
          outputTokens: c['outputTokens'] as int,
          cacheCreationInputTokens: cacheWrite,
          cacheReadInputTokens: cacheRead,
          imageOutputCount: c['imageOutputCount'] as int,
          analyzedImageUnits: (c['analyzedImageUnits'] as int?) ?? 0,
          groundedSearchCount: (c['groundedSearchCount'] as int?) ?? 0,
          at: DateTime.parse(c['at'] as String),
          table: pricingTable,
        );
        expect(actual, closeTo((c['usd'] as num).toDouble(), 1e-9));
      });
    }
  });
}
