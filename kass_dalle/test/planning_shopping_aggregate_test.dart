import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// La liste de courses du planning additionne les recettes et les garnitures.
///
/// Le riz d'une garniture et le riz d'une recette font une seule ligne ; une
/// garniture dans une autre unité reste à part, sous le même nom ; et chaque
/// ligne dit d'où elle vient, et pour combien.
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
    expect(out.products.single.name, 'Riz');
    expect(out.products.single.qty, '480');
    expect(out.products.single.unit, 'g');
    expect(
      out.sources['Riz'],
      'Riz cantonais (200 g) · Blanquette de veau · accompagnement (280 g)',
    );
  });

  test(
    'une autre famille d\'unité reste une autre entrée, sous le même nom',
    () {
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
            product: RecipeShoppingProduct(
              name: 'Yaourt',
              qty: '500',
              unit: 'g',
            ),
            source: 'Mercredi',
          ),
        ],
      );
      expect(out.products, hasLength(2));
      final pieces = out.products.firstWhere((p) => p.unit == 'pièce');
      expect(pieces.qty, '6');
      expect(out.products.map((p) => p.name).toSet(), {'Yaourt'});
      expect(out.sources['Yaourt'], 'Lundi (4) · Mardi (2) · Mercredi (500 g)');
    },
  );

  test(
    'deux unités sans conversion : deux entrées, une provenance chacune',
    () {
      final out = planningAggregateProducts([
        _recipe('Curry de poulet', const [
          RecipeShoppingProduct(name: 'lait de coco', qty: '250', unit: 'g'),
        ]),
        _recipe('Riz au lait de coco', const [
          RecipeShoppingProduct(name: 'Lait de coco', qty: '400', unit: 'ml'),
        ]),
      ]);
      expect(out.products, hasLength(2));
      expect(out.products.map((p) => p.name).toSet(), {'lait de coco'});
      expect(
        out.sources['lait de coco'],
        'Curry de poulet (250 g) · Riz au lait de coco (400 ml)',
      );
    },
  );

  test('kilo et grammes s\'additionnent entre recettes', () {
    final out = planningAggregateProducts([
      _recipe('Gratin', const [
        RecipeShoppingProduct(name: 'pommes de terre', qty: '1', unit: 'kg'),
      ]),
      _recipe('Purée', const [
        RecipeShoppingProduct(name: 'pomme de terre', qty: '500', unit: 'g'),
      ]),
    ]);
    expect(out.products.single.qty, '1,5');
    expect(out.products.single.unit, 'kg');
    expect(out.sources['pommes de terre'], 'Gratin (1 kg) · Purée (500 g)');
  });

  test(
    'la même recette deux jours de suite compte une fois dans la provenance',
    () {
      final out = planningAggregateProducts([
        _recipe('Curry', const [
          RecipeShoppingProduct(name: 'riz', qty: '200', unit: 'g'),
        ]),
        _recipe('Curry', const [
          RecipeShoppingProduct(name: 'riz', qty: '200', unit: 'g'),
        ]),
      ]);
      expect(out.products.single.qty, '400');
      expect(out.sources['riz'], 'Curry (400 g)');
    },
  );

  test('sans garniture, rien ne change', () {
    final out = planningAggregateProducts([
      _recipe('A', const [
        RecipeShoppingProduct(name: 'Sel', qty: '1', unit: 'pincée'),
      ]),
    ]);
    expect(out.products.single.name, 'Sel');
    expect(out.sources['Sel'], 'A (1 pincée)');
  });
}
