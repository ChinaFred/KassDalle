import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/recipe_protein_backfill_report.dart';

void main() {
  group('RecipeProteinBackfillReport.fromMap', () {
    test('lit les compteurs, les arrêts et le reste à traiter', () {
      final r = RecipeProteinBackfillReport.fromMap({
        'examinees': 100,
        'traitees': 38,
        'dejaTraitees': 12,
        'ignorees': 48,
        'sansReponse': 1,
        'echouees': 1,
        'restantes': 120,
        'completed': false,
        'stoppedByBudget': true,
      });
      expect(r.traitees, 38);
      expect(r.ignorees, 48);
      expect(r.echouees, 1);
      expect(r.restantes, 120);
      expect(r.stoppedByBudget, isTrue);
      expect(
        r.restantesSentence,
        'Reste à traiter : environ 120 plats ou accompagnements.',
      );
      expect(
        r.passSummary,
        'examinées=100, traitées=38, déjà traitées=12, ignorées=48, '
        'sans réponse=1, échecs=1 — incomplet '
        '(quota du passage atteint, relancer pour continuer)',
      );
    });

    test('un décompte absent reste inconnu, il ne devient pas zéro', () {
      final r = RecipeProteinBackfillReport.fromMap({'traitees': 3});
      expect(r.restantes, isNull);
      expect(r.restantesSentence, contains('décompte impossible'));
      expect(
        RecipeProteinBackfillReport.fromMap({'restantes': 0}).restantesSentence,
        'Plus rien à traiter.',
      );
    });
  });
}
