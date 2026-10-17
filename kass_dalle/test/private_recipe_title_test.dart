import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/private_recipe_title.dart';

void main() {
  test('une entrée complète devient une recette creuse privée', () {
    final list = parsePrivateRecipeTitles({
      'titles': [
        {
          'id': 'r1',
          'titre': 'Gâteau cadeau',
          'bookTitre': 'Livre secret',
          'createdBy': 'uidA',
        },
      ],
    });
    expect(list, hasLength(1));
    final r = list.single.toRecipe();
    expect(r.id, 'r1');
    expect(r.titre, 'Gâteau cadeau');
    expect(r.bookTitre, 'Livre secret');
    expect(r.isPrivate, isTrue);
    expect(r.rawCooklang, isEmpty);
    expect(r.imageUrls, isEmpty);
    expect(r.ingredientsIndex, isEmpty);
  });

  test('les entrées illisibles sont ignorées', () {
    final list = parsePrivateRecipeTitles({
      'titles': [
        {'id': '', 'titre': 'x'},
        {'id': 'a'},
        'texte',
        {'id': 'b', 'titre': 'Soupe'},
      ],
    });
    expect(list.map((t) => t.id), ['b']);
    expect(list.single.bookTitre, isNull);
  });

  test('une réponse mal formée donne une liste vide', () {
    expect(parsePrivateRecipeTitles(null), isEmpty);
    expect(parsePrivateRecipeTitles({'titles': 3}), isEmpty);
  });
}
