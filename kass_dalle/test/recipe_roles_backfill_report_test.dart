import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/recipe_roles_backfill_report.dart';

void main() {
  group('RecipeRolesBackfillReport.fromMap', () {
    test('lit les compteurs, les arrêts et le reste à classer', () {
      final r = RecipeRolesBackfillReport.fromMap({
        'examinees': 140,
        'classees': 40,
        'dejaClassees': 97,
        'horsRecette': 2,
        'sansRole': 1,
        'echouees': 0,
        'restantes': 212,
        'completed': false,
        'stoppedByBudget': true,
        'stoppedByErrors': false,
        'stoppedByDeadline': false,
      }, finishedAt: DateTime(2026, 9, 13, 12, 20));

      expect(r.examinees, 140);
      expect(r.classees, 40);
      expect(r.dejaClassees, 97);
      expect(r.horsRecette, 2);
      expect(r.sansRole, 1);
      expect(r.echouees, 0);
      expect(r.restantes, 212);
      expect(r.completed, isFalse);
      expect(r.stoppedByBudget, isTrue);
      expect(r.finishedAt, DateTime(2026, 9, 13, 12, 20));
      expect(r.restantesSentence, 'Reste à classer : 212 recettes.');
      expect(
        r.passSummary,
        'examinées=140, classées=40, déjà classées=97, hors recette=2, '
        'sans rôle=1, échecs=0 — incomplet '
        '(quota du passage atteint, relancer pour continuer)',
      );
    });

    test('un décompte absent reste inconnu, il ne devient pas zéro', () {
      final absent = RecipeRolesBackfillReport.fromMap({'classees': 3});
      expect(absent.restantes, isNull);
      expect(
        absent.restantesSentence,
        startsWith('Reste à classer : décompte'),
      );

      final nul = RecipeRolesBackfillReport.fromMap({'restantes': null});
      expect(nul.restantes, isNull);

      final zero = RecipeRolesBackfillReport.fromMap({
        'restantes': 0,
        'completed': true,
      });
      expect(zero.restantes, 0);
      expect(zero.restantesSentence, 'Plus rien à classer.');
      expect(zero.passSummary, endsWith('— terminé'));
    });

    test(
      'exclues après trois échecs, et incomplet tant qu\'un échec reste',
      () {
        final r = RecipeRolesBackfillReport.fromMap({
          'classees': 3,
          'sansRole': 1,
          'exclues': 2,
          'echecsNonExclus': 1,
          'restantes': 3,
          'completed': true,
        });
        expect(r.exclues, 2);
        expect(r.echecsNonExclus, 1);
        expect(
          r.passSummary,
          'examinées=0, classées=3, déjà classées=0, hors recette=0, '
          'sans rôle=1, échecs=0, exclues après 3 échecs=2 — incomplet',
        );
      },
    );

    test('un nombre décimal venu du JSON est tronqué en entier', () {
      final r = RecipeRolesBackfillReport.fromMap({
        'restantes': 1.0,
        'classees': 2.0,
      });
      expect(r.restantes, 1);
      expect(r.classees, 2);
      expect(r.restantesSentence, 'Reste à classer : 1 recette.');
    });
  });
}
