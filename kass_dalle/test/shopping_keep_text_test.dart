import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/shopping_cart.dart';

ShoppingItem _item(String name, String category, {bool checked = false}) =>
    ShoppingItem(
      name: name,
      quantities: const [(qty: '1', unit: '')],
      category: category,
      checked: checked,
    );

void main() {
  const date = '5 novembre 2026';
  const title = "Liste de courses Kass'Dalle – 5 novembre 2026";

  group('buildKeepText — « Copier pour Google Keep »', () {
    test('les articles cochés sont écartés, un rayon tout coché aussi', () {
      final keep = buildKeepText(
        items: [
          _item('Poulet', 'Viandes & charcuterie', checked: true),
          _item('Carotte', 'Légumes'),
          _item('Oignon', 'Légumes', checked: true),
          _item('Riz', 'Féculents & céréales'),
        ],
        dateLabel: date,
      );
      expect(keep.count, 2);
      expect(
        keep.text,
        '$title\n'
        'LÉGUMES\n'
        '\t1 Carotte\n'
        'FÉCULENTS & CÉRÉALES\n'
        '\t1 Riz',
      );
      expect(keep.text, isNot(contains('Poulet')));
      expect(keep.text, isNot(contains('Oignon')));
      expect(keep.text, isNot(contains('VIANDES')));
    });

    test('sans coché : titre, rayons en majuscules dans l\'ordre du magasin, '
        'une ligne par article', () {
      final keep = buildKeepText(
        items: [
          _item('Clous', 'Bricolage'),
          _item('Sel', 'Épices & herbes'),
          _item('Carotte', 'Légumes'),
          _item('Poulet', 'Viandes & charcuterie'),
          _item('Oignon', 'Légumes'),
        ],
        dateLabel: date,
      );
      expect(keep.count, 5);
      expect(
        keep.text,
        '$title\n'
        'VIANDES & CHARCUTERIE\n'
        '\t1 Poulet\n'
        'LÉGUMES\n'
        '\t1 Carotte\n'
        '\t1 Oignon\n'
        'ÉPICES & HERBES\n'
        '\t1 Sel\n'
        'BRICOLAGE\n'
        '\t1 Clous',
      );
    });

    test('tout coché : aucun article, le texte n\'a que son titre', () {
      final keep = buildKeepText(
        items: [
          _item('Poulet', 'Viandes & charcuterie', checked: true),
          _item('Carotte', 'Légumes', checked: true),
        ],
        dateLabel: date,
      );
      expect(keep.count, 0);
      expect(keep.text, title);
      expect(keep.text, isNot(contains('\t')));
    });

    test('liste vide : aucun article, le texte n\'a que son titre', () {
      final keep = buildKeepText(items: const [], dateLabel: date);
      expect(keep.count, 0);
      expect(keep.text, title);
    });
  });

  group('orderedShoppingCategories', () {
    test('l\'ordre du magasin d\'abord, les rayons inconnus ensuite', () {
      expect(
        orderedShoppingCategories([
          'Bricolage',
          'Autres',
          'Légumes',
          'Viandes & charcuterie',
          'Légumes',
        ]),
        ['Viandes & charcuterie', 'Légumes', 'Autres', 'Bricolage'],
      );
    });
  });
}
