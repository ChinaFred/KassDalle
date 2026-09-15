import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/recipe_search_scope.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le périmètre de « Où chercher des recettes ? » : quelles sources, et dans
/// quels livres. Persisté sous l'utilisateur, il doit survivre à un aller-
/// retour Firestore fidèle, et ne jamais écarter une recette qu'un filtre par
/// livre ne peut pas juger.
Recipe _recipe({String? bookId}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: 'r',
    titre: 'Recette',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
    bookId: bookId,
  );
}

void main() {
  group('aller-retour Firestore', () {
    test('toMap puis fromMap rend le même périmètre', () {
      const scope = RecipeSearchScope(
        sources: {RecipeSource.myRecipes, RecipeSource.familyRecipes},
        bookIds: {'livre_a', 'livre_b'},
      );
      final restored = RecipeSearchScope.fromMap(scope.toMap());
      expect(restored.sources, scope.sources);
      expect(restored.bookIds, scope.bookIds);
    });

    test(
      'un document sans champ sources se rabat sur les recettes validées',
      () {
        final scope = RecipeSearchScope.fromMap({'book_ids': []});
        expect(scope.sources, {RecipeSource.myRecipes});
      },
    );

    test('une clé de source inconnue est ignorée sans faire tout échouer', () {
      final scope = RecipeSearchScope.fromMap({
        'sources': ['myDrafts', 'clé_dun_futur_enum'],
        'book_ids': ['x'],
      });
      expect(scope.sources, {RecipeSource.myDrafts});
      expect(scope.bookIds, {'x'});
    });
  });

  group('matchesBook', () {
    test('un livre retenu passe, un autre est écarté', () {
      const scope = RecipeSearchScope(
        sources: {RecipeSource.myRecipes},
        bookIds: {'livre_a'},
      );
      expect(scope.matchesBook(_recipe(bookId: 'livre_a')), isTrue);
      expect(scope.matchesBook(_recipe(bookId: 'livre_b')), isFalse);
    });

    test('un livre vide (aucun coché) écarte tout ce qui a un livre', () {
      const scope = RecipeSearchScope(sources: {RecipeSource.myRecipes});
      expect(scope.matchesBook(_recipe(bookId: 'livre_a')), isFalse);
    });

    test('une recette sans livre n\'est jamais écartée', () {
      const scope = RecipeSearchScope(sources: {RecipeSource.myRecipes});
      expect(scope.matchesBook(_recipe(bookId: null)), isTrue);
      expect(scope.matchesBook(_recipe(bookId: '')), isTrue);
    });
  });
}
