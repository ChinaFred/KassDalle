import 'book.dart';

/// Ordre d'affichage de la bibliothèque, choisi par glisser-déposer.
///
/// L'ordre est une **préférence de lecteur**, pas une propriété du livre :
/// une même bibliothèque est lue par plusieurs membres de la famille, chacun
/// range la sienne comme il l'entend. Il vit donc sous l'utilisateur
/// (`users/{uid}/preferences/book_order`) et n'écrit jamais dans `books`.
///
/// [order] est une simple liste d'identifiants. Elle survit aux livres
/// supprimés (les identifiants inconnus sont ignorés) comme aux livres créés
/// depuis (ils ne sont dans aucun rang et se rangent à la fin, dans l'ordre
/// reçu — le plus récemment modifié d'abord).
List<Book> applyBookOrder(List<Book> books, List<String> order) {
  if (order.isEmpty || books.length < 2) return books;

  final rank = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    rank.putIfAbsent(order[i], () => i);
  }

  final ranked = <Book>[];
  final unranked = <Book>[];
  for (final book in books) {
    (rank.containsKey(book.id) ? ranked : unranked).add(book);
  }
  ranked.sort((a, b) => rank[a.id]!.compareTo(rank[b.id]!));

  return [...ranked, ...unranked];
}

/// Liste d'identifiants à persister pour l'ordre visible [books].
List<String> bookOrderIds(List<Book> books) =>
    books.map((b) => b.id).toList(growable: false);
