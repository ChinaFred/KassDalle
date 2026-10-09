import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/presentation/delete_book_flow.dart';

/// Les messages de suppression d'un livre disent ce qui reste : les pages
/// ajoutées par d'autres membres ne sont ni supprimées ni détachées par le
/// créateur du livre (v0.23.8).
void main() {
  test('aucune page d\'un autre : rien à annoncer', () {
    expect(deleteBookOthersNotice(0), isEmpty);
    expect(
      deleteBookSuccessMessage(deleteAll: true, othersCount: 0),
      'Livre et recettes supprimés.',
    );
  });

  // Les pages privées des autres ne sont pas lisibles : le chiffre est un
  // minimum.
  test('des pages d\'autres membres : « au moins N »', () {
    expect(deleteBookOthersNotice(2), contains('Au moins 2 pages ajoutées'));
    expect(deleteBookOthersNotice(1), contains('sera conservée'));
    expect(
      deleteBookSuccessMessage(deleteAll: true, othersCount: 2),
      contains('Livre et vos recettes supprimés.'),
    );
  });

  test('livre privé ou décompte en panne : on prévient sans chiffre', () {
    expect(deleteBookOthersNotice(-1), startsWith('Les pages éventuellement'));
    expect(
      deleteBookSuccessMessage(deleteAll: false, othersCount: -1),
      contains('restent chez leurs auteurs'),
    );
  });

  // Un administrateur, même sur son propre livre, efface aussi les pages des
  // autres : le flux passe `actsForAll` dès que le lecteur est admin.
  test('un administrateur : jamais « vos »', () {
    final question = deleteBookQuestion(bookTitre: 'X', actsForAll: true);
    expect(question, contains('pour tous leurs auteurs'));
    expect(question, isNot(contains('vos')));
    for (final deleteAll in [true, false]) {
      expect(
        deleteBookSuccessMessage(
          deleteAll: deleteAll,
          othersCount: 0,
          actsForAll: true,
        ),
        isNot(contains('vos')),
      );
    }
  });
}
