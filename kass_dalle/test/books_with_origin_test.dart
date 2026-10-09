import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_meta_panel.dart';

import 'support/test_backend.dart';

/// Une page rangée dans le livre d'un autre membre garde ce livre en tête du
/// sélecteur : on peut y revenir après avoir choisi un de ses livres.
void main() {
  final mine = [testBook(id: 'a'), testBook(id: 'b')];

  test('livre d\'origine hors liste : ajouté en tête', () {
    final recipe = testRecipe(bookId: 'chez-marie');
    final books = booksWithOrigin(mine, recipe);
    expect(books.map((b) => b.id), ['chez-marie', 'a', 'b']);
  });

  test('livre d\'origine dans la liste, ou sans livre : liste inchangée', () {
    expect(
      identical(booksWithOrigin(mine, testRecipe(bookId: 'a')), mine),
      isTrue,
    );
    expect(identical(booksWithOrigin(mine, testRecipe()), mine), isTrue);
    expect(identical(booksWithOrigin(mine, null), mine), isTrue);
  });
}
