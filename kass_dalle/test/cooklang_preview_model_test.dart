import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/presentation/cooklang_preview_model.dart';

/// Lecture d'un texte CookLang pour l'aperçu.
///
/// Ces 120 lignes de règles vivaient au milieu d'une méthode de rendu : les
/// éprouver demandait de monter un écran entier, avec son thème et ses
/// contraintes de taille. Extraites, elles se testent comme ce qu'elles sont —
/// une lecture de texte.
void main() {
  group('métadonnées', () {
    test('les clés sont normalisées en minuscules', () {
      final model = parseCooklangPreview('>> Portions: 4\n>> PREP_TIME: 20');
      expect(model.meta['portions'], '4');
      expect(model.meta['prep_time'], '20');
    });

    test('une ligne >> sans deux-points est ignorée', () {
      expect(parseCooklangPreview('>> nimportequoi').meta, isEmpty);
    });

    test('la valeur peut contenir des deux-points', () {
      final model = parseCooklangPreview('>> source: Livre: tome 2');
      expect(model.meta['source'], 'Livre: tome 2');
    });
  });

  group('étapes et sections', () {
    test('sans section, un seul groupe anonyme', () {
      final model = parseCooklangPreview('Préchauffer.\nEnfourner.');
      expect(model.stepGroups.length, 1);
      expect(model.stepGroups.first.name, isNull);
      expect(model.steps, ['Préchauffer.', 'Enfourner.']);
      expect(model.hasSections, isFalse);
    });

    test('les sections == == ouvrent des groupes nommés', () {
      final model = parseCooklangPreview(
        '== Pâte ==\nMélanger.\n== Cuisson ==\nEnfourner.',
      );
      expect(model.stepGroups.map((g) => g.name), ['Pâte', 'Cuisson']);
      expect(model.hasSections, isTrue);
    });

    test('une seule section nommée compte quand même comme sectionnée', () {
      final model = parseCooklangPreview('== Pâte ==\nMélanger.');
      expect(model.hasSections, isTrue);
    });

    test('les commentaires -- et les lignes vides disparaissent', () {
      final model = parseCooklangPreview(
        '-- note interne\n\nPréchauffer.\n\n-- autre note',
      );
      expect(model.steps, ['Préchauffer.']);
    });
  });

  group('continuation « + »', () {
    test('prolonge l\'étape précédente au lieu d\'en ouvrir une', () {
      final model = parseCooklangPreview('Préchauffer.\n+ à 180 degrés.');
      expect(model.steps, ['Préchauffer.\nà 180 degrés.']);
    });

    test('une note n\'accepte pas de continuation', () {
      final model = parseCooklangPreview('> Astuce du chef.\n+ suite.');
      expect(model.steps.length, 2);
    });

    test('une image n\'accepte pas de continuation', () {
      final model = parseCooklangPreview('![after](http://x/y.jpg)\n+ suite.');
      expect(model.steps.length, 2);
    });

    test('un « + » en toute première ligne reste une étape', () {
      final model = parseCooklangPreview('+ commencer ici.');
      expect(model.steps, ['+ commencer ici.']);
    });

    test('les ingrédients de la continuation sont collectés', () {
      final model = parseCooklangPreview(
        'Mélanger.\n+ ajouter la @farine{200%g}.',
      );
      expect(model.ingredients.map((i) => i.name), ['farine']);
      expect(model.ingredients.first.qty, '200');
      expect(model.ingredients.first.unit, 'g');
    });
  });

  group('ingrédients', () {
    test('quantité et unité sont séparées par le %', () {
      final model = parseCooklangPreview('Verser le @lait{50%cl}.');
      final lait = model.ingredients.single;
      expect(lait.name, 'lait');
      expect(lait.qty, '50');
      expect(lait.unit, 'cl');
    });

    test('un ingrédient sans unité garde une unité vide', () {
      final model = parseCooklangPreview('Casser les @œufs{3}.');
      expect(model.ingredients.single.qty, '3');
      expect(model.ingredients.single.unit, '');
    });

    test(
      'la déduplication ignore la casse et garde la première occurrence',
      () {
        final model = parseCooklangPreview(
          'Verser le @lait{50%cl}.\nAjouter le @Lait{10%cl}.',
        );
        expect(model.ingredients.length, 1);
        expect(model.ingredients.single.qty, '50');
      },
    );

    test('la section courante devient la catégorie de l\'ingrédient', () {
      final model = parseCooklangPreview(
        '== Pâte ==\n@farine{200%g}\n== Garniture ==\n@crème{20%cl}',
      );
      expect(
        {for (final i in model.ingredients) i.name: i.category},
        {'farine': 'Pâte', 'crème': 'Garniture'},
      );
    });

    test('hors section, la catégorie reste nulle', () {
      final model = parseCooklangPreview('@farine{200%g}');
      expect(model.ingredients.single.category, isNull);
    });

    test('une ligne de note ne fournit pas d\'ingrédient', () {
      // Le `>` marque un conseil, pas une instruction : ce qu'il cite n'entre
      // pas dans la liste des courses.
      final model = parseCooklangPreview('> Prévoir de la @farine{200%g}.');
      expect(model.ingredients, isEmpty);
    });

    test('l\'ordre suit la première apparition, pas l\'alphabet', () {
      final model = parseCooklangPreview(
        '@zeste{1} puis @ail{2} puis @beurre{30%g}',
      );
      expect(model.ingredients.map((i) => i.name), ['zeste', 'ail', 'beurre']);
    });
  });

  group('texte vide', () {
    test('ne produit ni étape ni ingrédient', () {
      final model = parseCooklangPreview('');
      expect(model.steps, isEmpty);
      expect(model.ingredients, isEmpty);
      expect(model.stepGroups, isEmpty);
      expect(model.hasSections, isFalse);
    });
  });
}
