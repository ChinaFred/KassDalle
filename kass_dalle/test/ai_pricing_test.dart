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

  group('table des tarifs', () {
    for (final row in table) {
      final model = row['model'] as String;
      test('« $model » porte les prix de la fixture', () {
        final pricing = AiPricing.forModel(model);
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
      });
    }
  });

  group('résolution du modèle', () {
    final cases = (fixture['resolution'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final model = c['model'] as String;
      final expected = c['expect'] as String?;
      test('« $model » → ${expected ?? '(défaut)'}  (${c['why']})', () {
        final actual = AiPricing.forModel(model);
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
      test(
        '${c['model']} : ${c['inputTokens']} in / ${c['outputTokens']} out / '
        '${c['imageOutputCount']} img → ${c['usd']} \$  (${c['why']})',
        () {
          final actual = AiPricing.costUsd(
            model: c['model'] as String,
            inputTokens: c['inputTokens'] as int,
            outputTokens: c['outputTokens'] as int,
            imageOutputCount: c['imageOutputCount'] as int,
          );
          expect(actual, closeTo((c['usd'] as num).toDouble(), 1e-9));
        },
      );
    }
  });
}
