import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/monthly_costs_repository.dart';
import 'package:kass_dalle/features/admin/presentation/costs_format.dart';

/// Le compte est belge : les montants s'affichent en euros, avec la virgule
/// pour les décimales. Une notation anglo-saxonne ne casse aucun écran — elle
/// fait seulement lire « 1.234 € » comme un euro et des poussières.
void main() {
  group('notation européenne', () {
    test('les décimales sont séparées par une virgule', () {
      expect(formatEur(12.34), contains(','));
      expect(formatEur(12.34), isNot(contains('.')));
      expect(formatEur(12.34), endsWith('€'));
    });

    test('les milliers sont séparés, jamais par un point', () {
      final text = formatEur(1234.5);
      expect(text, contains(','));
      expect(text, isNot(contains('.')));
      // Le séparateur de milliers est un espace, quelle que soit sa graisse.
      expect(RegExp(r'1\s').hasMatch(text), isTrue, reason: text);
    });

    test('un petit montant garde quatre décimales', () {
      // À deux décimales, la majorité des appels d'IA s'afficherait
      // « 0,00 € » — soit exactement le contraire de ce qu'on mesure.
      expect(formatEur(0.0123), '0,0123 €');
    });

    test('un montant est converti au taux fourni', () {
      expect(formatMoney(10, 0.9), '9,00 €');
    });

    test('sans taux connu, le dollar est affiché tel quel', () {
      // Convertir au hasard produirait un montant faux ; le dollar, lui, est
      // seulement étranger.
      expect(formatMoney(10, 0), endsWith('\$'));
    });

    test('un écart s\'exprime en pourcentage signé', () {
      expect(formatSignedPercent(0.1), startsWith('+'));
      expect(formatSignedPercent(-0.1), startsWith('−'));
    });
  });

  group('empreinte énergétique', () {
    test('l\'unité suit l\'ordre de grandeur', () {
      expect(formatEnergy(100), endsWith('µWh'));
      expect(formatEnergy(2000000), endsWith('Wh'));
      expect(formatEnergy(2000000000), endsWith('kWh'));
    });

    test('aucun jeton, aucune énergie', () {
      expect(estimateWh(0), 0);
      expect(formatEnergyKwh(0), '0 kWh');
    });
  });

  group('lecture d\'un mois', () {
    /// Le serveur rend chaque moteur sous la même forme — estimé d'un côté,
    /// facturé de l'autre — et un taux propre au mois.
    final month = MonthlyCost.fromMap(const {
      'period': '2026-08',
      'usdToEur': 0.9,
      'totalCostUsd': 5.0,
      'ai': {
        'totalCostUsd': 3.0,
        'calls': 10,
        'inputTokens': 1000,
        'outputTokens': 500,
        'byFeature': {
          'plating_coach': {
            'cost_usd': 3.0,
            'calls': 10,
            'input_tokens': 1000,
            'output_tokens': 500,
            'by_provider': {
              'anthropic': {
                'cost_usd': 2.0,
                'calls': 4,
                'input_tokens': 600,
                'output_tokens': 300,
              },
              'gemini': {
                'cost_usd': 1.0,
                'calls': 6,
                'input_tokens': 400,
                'output_tokens': 200,
              },
            },
          },
        },
      },
      'anthropic': {
        'estimatedUsd': 2.0,
        'billedUsd': 2.2,
        'calls': 4,
        'inputTokens': 600,
        'outputTokens': 300,
      },
      'gemini': {
        'estimatedUsd': 1.0,
        'billedUsd': null,
        'calls': 6,
        'inputTokens': 400,
        'outputTokens': 200,
      },
      'gcp': {
        'totalCostUsd': 2.0,
        'services': [
          {'service': 'Cloud Functions', 'costUsd': 2.0},
        ],
      },
    });

    test('le taux du mois est celui du mois, pas un taux global', () {
      expect(month.usdToEur, 0.9);
    });

    test('le facturé prime sur l\'estimé quand il existe', () {
      expect(month.anthropic.effectiveUsd, 2.2);
      expect(month.gemini.effectiveUsd, 1.0);
    });

    test('un facturé inconnu n\'est pas un facturé nul', () {
      // Un export illisible ne prouve pas une dépense nulle.
      expect(month.gemini.billedUsd, isNull);
      expect(month.gemini.deltaUsd, isNull);
    });

    test('l\'écart se lit en montant et en proportion', () {
      expect(month.anthropic.deltaUsd, closeTo(0.2, 1e-9));
      expect(month.anthropic.deltaRatio, closeTo(0.2 / 2.2, 1e-9));
    });

    test('le coût unitaire distingue deux postes de même total', () {
      final feature = month.features.single;
      expect(feature.provider('anthropic').unitCostUsd, 0.5);
      expect(feature.provider('gemini').unitCostUsd, closeTo(1 / 6, 1e-9));
    });

    test('un moteur absent du poste rend zéro, pas une erreur', () {
      expect(month.features.single.provider('inconnu').calls, 0);
    });
  });

  group('écart déjà expliqué par l\'histoire', () {
    MonthlyCost at(String period) =>
        MonthlyCost.fromMap({'period': period, 'usdToEur': 0.9});

    test('un mois clos avant le comptage du raisonnement est définitif', () {
      // Aucune reconstruction ne fera apparaître une donnée qui n'a jamais
      // été enregistrée : l'écart de ce mois-là n'est pas une piste à suivre.
      expect(at('2026-07').predatesThinkingCount, isTrue);
      expect(at('2026-07').spansThinkingCount, isFalse);
    });

    test('le mois où le comptage démarre est à cheval', () {
      expect(at('2026-08').predatesThinkingCount, isFalse);
      expect(at('2026-08').spansThinkingCount, isTrue);
    });

    test('un mois postérieur n\'a plus d\'excuse', () {
      // C'est tout l'intérêt de la bascule : à partir de septembre, un écart
      // redevient une anomalie à instruire.
      expect(at('2026-09').predatesThinkingCount, isFalse);
      expect(at('2026-09').spansThinkingCount, isFalse);
    });

    test('une période illisible ne prétend rien', () {
      expect(at('').predatesThinkingCount, isFalse);
      expect(at('2026').spansThinkingCount, isFalse);
    });
  });
}
