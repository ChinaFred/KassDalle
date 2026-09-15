import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/utils/ingredient_display.dart';

/// Une ligne de courses qui porte plusieurs quantités.
///
/// « 250 g de lait de coco » et « 400 ml de lait de coco » faisaient deux
/// lignes : le produit est le même, on l'achète une fois. Les deux quantités
/// se lisent sur une ligne, et un comptage vient en dernier, accordé au nom.
void main() {
  group('formatShoppingLine', () {
    test('deux mesures sans conversion se lisent sur une ligne', () {
      expect(
        formatShoppingLine(
          quantities: const [(qty: '400', unit: 'ml'), (qty: '250', unit: 'g')],
          name: 'lait de coco',
        ),
        '400 ml + 250 g de lait de coco',
      );
    });

    test('le comptage vient en dernier et accorde le nom', () {
      expect(
        formatShoppingLine(
          quantities: const [(qty: '2', unit: 'kg'), (qty: '6', unit: '')],
          name: 'pomme de terre',
        ),
        '2 kg + 6 pommes de terre',
      );
      expect(
        formatShoppingLine(
          quantities: const [
            (qty: '6', unit: 'pièces'),
            (qty: '2', unit: 'kg'),
          ],
          name: 'pomme de terre',
        ),
        '2 kg + 6 pommes de terre',
      );
    });

    test('une seule quantité se lit comme une ligne ordinaire', () {
      expect(
        formatShoppingLine(
          quantities: const [(qty: '500', unit: 'g')],
          name: 'farine',
        ),
        '500 g de farine',
      );
      expect(
        formatShoppingLine(
          quantities: const [(qty: '3', unit: '')],
          name: 'carotte',
        ),
        '3 carottes',
      );
    });

    test('sans quantité, le nom seul', () {
      expect(formatShoppingLine(quantities: const [], name: 'sel'), 'sel');
    });

    test('l\'élision tient devant une voyelle', () {
      expect(
        formatShoppingLine(
          quantities: const [
            (qty: '20', unit: 'cl'),
            (qty: '2', unit: 'cuillère à soupe'),
          ],
          name: 'huile d\'olive',
        ),
        "20 cl + 2 cuillères à soupe d'huile d'olive",
      );
    });
  });

  group('formatQuantityOnly', () {
    test('une mesure garde son unité, accordée', () {
      expect(
        formatQuantityOnly(qty: '3', unit: 'Cuillère à soupe'),
        '3 cuillères à soupe',
      );
      expect(formatQuantityOnly(qty: '400', unit: 'ml'), '400 ml');
    });

    test('un comptage est le nombre seul', () {
      expect(formatQuantityOnly(qty: '6', unit: ''), '6');
      expect(formatQuantityOnly(qty: '4', unit: 'pièces'), '4');
    });
  });
}
