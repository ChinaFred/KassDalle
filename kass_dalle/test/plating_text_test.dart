import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/plating_advice.dart';
import 'package:kass_dalle/features/recipes/domain/plating_text.dart';

/// Écriture du dressage dans le CookLang de la recette.
///
/// Trois risques réels sont couverts ici : un « @ » ou un « # » resté dans une
/// phrase fabriquerait un ingrédient fantôme qui remonterait jusque dans la
/// liste de courses ; une seconde insertion empilerait les sections
/// « Dressage » au lieu de remplacer la précédente ; et une section
/// « Cuisson et dressage » écrite à la main par un cuisinier pourrait être
/// emportée par le nettoyage.

PlatingAdvice _advice({
  List<PlatingStep> etapes = const [],
  List<String> pieges = const [],
  List<String> derniereMinute = const [],
  String contenant = '',
}) {
  return PlatingAdvice(
    complexite: PlatingComplexity.complexe,
    resume: 'Une assiette lisible.',
    contenant: contenant,
    etapes: etapes,
    pieges: pieges,
    derniereMinute: derniereMinute,
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
      expect(hasPlatingSection(updated), isTrue);
    });

    test('une seconde insertion remplace la première', () {
      // La question qui compte : intégrer deux fois ne doit pas laisser deux
      // dressages contradictoires dans la même recette.
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

    test('trois insertions ne laissent qu\'une section', () {
      var cooklang = recette;
      for (final geste in ['Un.', 'Deux.', 'Trois.']) {
        cooklang = applyPlatingSection(
          cooklang,
          _advice(etapes: [PlatingStep(titre: 'A', geste: geste)]),
        );
      }
      expect('## Dressage'.allMatches(cooklang).length, 1);
      expect(cooklang, contains('Trois.'));
      expect(cooklang, isNot(contains('Un.')));
    });

    test('les visuels de l\'insertion précédente ne s\'accumulent pas', () {
      final once = applyPlatingSection(
        recette,
        _advice(
          etapes: const [
            PlatingStep(titre: 'A', geste: 'Poser.', imageUrl: 'https://x/vieux.jpg'),
          ],
        ),
      );
      final twice = applyPlatingSection(
        once,
        _advice(
          etapes: const [
            PlatingStep(titre: 'A', geste: 'Poser.', imageUrl: 'https://x/neuf.jpg'),
          ],
        ),
      );
      expect(twice, contains('https://x/neuf.jpg'));
      expect(twice, isNot(contains('https://x/vieux.jpg')));
    });

    test('la section « Cuisson et dressage » du cuisinier est préservée', () {
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

    test('une section qui suit le dressage reprend le fil', () {
      const avecSuite =
          '## Dressage\nPoser au centre.\n## Conservation\nAu frais 24 h.';
      final nettoye = removePlatingSection(avecSuite);
      expect(nettoye, contains('## Conservation'));
      expect(nettoye, contains('Au frais 24 h.'));
      expect(nettoye, isNot(contains('Poser au centre.')));
    });
  });
}
