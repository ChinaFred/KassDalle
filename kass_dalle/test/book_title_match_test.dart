import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/domain/book_title_match.dart';

void main() {
  group('bookTitleMatches', () {
    test('une saisie vide correspond à tous les titres', () {
      expect(bookTitleMatches('Desserts', ''), isTrue);
      expect(bookTitleMatches('Desserts', '   '), isTrue);
    });

    test('cherche n\'importe où dans le titre, pas seulement au début', () {
      expect(bookTitleMatches('Mes salades d\'été', 'salade'), isTrue);
      expect(bookTitleMatches('Mes salades d\'été', 'mes'), isTrue);
      expect(bookTitleMatches('Mes salades d\'été', 'ete'), isTrue);
    });

    test('ignore les majuscules', () {
      expect(bookTitleMatches('COOK', 'cook'), isTrue);
      expect(bookTitleMatches('cook', 'COOK'), isTrue);
    });

    test('ignore les accents, dans le titre comme dans la saisie', () {
      expect(bookTitleMatches('Pâtisserie', 'patis'), isTrue);
      expect(bookTitleMatches('Patisserie', 'pâtis'), isTrue);
      expect(bookTitleMatches('Mes créations', 'creation'), isTrue);
    });

    test('une apostrophe et une espace se valent', () {
      expect(bookTitleMatches('Mes créations Kass\'Dalle', 'kass d'), isTrue);
      expect(bookTitleMatches('Mes créations Kass\'Dalle', 'kass\'d'), isTrue);
    });

    test('une espace en fin de saisie ne change pas le résultat', () {
      expect(bookTitleMatches('Desserts', 'desserts '), isTrue);
    });

    test('rejette un titre qui ne contient pas la saisie', () {
      expect(bookTitleMatches('Desserts', 'soupe'), isFalse);
      expect(bookTitleMatches('Desserts', 'desserts d\'été'), isFalse);
    });
  });

  group('bookTitleEquals', () {
    test('égalité à l\'accent, à la casse et à la ponctuation près', () {
      expect(bookTitleEquals('Pâtisserie', 'patisserie'), isTrue);
      expect(bookTitleEquals('Kass\'Dalle', 'kass dalle'), isTrue);
    });

    test('un titre plus long n\'est pas égal', () {
      expect(bookTitleEquals('COOK 2', 'cook'), isFalse);
    });
  });
}
