import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/presentation/ai_services_tab.dart';

/// Tri du tableau « Coût des appels d'IA ».
///
/// La règle qui compte : une colonne vide affiche « — », et « — » n'est pas
/// zéro. Un poste qui n'a jamais appelé Claude n'a pas un coût unitaire nul, il
/// n'en a pas — le trier comme un zéro le placerait en tête d'un tri croissant,
/// c'est-à-dire le présenterait comme le moins cher.
void main() {
  CostLine line(
    String label, {
    double claudeEur = 0,
    int claudeCalls = 0,
    double geminiEur = 0,
    int geminiCalls = 0,
  }) {
    return CostLine(label)
      ..claudeEur = claudeEur
      ..claudeCalls = claudeCalls
      ..geminiEur = geminiEur
      ..geminiCalls = geminiCalls;
  }

  List<String> labels(List<CostLine> lines) =>
      lines.map((l) => l.label).toList();

  group('costColumnValue', () {
    test('une colonne Claude vide vaut null, pas zéro', () {
      final sansClaude = line('Sans Claude', geminiEur: 1, geminiCalls: 10);
      expect(costColumnValue(sansClaude, CostColumn.claudeCalls), isNull);
      expect(costColumnValue(sansClaude, CostColumn.claudeUnit), isNull);
      expect(costColumnValue(sansClaude, CostColumn.claudeTotal), isNull);
    });

    test('une colonne Total est toujours renseignée', () {
      // Une ligne n'existe que parce qu'elle a coûté quelque chose : son total
      // n'est jamais « absent », au pire il vaut zéro.
      final l = line('X', geminiEur: 1, geminiCalls: 2);
      expect(costColumnValue(l, CostColumn.totalCalls), 2);
      expect(costColumnValue(l, CostColumn.total), 1);
    });
  });

  group('sortCostLines', () {
    final avecClaude = line(
      'Avec Claude',
      claudeEur: 1.0,
      claudeCalls: 100,
    ); // 0,01 € / appel
    final claudeCher = line(
      'Claude cher',
      claudeEur: 2.0,
      claudeCalls: 10,
    ); // 0,20 € / appel
    final sansClaude = line('Sans Claude', geminiEur: 5, geminiCalls: 50);

    test('un tri décroissant met le plus grand en tête', () {
      final sorted = sortCostLines(
        [avecClaude, claudeCher, sansClaude],
        CostColumn.claudeUnit,
        false,
      );
      expect(labels(sorted), ['Claude cher', 'Avec Claude', 'Sans Claude']);
    });

    test('un tri CROISSANT laisse la colonne vide en bas', () {
      // Le cas qui motive tout ce fichier : « Sans Claude » ne doit PAS
      // remonter en tête sous prétexte qu'il vaudrait zéro.
      final sorted = sortCostLines(
        [claudeCher, sansClaude, avecClaude],
        CostColumn.claudeUnit,
        true,
      );
      expect(labels(sorted), ['Avec Claude', 'Claude cher', 'Sans Claude']);
    });

    test('deux colonnes vides se rangent par libellé', () {
      final b = line('Beta', geminiEur: 1, geminiCalls: 1);
      final a = line('Alpha', geminiEur: 2, geminiCalls: 2);
      final sorted = sortCostLines([b, a], CostColumn.claudeTotal, false);
      expect(labels(sorted), ['Alpha', 'Beta']);
    });

    test(
      'des montants égaux se départagent par libellé, dans les deux sens',
      () {
        // Sans ce départage, deux postes au même montant échangent de place à
        // chaque reconstruction de l'écran.
        final z = line('Zeta', geminiEur: 3, geminiCalls: 1);
        final a = line('Alpha', geminiEur: 3, geminiCalls: 1);
        expect(labels(sortCostLines([z, a], CostColumn.total, false)), [
          'Alpha',
          'Zeta',
        ]);
        expect(labels(sortCostLines([z, a], CostColumn.total, true)), [
          'Alpha',
          'Zeta',
        ]);
      },
    );

    test(
      'le libellé se trie alphabétiquement, sans tenir compte de la casse',
      () {
        final lines = [line('banane'), line('Ananas'), line('Cerise')];
        expect(labels(sortCostLines(lines, CostColumn.label, true)), [
          'Ananas',
          'banane',
          'Cerise',
        ]);
        expect(labels(sortCostLines(lines, CostColumn.label, false)), [
          'Cerise',
          'banane',
          'Ananas',
        ]);
      },
    );

    test('la liste d\'origine n\'est pas modifiée', () {
      // Le tableau reçoit ses lignes d'un agrégat partagé : les trier sur place
      // changerait l'ordre sous les autres lecteurs.
      final source = [claudeCher, avecClaude];
      sortCostLines(source, CostColumn.claudeUnit, true);
      expect(labels(source), ['Claude cher', 'Avec Claude']);
    });
  });

  group('filterCostLines', () {
    final lines = [
      CostLine('Génération de recette'),
      CostLine('Maj produits de courses (save recette)'),
      CostLine('Visuel de montage'),
    ];

    test('une requête vide rend tout', () {
      expect(filterCostLines(lines, ''), hasLength(3));
      expect(filterCostLines(lines, '   '), hasLength(3));
    });

    test('la recherche ignore les accents', () {
      // Personne ne tape « Génération » avec son accent dans un filtre.
      expect(labels(filterCostLines(lines, 'generation')), [
        'Génération de recette',
      ]);
    });

    test('la recherche ignore la casse', () {
      expect(labels(filterCostLines(lines, 'VISUEL')), ['Visuel de montage']);
    });

    test('elle cherche partout dans le libellé, pas seulement au début', () {
      expect(labels(filterCostLines(lines, 'montage')), ['Visuel de montage']);
    });

    test('elle peut rendre plusieurs lignes', () {
      expect(filterCostLines(lines, 'recette'), hasLength(2));
    });

    test('sans correspondance, elle rend une liste vide', () {
      expect(filterCostLines(lines, 'zzz'), isEmpty);
    });
  });

  group('sumCostLines', () {
    test('la somme d\'une sélection ne compte que cette sélection', () {
      // Le total sous un tableau filtré doit additionner CE QU\'IL MONTRE :
      // laisser celui de la période afficherait une somme que les lignes
      // au-dessus ne font pas.
      final a = line(
        'A',
        claudeEur: 1,
        claudeCalls: 2,
        geminiEur: 3,
        geminiCalls: 4,
      );
      final b = line('B', geminiEur: 7, geminiCalls: 1);
      final total = sumCostLines([a, b], label: 'Total filtré');
      expect(total.label, 'Total filtré');
      expect(total.claudeEur, 1);
      expect(total.claudeCalls, 2);
      expect(total.geminiEur, 10);
      expect(total.totalCalls, 7);
    });

    test('la somme d\'une liste vide est nulle, pas absente', () {
      final total = sumCostLines(const [], label: 'Total filtré');
      expect(total.totalEur, 0);
      expect(total.totalCalls, 0);
    });
  });
}
