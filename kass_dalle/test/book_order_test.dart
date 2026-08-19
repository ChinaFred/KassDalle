import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/domain/book_order.dart';

Book _book(String id) {
  final now = DateTime(2026, 1, 1);
  return Book(
    id: id,
    titre: 'Livre $id',
    auteur: 'Kassbi',
    langue: 'fr',
    tags: const [],
    createdBy: 'uid',
    createdAt: now,
    updatedAt: now,
  );
}

List<String> _ids(List<Book> books) => books.map((b) => b.id).toList();

void main() {
  group('applyBookOrder', () {
    test('sans ordre enregistré, la liste reçue est rendue telle quelle', () {
      final books = [_book('a'), _book('b'), _book('c')];
      expect(_ids(applyBookOrder(books, const [])), ['a', 'b', 'c']);
    });

    test('range les livres selon l\'ordre choisi', () {
      final books = [_book('a'), _book('b'), _book('c')];
      expect(_ids(applyBookOrder(books, const ['c', 'a', 'b'])), [
        'c',
        'a',
        'b',
      ]);
    });

    test('un identifiant disparu ne laisse pas de trou', () {
      final books = [_book('a'), _book('c')];
      expect(_ids(applyBookOrder(books, const ['c', 'b', 'a'])), ['c', 'a']);
    });

    test('les livres créés depuis vont à la fin, dans l\'ordre reçu', () {
      final books = [_book('neuf'), _book('a'), _book('autre'), _book('b')];
      expect(_ids(applyBookOrder(books, const ['b', 'a'])), [
        'b',
        'a',
        'neuf',
        'autre',
      ]);
    });

    test('un doublon dans l\'ordre ne duplique aucun livre', () {
      final books = [_book('a'), _book('b')];
      expect(_ids(applyBookOrder(books, const ['b', 'b', 'a'])), ['b', 'a']);
    });

    test('bookOrderIds rend les identifiants dans l\'ordre visible', () {
      expect(bookOrderIds([_book('b'), _book('a')]), ['b', 'a']);
    });
  });
}
