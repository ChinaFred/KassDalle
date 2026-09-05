import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/processing/domain/processing_trail.dart';

/// Le fil des étapes est un **miroir** du pipeline serveur.
///
/// Les séquences viennent des branchements de
/// `functions/src/pipeline/recipeProcessor.ts`, qui écrit `current_step` à
/// chaque passage. Rien ne relie les deux côtés à l'exécution : si le serveur
/// ajoute une étape ou en retire une, le fil continue de s'afficher — il
/// montrera simplement un jalon qui n'arrive jamais, ou sautera une étape
/// réellement traversée. Aucune erreur, aucun test rouge.
///
/// D'où ces séquences figées : les modifier oblige à venir ici, donc à vérifier
/// le serveur.
void main() {
  group('trailFor', () {
    test('une couverture de livre traverse trois étapes', () {
      // `recipeProcessor.ts`, branche `bookCoverScan` : import, gemini_call,
      // save, puis done. Ni parse, ni design, ni tagging, ni normalize.
      expect(
        trailFor(ProcessingJobType.bookCoverScan).map((e) => e.code).toList(),
        ['import', 'gemini_call', 'save'],
      );
    });

    test('une page de recette en traverse sept', () {
      const attendu = [
        'import',
        'gemini_call',
        'parse',
        'design',
        'tagging',
        'normalize',
        'save',
      ];
      expect(
        trailFor(ProcessingJobType.recipeScan).map((e) => e.code).toList(),
        attendu,
      );
      expect(
        trailFor(
          ProcessingJobType.bookDocumentScan,
        ).map((e) => e.code).toList(),
        attendu,
      );
    });

    test('chaque étape porte un libellé court, sur une seule ligne', () {
      // C'est tout l'objet du fil : la phrase complète se coupait une lettre
      // par ligne sur un téléphone étroit à grande échelle de police.
      for (final type in ProcessingJobType.values) {
        for (final etape in trailFor(type)) {
          expect(etape.shortLabel, isNotEmpty);
          expect(
            etape.shortLabel.contains(' '),
            isFalse,
            reason: '${etape.code} : un seul mot attendu',
          );
          expect(etape.shortLabel.length, lessThanOrEqualTo(12));
        }
      }
    });
  });

  group('stepIndexIn', () {
    test('situe l\'étape courante dans le fil', () {
      final fil = trailFor(ProcessingJobType.recipeScan);
      expect(stepIndexIn(fil, 'import'), 0);
      expect(stepIndexIn(fil, 'tagging'), 4);
      expect(stepIndexIn(fil, 'save'), 6);
    });

    test('rend null sur une étape hors du fil', () {
      // Le client écrit parfois un libellé en clair — « Extraction du texte… »
      // pendant un scan. L'afficher comme un jalon désignerait la mauvaise
      // case ; l'appelant retombe sur le texte.
      final fil = trailFor(ProcessingJobType.bookCoverScan);
      expect(stepIndexIn(fil, 'tagging'), isNull);
      expect(stepIndexIn(fil, 'Extraction du texte…'), isNull);
      expect(stepIndexIn(fil, null), isNull);
      expect(stepIndexIn(fil, '  '), isNull);
    });

    test('queued et done n\'ont pas de jalon', () {
      // L'un précède le premier, l'autre éteint le fil entier.
      final fil = trailFor(ProcessingJobType.recipeScan);
      expect(stepIndexIn(fil, 'queued'), isNull);
      expect(stepIndexIn(fil, 'done'), isNull);
    });
  });
}
