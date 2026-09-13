import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// La liste de courses du planning additionne les recettes et les garnitures.
///
/// Le riz d'une garniture et le riz d'une recette font une seule ligne ; une
/// garniture dans une autre unité reste à part, et chaque ligne dit d'où elle
/// vient.
Recipe _recipe(String titre, List<RecipeShoppingProduct> products) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: titre.toLowerCase(),
    titre: titre,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
    shoppingProducts: products,
  );
}

void main() {
  test('une garniture se fond dans la ligne de la recette', () {
    final out = planningAggregateProducts(
      [
        _recipe('Riz cantonais', const [
          RecipeShoppingProduct(name: 'Riz', qty: '200', unit: 'g'),
        ]),
      ],
      extras: const [
        (
          product: RecipeShoppingProduct(name: 'riz', qty: '280', unit: 'g'),
          source: 'Blanquette de veau · accompagnement',
        ),
      ],
    );
    expect(out.products, hasLength(1));
    expect(out.products.single.qty, '480');
    expect(out.products.single.unit, 'g');
    expect(
      out.sources['Riz'],
      'Riz cantonais · Blanquette de veau · accompagnement',
    );
  });

  test('une autre unité reste une autre ligne', () {
    final out = planningAggregateProducts(
      const [],
      extras: const [
        (
          product: RecipeShoppingProduct(
            name: 'Yaourt',
            qty: '4',
            unit: 'pièce',
          ),
          source: 'Lundi',
        ),
        (
          product: RecipeShoppingProduct(
            name: 'Yaourt',
            qty: '2',
            unit: 'pièce',
          ),
          source: 'Mardi',
        ),
        (
          product: RecipeShoppingProduct(name: 'Yaourt', qty: '500', unit: 'g'),
          source: 'Mercredi',
        ),
      ],
    );
    expect(out.products, hasLength(2));
    final pieces = out.products.firstWhere((p) => p.unit == 'pièce');
    expect(pieces.qty, '6');
    expect(out.sources['Yaourt'], isNotNull);
  });

  test('sans garniture, rien ne change', () {
    final out = planningAggregateProducts([
      _recipe('A', const [
        RecipeShoppingProduct(name: 'Sel', qty: '1', unit: 'pincée'),
      ]),
    ]);
    expect(out.products.single.name, 'Sel');
    expect(out.sources['Sel'], 'A');
  });
}
