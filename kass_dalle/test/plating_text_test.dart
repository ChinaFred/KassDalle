import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/plating_advice.dart';
import 'package:kass_dalle/features/recipes/domain/plating_text.dart';

/// Le dressage comme texte autonome, et le nettoyage des recettes où il avait
/// été recopié.
///
/// Le retrait doit être chirurgical : une section « Cuisson et dressage »
/// écrite à la main par un cuisinier n'est pas la section produite par l'IA, et
/// la supprimer ferait perdre du contenu que personne ne pourrait retrouver.

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
  group('buildPlatingText', () {
    test('le titre de la recette coiffe le texte', () {
      final texte = buildPlatingText(_advice(), recipeTitle: 'Cabillaud');
      expect(texte, startsWith('Dressage — Cabillaud'));
    });

    test('sans titre, l\'en-tête reste lisible', () {
      expect(buildPlatingText(_advice()), startsWith('Dressage\n'));
    });

    test('les étapes sont numérotées dans l\'ordre', () {
      final texte = buildPlatingText(
        _advice(
          etapes: const [
            PlatingStep(titre: 'Le lit', geste: 'Étaler le confit.'),
            PlatingStep(titre: 'Le poisson', geste: 'Poser le cabillaud.'),
          ],
        ),
      );
      expect(texte, contains('1. Le lit — Étaler le confit.'));
      expect(texte, contains('2. Le poisson — Poser le cabillaud.'));
    });

    test('une étape sans geste ne consomme pas de numéro', () {
      final texte = buildPlatingText(
        _advice(
          etapes: const [
            PlatingStep(titre: 'Vide', geste: '   '),
            PlatingStep(titre: 'Le poisson', geste: 'Poser le cabillaud.'),
          ],
        ),
      );
      expect(texte, contains('1. Le poisson — Poser le cabillaud.'));
      expect(texte, isNot(contains('2.')));
    });

    test('pièges et finitions sont regroupés sous leur intitulé', () {
      final texte = buildPlatingText(
        _advice(
          contenant: 'Assiette creuse tiède.',
          pieges: const ['La tuile ramollit.'],
          derniereMinute: const ['Les pousses de cresson.'],
        ),
      );
      expect(texte, contains('Contenant : Assiette creuse tiède.'));
      expect(texte, contains('Ce qui rate sur ce plat :\n- La tuile ramollit.'));
      expect(texte, contains('Au dernier moment :\n- Les pousses de cresson.'));
    });

    test('aucune balise CookLang ne sort du texte', () {
      final texte = buildPlatingText(
        _advice(etapes: const [PlatingStep(titre: 'A', geste: 'Poser.')]),
      );
      expect(texte, isNot(contains('##')));
      expect(texte, isNot(contains('![')));
    });
  });

  group('removePlatingSection', () {
    const recette = '>> titre: Cabillaud\n\n## Cuisson\nCuire le poisson.';

    test('une recette sans section insérée n\'est pas touchée', () {
      expect(removePlatingSection(recette), recette);
      expect(hasPlatingSection(recette), isFalse);
    });

    test('la section insérée par une version antérieure est retirée', () {
      const avecSection =
          '$recette\n\n## Dressage\nPoser au centre.\n![right|40](https://x/a.jpg)';
      expect(hasPlatingSection(avecSection), isTrue);
      final nettoye = removePlatingSection(avecSection);
      expect(nettoye, recette);
    });

    test('la forme == Dressage de l\'éditeur visuel est aussi retirée', () {
      const avecSectionEgal = '>> titre: X\n\n== Dressage\nAncien texte.';
      expect(removePlatingSection(avecSectionEgal), '>> titre: X');
    });

    test('la section « Cuisson et dressage » du cuisinier est préservée', () {
      const avecTitreProche = '## Cuisson et dressage\nEnfourner 20 min.';
      expect(removePlatingSection(avecTitreProche), avecTitreProche);
      expect(hasPlatingSection(avecTitreProche), isFalse);
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
