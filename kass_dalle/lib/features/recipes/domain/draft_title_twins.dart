import 'recipe.dart';

/// Les autres brouillons du même livre qui portent le même titre.
///
/// [first] est le premier trouvé dans la file ; [others] compte les autres
/// brouillons rapprochés en plus de lui.
class DraftTitleTwins {
  const DraftTitleTwins({required this.first, this.others = 0});

  final Recipe first;
  final int others;
}

/// Rapproche les brouillons de la file par `titre_key`, dans le même livre.
///
/// Le serveur ne marque que le brouillon écrit en second : le plus ancien des
/// deux n'affichait rien. Cette fonction rapproche les deux côtés à
/// l'affichage, sans rien stocker. Elle compare la clé posée par le serveur
/// ([Recipe.titreKey]) et ne normalise aucun titre.
///
/// Pas de rapprochement sans livre, sans clé, ou quand les deux pages sont
/// connues et différentes (même règle que le serveur : « Pâte brisée » existe
/// à plusieurs pages d'un même livre). Le résultat est indexé par `Recipe.id`.
Map<String, DraftTitleTwins> draftTitleTwins(List<Recipe> drafts) {
  final result = <String, DraftTitleTwins>{};
  for (final draft in drafts) {
    final bookId = draft.bookId;
    final key = draft.titreKey;
    if (bookId == null || bookId.isEmpty || key == null || key.isEmpty) {
      continue;
    }
    final twins = drafts.where(
      (o) =>
          o.id != draft.id &&
          o.bookId == bookId &&
          o.titreKey == key &&
          _pagesCompatible(draft.pageNumber, o.pageNumber),
    );
    if (twins.isEmpty) continue;
    result[draft.id] = DraftTitleTwins(
      first: twins.first,
      others: twins.length - 1,
    );
  }
  return result;
}

bool _pagesCompatible(int? a, int? b) => a == null || b == null || a == b;
