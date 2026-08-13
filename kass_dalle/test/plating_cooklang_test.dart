import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/plating_advice.dart';
import 'package:kass_dalle/features/recipes/domain/plating_cooklang.dart';

/// Écriture du conseil de dressage dans le CookLang.
///
/// Deux risques réels sont couverts ici : un « @ » ou un « # » resté dans une
/// phrase fabriquerait un ingrédient fantôme qui remonterait jusque dans la
/// liste de courses ; et une régénération empilerait les sections « Dressage »
/// au lieu de remplacer la précédente.

PlatingAdvice _advice({
  List<PlatingStep> etapes = const [],
  List<String> pieges = const [],
  List<String> derniereMinute = const [],
  String contenant = '',
  String? finalImageUrl,
}) {
  return PlatingAdvice(
    complexite: PlatingComplexity.complexe,
    resume: 'Une assiette lisible.',
    contenant: contenant,
    etapes: etapes,
    pieges: pieges,
    derniereMinute: derniereMinute,
    finalImageUrl: finalImageUrl,
  );
}

void main() {
  group('sanitizeForCooklang', () {
    test('retire le balisage qui créerait un ingrédient fantôme', () {
      expect(
        sanitizeForCooklang('Poser le @cabillaud{2%pièce} dans la #assiette'),
        'Poser le cabillaud2%pièce dans la assiette',
      );
    });

    test('normalise les espaces', () {
      expect(sanitizeForCooklang('  deux   espaces \n fin '), 'deux espaces fin');
    });
  });

  group('buildPlatingSection', () {
    test('titre et geste tiennent sur une ligne d\'étape', () {
      final section = buildPlatingSection(
        _advice(
          etapes: const [
            PlatingStep(titre: 'Le lit', geste: 'Étaler le confit au centre.'),
          ],
        ),
      );
      expect(section, contains('## Dressage'));
      expect(section, contains('Le lit : Étaler le confit au centre.'));
    });

    test('les visuels alternent droite puis gauche', () {
      final section = buildPlatingSection(
        _advice(
          etapes: const [
            PlatingStep(titre: 'A', geste: 'Geste A', imageUrl: 'https://x/a.jpg'),
            PlatingStep(titre: 'B', geste: 'Geste B', imageUrl: 'https://x/b.jpg'),
            PlatingStep(titre: 'C', geste: 'Geste C'),
          ],
        ),
      );
      expect(section, contains('![right|40](https://x/a.jpg)'));
      expect(section, contains('![left|40](https://x/b.jpg)'));
      expect('!['.allMatches(section).length, 2);
    });

    test('pièges et finitions deviennent des notes', () {
      final section = buildPlatingSection(
        _advice(
          contenant: 'Assiette creuse tiède.',
          pieges: const ['La tuile ramollit sur le confit chaud.'],
          derniereMinute: const ['Les pousses de cresson.'],
        ),
      );
      expect(section, contains('> Assiette creuse tiède.'));
      expect(section, contains('> La tuile ramollit sur le confit chaud.'));
      expect(section, contains('> Au dernier moment : Les pousses de cresson.'));
    });

    test('le résultat dressé clôt la section en pleine largeur', () {
      final section = buildPlatingSection(
        _advice(
          etapes: const [
            PlatingStep(titre: 'A', geste: 'Geste A', imageUrl: 'https://x/a.jpg'),
          ],
          finalImageUrl: 'https://x/final.jpg',
        ),
      );
      expect(section, contains('![right|40](https://x/a.jpg)'));
      expect(section.trimRight(), endsWith('![after](https://x/final.jpg)'));
    });

    test('une étape sans geste ne produit pas de ligne vide', () {
      final section = buildPlatingSection(
        _advice(etapes: const [PlatingStep(titre: 'Vide', geste: '   ')]),
      );
      expect(section.split('\n').length, 1);
    });
  });

  group('applyPlatingSection', () {
    const recette = '>> titre: Cabillaud\n\n## Cuisson\nCuire le poisson.';

    test('ajoute la section à la fin de la recette', () {
      final updated = applyPlatingSection(
        recette,
        _advice(etapes: const [PlatingStep(titre: 'A', geste: 'Poser.')]),
      );
      expect(updated, startsWith(recette));
      expect(updated, contains('## Dressage'));
    });

    test('une seconde insertion remplace la première', () {
      final once = applyPlatingSection(
        recette,
        _advice(etapes: const [PlatingStep(titre: 'A', geste: 'Premier conseil.')]),
      );
      final twice = applyPlatingSection(
        once,
        _advice(etapes: const [PlatingStep(titre: 'A', geste: 'Second conseil.')]),
      );
      expect('## Dressage'.allMatches(twice).length, 1);
      expect(twice, contains('Second conseil.'));
      expect(twice, isNot(contains('Premier conseil.')));
      expect(twice, contains('Cuire le poisson.'));
    });

    test('la section « Cuisson et dressage » de la recette est préservée', () {
      const avecTitreProche = '## Cuisson et dressage\nEnfourner 20 min.';
      final updated = applyPlatingSection(
        avecTitreProche,
        _advice(etapes: const [PlatingStep(titre: 'A', geste: 'Poser.')]),
      );
      expect(updated, contains('## Cuisson et dressage'));
      expect(updated, contains('Enfourner 20 min.'));
    });

    test('la forme == Dressage de l\'éditeur visuel est aussi remplacée', () {
      const avecSectionEgal = '>> titre: X\n\n== Dressage\nAncien texte.';
      final updated = applyPlatingSection(
        avecSectionEgal,
        _advice(etapes: const [PlatingStep(titre: 'A', geste: 'Nouveau texte.')]),
      );
      expect(updated, isNot(contains('Ancien texte.')));
      expect(updated, contains('Nouveau texte.'));
    });
  });
}
