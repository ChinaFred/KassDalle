import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_candidates.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Ce que l'IA a le droit de proposer pour un repas.
///
/// Une recette écartée qui revient ne lève aucune erreur : elle s'affiche,
/// suggérée à nouveau, et le lecteur la refuse une deuxième fois.
void main() {
  Recipe recipe(String id) => Recipe(
    id: id,
    titre: 'Recette $id',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'u1',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
  );
  final corpus = [recipe('a'), recipe('b'), recipe('c')];

  test('sans rien à écarter, le corpus entier', () {
    expect(candidatesForMeal(corpus), same(corpus));
  });

  test('la recette en place ne se repropose pas', () {
    expect(candidatesForMeal(corpus, currentRecipeId: 'b').map((r) => r.id), [
      'a',
      'c',
    ]);
  });

  test('les recettes écartées non plus', () {
    expect(
      candidatesForMeal(
        corpus,
        currentRecipeId: 'a',
        dismissedRecipeIds: const {'c'},
      ).map((r) => r.id),
      ['b'],
    );
  });

  test('tout écarté : rien à proposer, et non le corpus entier', () {
    expect(
      candidatesForMeal(corpus, dismissedRecipeIds: const ['a', 'b', 'c']),
      isEmpty,
    );
  });

  test('un identifiant vide n\'écarte personne', () {
    expect(candidatesForMeal(corpus, currentRecipeId: '').length, 3);
  });
}
