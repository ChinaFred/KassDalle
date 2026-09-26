import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/ingredient_name.dart';
import 'package:kass_dalle/features/admin/data/nutrition_ingredients_repository.dart';
import 'package:kass_dalle/features/recipes/domain/nutrition_contributions.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le tableau des apports, calculé dans le domaine.
///
/// Il vivait dans l'écran Nutrition, où rien ne le vérifiait. Le PDF exporté
/// dessine maintenant le même tableau : deux calculs séparés auraient fini par
/// donner deux totaux à la même recette, sans qu'aucune erreur soit levée.
void main() {
  NutritionIngredientDoc profil(
    String nom, {
    required Map<String, double> per100g,
    bool notConsumed = false,
  }) => NutritionIngredientDoc(
    id: normalizeIngredientStrictId(nom),
    source: 'test',
    qualityStatus: 'verified',
    per100g: per100g,
    notConsumed: notConsumed,
  );

  Map<String, NutritionIngredientDoc> referentiel(
    List<NutritionIngredientDoc> docs,
  ) => {for (final doc in docs) doc.id: doc};

  Recipe recette({
    required List<RecipeIngredient> ingredients,
    RecipeNutritionSnapshot? nutrition,
  }) => Recipe(
    id: 'r1',
    titre: 'Beignets',
    langue: 'fr',
    rawCooklang: '>> titre: Beignets',
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    imageUrls: const [],
    createdBy: 'u1',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    ingredients: ingredients,
    nutrition: nutrition,
  );

  RecipeNutritionSnapshot bloc({
    List<String> duplicates = const [],
    RecipeAbsorbedOil? absorbedOil,
  }) => RecipeNutritionSnapshot(
    selectedPortions: 4,
    totalWeightG: 500,
    coverage: 1,
    coverageState: 'full',
    totals: const {'kcal': 1000},
    perPortion: const {'kcal': 250},
    per100g: const {'kcal': 200},
    quality: const RecipeNutritionQuality(score: 90, level: 'A'),
    duplicateIngredients: duplicates,
    absorbedOil: absorbedOil,
  );

  group('les apports par ingrédient', () {
    test('un poids en grammes donne la contribution du profil', () {
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
          ],
        ),
        nutritionById: referentiel([
          profil('farine', per100g: {'kcal': 350, 'protein_g': 10}),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      expect(table.rows.single.weightGrams, 200);
      expect(table.rows.single.perIngredient!['kcal'], 700);
      expect(table.totalFor('kcal'), 700);
      expect(table.knownWeight, 200);
    });

    test('un ingrédient sans profil ne contribue à rien, et se signale', () {
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
            RecipeIngredient(name: 'four à bois', qty: '1', unit: ''),
          ],
        ),
        nutritionById: referentiel([
          profil('farine', per100g: {'kcal': 350}),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      expect(table.missingCount, 1);
      expect(table.totalFor('kcal'), 700);
    });

    test('le bain de friture reste affiché mais sort du total', () {
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
            RecipeIngredient(name: 'huile de friture', qty: '1000', unit: 'g'),
          ],
        ),
        nutritionById: referentiel([
          profil('farine', per100g: {'kcal': 350}),
          profil('huile de friture', per100g: {'kcal': 884}, notConsumed: true),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      // Le bain pèse 8840 kcal à lui seul : compté, il écraserait la recette.
      expect(table.totalFor('kcal'), 700);
      expect(table.notConsumedCount, 1);
      expect(table.rows.last.perIngredient!['kcal'], 8840);
      expect(table.knownWeight, 200);
    });

    test('une ligne déjà comptée plus haut sort du total elle aussi', () {
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'poulet', qty: '1000', unit: 'g'),
            RecipeIngredient(name: 'blanc de poulet', qty: '400', unit: 'g'),
          ],
          nutrition: bloc(duplicates: const ['blanc de poulet']),
        ),
        nutritionById: referentiel([
          profil('poulet', per100g: {'kcal': 200}),
          profil('blanc de poulet', per100g: {'kcal': 110}),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      expect(table.duplicateCount, 1);
      expect(table.totalFor('kcal'), 2000);
    });

    test('l\'huile absorbée entre au total sans avoir de ligne', () {
      const oil = RecipeAbsorbedOil(
        grams: 80,
        absorptionRatio: 0.1,
        friedWeightG: 800,
        sourceName: 'huile de friture',
        capped: false,
        contribution: {'kcal': 707},
      );
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
            RecipeIngredient(name: 'huile de friture', qty: '1000', unit: 'g'),
          ],
          nutrition: bloc(absorbedOil: oil),
        ),
        nutritionById: referentiel([
          profil('farine', per100g: {'kcal': 350}),
          profil('huile de friture', per100g: {'kcal': 884}, notConsumed: true),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      expect(table.totalFor('kcal'), 700 + 707);
      // Les 80 g mangés s'ajoutent au poids, le litre du bain non.
      expect(table.knownWeight, 280);
      // Le bain est listé : la ligne dérivée se range dessous.
      expect(table.hasOrphanAbsorbedOil, isFalse);
      expect(table.isAbsorbedOilSource(table.rows.last), isTrue);
    });

    test('un bain que la recette ne liste pas laisse sa ligne orpheline', () {
      const oil = RecipeAbsorbedOil(
        grams: 80,
        absorptionRatio: 0.1,
        friedWeightG: 800,
        sourceName: 'huile de tournesol',
        capped: false,
        contribution: {'kcal': 707},
      );
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
          ],
          nutrition: bloc(absorbedOil: oil),
        ),
        nutritionById: referentiel([
          profil('farine', per100g: {'kcal': 350}),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      expect(table.hasOrphanAbsorbedOil, isTrue);
    });

    test(
      'une ligne vide de la recette ne devient pas une ligne du tableau',
      () {
        final table = buildNutritionContributions(
          recipe: recette(
            ingredients: const [
              RecipeIngredient(name: '  ', qty: '', unit: ''),
              RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
            ],
          ),
          nutritionById: referentiel([
            profil('farine', per100g: {'kcal': 350}),
          ]),
          unitOverrides: const {},
          unitInfos: const {},
        );
        expect(table.rows.length, 1);
      },
    );
  });

  group('la légende sous le tableau', () {
    test('ne dit rien quand tout est connu et consommé', () {
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
          ],
        ),
        nutritionById: referentiel([
          profil('farine', per100g: {'kcal': 350}),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      expect(table.needsLegend, isFalse);
      expect(nutritionLegendEntries(table), isEmpty);
    });

    test('nomme ce qui est écarté et ce qui manque', () {
      final table = buildNutritionContributions(
        recipe: recette(
          ingredients: const [
            RecipeIngredient(name: 'huile de friture', qty: '1000', unit: 'g'),
            RecipeIngredient(name: 'four à bois', qty: '1', unit: ''),
          ],
        ),
        nutritionById: referentiel([
          profil('huile de friture', per100g: {'kcal': 884}, notConsumed: true),
        ]),
        unitOverrides: const {},
        unitInfos: const {},
      );
      final kinds = nutritionLegendEntries(table).map((e) => e.kind);
      expect(kinds, contains(NutritionLegendKind.notConsumed));
      expect(kinds, contains(NutritionLegendKind.missing));
    });
  });

  group('une quantité que la recette ne donne pas', () {
    NutritionContributionTable tableDe(List<RecipeIngredient> ingredients) =>
        buildNutritionContributions(
          recipe: recette(ingredients: ingredients),
          nutritionById: referentiel([
            profil('basilic', per100g: {'kcal': 23}),
            profil('sel', per100g: {'sodium_mg': 38758}),
          ]),
          unitOverrides: const {},
          unitInfos: const {},
        );

    test('« brin de basilic » se lit un brin et se pèse', () {
      final table = tableDe(const [
        RecipeIngredient(name: 'basilic', qty: '', unit: 'brin'),
      ]);
      final row = table.rows.single;
      expect(row.isMissing, isFalse);
      expect(row.weightGrams, 2);
      expect(row.quantityAssumed, isTrue);
      expect(nutritionAssumedUnitPhrase(row), 'un brin');
    });

    test('la légende parle de pincée quand il n\'y a que des pincées', () {
      final table = tableDe(const [
        RecipeIngredient(name: 'sel', qty: '', unit: ''),
      ]);
      expect(nutritionAssumedUnitPhrase(table.rows.single), 'une pincée');
      final legende = nutritionLegendEntries(
        table,
      ).singleWhere((e) => e.kind == NutritionLegendKind.assumedQuantity);
      expect(
        legende.label,
        '1 ingrédient(s) sans quantité, comptés à la pincée',
      );
    });

    test('la légende nomme l\'unité en général dès qu\'un brin s\'y mêle', () {
      final table = tableDe(const [
        RecipeIngredient(name: 'sel', qty: '', unit: ''),
        RecipeIngredient(name: 'basilic', qty: '', unit: 'brin'),
      ]);
      final legende = nutritionLegendEntries(
        table,
      ).singleWhere((e) => e.kind == NutritionLegendKind.assumedQuantity);
      expect(
        legende.label,
        '2 ingrédient(s) sans quantité, comptés pour une unité '
        '(pincée, brin, bouquet…)',
      );
    });
  });
}
