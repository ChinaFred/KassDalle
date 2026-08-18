import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/utils/ingredient_display.dart';

/// Accord des ingrédients à l'affichage.
///
/// Le premier groupe rejoue **ligne par ligne** une fiche réellement imprimée —
/// « Bœuf-riz express aux légumes croquants ». C'est elle qui a révélé le
/// défaut, et c'est elle qui dit si la correction tient.
void main() {
  group('la fiche imprimée, ligne par ligne', () {
    test('l\'unité du référentiel se lit en minuscule et s\'accorde', () {
      // Lu : « 3 Cuillère à soupe sauce soja ». Le libellé du référentiel est
      // écrit pour un tableau d'administration, pas pour une phrase.
      expect(
        formatIngredientDisplay(
          qty: '3',
          unit: 'Cuillère à soupe',
          name: 'sauce soja',
        ),
        '3 cuillères à soupe de sauce soja',
      );
      expect(
        formatIngredientDisplay(
          qty: '1',
          unit: 'Cuillère à soupe',
          name: 'huile de sésame',
        ),
        "1 cuillère à soupe d'huile de sésame",
      );
      expect(
        formatIngredientDisplay(qty: '1', unit: 'Pincée', name: 'sel'),
        '1 pincée de sel',
      );
    });

    test('l\'unité qui compte disparaît, et le nom prend le nombre', () {
      // Lu : « 1 pièces poivron » et « 2 pièces carotte ».
      expect(
        formatIngredientDisplay(qty: '1', unit: 'pièces', name: 'poivron'),
        '1 poivron',
      );
      expect(
        formatIngredientDisplay(qty: '2', unit: 'pièces', name: 'carotte'),
        '2 carottes',
      );
    });

    test('l\'élision se fait devant une voyelle', () {
      // Lu : « 2 gousse ail » et « 500 g émincé de bœuf ».
      expect(
        formatIngredientDisplay(qty: '2', unit: 'gousse', name: 'ail'),
        "2 gousses d'ail",
      );
      expect(
        formatIngredientDisplay(qty: '500', unit: 'g', name: 'émincé de bœuf'),
        "500 g d'émincé de bœuf",
      );
    });

    test('un symbole d\'unité reste tel quel', () {
      // « 500 gs » n'existe pas, et « 1 Cm » non plus.
      expect(
        formatIngredientDisplay(qty: '300', unit: 'g', name: 'riz basmati'),
        '300 g de riz basmati',
      );
      expect(
        formatIngredientDisplay(qty: '1', unit: 'cm', name: 'gingembre'),
        '1 cm de gingembre',
      );
    });

    test('dans la prose, le nom s\'accorde — mais seulement s\'il compte', () {
      // Lu : « Émincer finement le poivron, les carotte, l'oignon ».
      expect(
        ingredientNameInProse(name: 'carotte', qty: '2', unit: 'pièces'),
        'carottes',
      );
      expect(
        ingredientNameInProse(name: 'poivron', qty: '1', unit: 'pièces'),
        'poivron',
      );
      // Trois cuillères de sauce soja restent « la sauce soja », et deux
      // gousses d'ail restent « l'ail » : c'est l'unité qui porte le nombre.
      expect(
        ingredientNameInProse(
          name: 'sauce soja',
          qty: '3',
          unit: 'Cuillère à soupe',
        ),
        'sauce soja',
      );
      expect(
        ingredientNameInProse(name: 'ail', qty: '2', unit: 'gousse'),
        'ail',
      );
    });
  });

  group('pluriel français', () {
    test('les cas réguliers', () {
      expect(pluralizeWord('carotte'), 'carottes');
      expect(pluralizeWord('oignon'), 'oignons');
    });

    test('un mot déjà au pluriel ou invariable ne double pas', () {
      expect(pluralizeWord('ananas'), 'ananas');
      expect(pluralizeWord('noix'), 'noix');
      expect(pluralizeWord('carottes'), 'carottes');
    });

    test('les finales en -eau, -eu, -al, -ou', () {
      expect(pluralizeWord('poireau'), 'poireaux');
      expect(pluralizeWord('chou'), 'choux');
      expect(pluralizeWord('clou'), 'clous');
      expect(pluralizeWord('bocal'), 'bocaux');
      expect(pluralizeWord('festival'), 'festivals');
      expect(pluralizeWord('pneu'), 'pneus');
    });

    test('un symbole d\'unité ne prend jamais de pluriel', () {
      expect(pluralizeWord('g'), 'g');
      expect(pluralizeWord('kg'), 'kg');
      expect(pluralizeWord('ml'), 'ml');
    });

    test('un groupe avec préposition n\'accorde que sa tête', () {
      expect(pluralizeNounPhrase('cuillère à soupe'), 'cuillères à soupe');
      expect(pluralizeNounPhrase('pomme de terre'), 'pommes de terre');
      expect(pluralizeNounPhrase('gousse d\'ail'), 'gousses d\'ail');
    });

    test('un groupe sans préposition accorde tous ses mots', () {
      expect(pluralizeNounPhrase('haricot vert'), 'haricots verts');
      expect(pluralizeNounPhrase('verre moyen'), 'verres moyens');
    });
  });

  group('quand le pluriel ne s\'applique pas', () {
    test('le singulier tient jusqu\'à deux', () {
      // Le français écrit « 1,5 litre », au singulier.
      expect(quantityIsPlural('1'), isFalse);
      expect(quantityIsPlural('1,5'), isFalse);
      expect(quantityIsPlural('2'), isTrue);
      expect(quantityIsPlural('500'), isTrue);
    });

    test('une quantité illisible laisse le singulier', () {
      // Deviner un accord sur un mot qu'on n'a pas compris se voit davantage
      // que de s'abstenir.
      expect(quantityIsPlural('quelques'), isFalse);
      expect(quantityIsPlural(''), isFalse);
      expect(
        formatIngredientDisplay(qty: '', unit: 'pincée', name: 'sel'),
        'pincée de sel',
      );
    });

    test('sans quantité ni unité, le nom passe intact', () {
      expect(formatIngredientDisplay(qty: '', unit: '', name: 'sel'), 'sel');
    });

    test('l\'unité déjà contenue dans le nom ne se répète pas', () {
      // « 1 brin brin de romarin » : le cas que l'ancien formateur gérait
      // déjà, et qu'il ne faut pas perdre.
      expect(
        formatIngredientDisplay(
          qty: '1',
          unit: 'brin',
          name: 'brin de romarin',
        ),
        '1 brin de romarin',
      );
      expect(
        formatIngredientDisplay(qty: '2', unit: 'brin', name: 'brin de thym'),
        '2 brins de thym',
      );
    });

    test('le h aspiré refuse l\'élision', () {
      expect(
        formatIngredientDisplay(qty: '200', unit: 'g', name: 'haricots verts'),
        '200 g de haricots verts',
      );
      // …mais le h muet la prend, et c'est le cas le plus fréquent en cuisine.
      expect(
        formatIngredientDisplay(
          qty: '2',
          unit: 'Cuillère à soupe',
          name: 'huile',
        ),
        "2 cuillères à soupe d'huile",
      );
    });
  });
}
