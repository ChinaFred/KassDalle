import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/allergens.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_filter.dart';
import 'package:kass_dalle/features/search/domain/explore_facets.dart';
import 'package:kass_dalle/features/search/domain/search_models.dart';

/// Le filtre local de l'écran Explorer : texte, filtres, tri, et recettes
/// écartées faute de donnée. Tout se calcule sur l'appareil, sans IA.
void main() {
  RecipeNutritionSnapshot nutrition(double kcalTotal, int portions) =>
      RecipeNutritionSnapshot(
        selectedPortions: portions,
        totalWeightG: 1000,
        coverage: 1,
        coverageState: 'complete',
        totals: {'kcal': kcalTotal},
        perPortion: {'kcal': kcalTotal / portions},
        per100g: null,
        quality: const RecipeNutritionQuality(score: 50, level: 'B'),
      );

  Recipe recipe(
    String id, {
    String? titre,
    List<String> ingredients = const [],
    List<String> dishTypes = const [],
    List<String> cuisines = const [],
    List<String> themes = const [],
    int? prep,
    int? cook,
    int? rest,
    int? portions,
    RecipeNutritionSnapshot? nutri,
    RecipeAllergens? allergens,
    String createdBy = 'moi',
    DateTime? createdAt,
    String? mealRole,
  }) => Recipe(
    id: id,
    titre: titre ?? 'Recette $id',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(
      dishTypes: dishTypes,
      cuisines: cuisines,
      themes: themes,
      prepTime: prep,
      cookTime: cook,
      restTime: rest,
      mealRole: mealRole,
    ),
    ingredientsIndex: ingredients,
    createdBy: createdBy,
    createdAt: createdAt ?? DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    portions: portions,
    nutrition: nutri,
    allergens: allergens,
  );

  group('texte', () {
    final crepes = recipe(
      'crepes',
      titre: 'Crêpes de la Chandeleur',
      ingredients: const ['farine', 'œufs', 'lait'],
      cuisines: const ['Française'],
    );
    final curry = recipe(
      'curry',
      titre: 'Curry de pois chiches',
      ingredients: const ['pois chiches', 'lait de coco'],
      themes: const ['Végétarien'],
    );

    List<String> ids(String q) => applyRecipeFilter([
      crepes,
      curry,
    ], query: q).recipes.map((r) => r.id).toList();

    test('sans accents ni casse', () {
      expect(ids('CREPES'), ['crepes']);
      expect(ids('vegetarien'), ['curry']);
      expect(ids('francaise'), ['crepes']);
    });

    test('dans les ingrédients et les étiquettes', () {
      expect(ids('coco'), ['curry']);
      expect(ids('lait'), containsAll(['crepes', 'curry']));
    });

    test('tous les mots doivent être trouvés', () {
      expect(ids('lait farine'), ['crepes']);
      expect(ids('lait poulet'), isEmpty);
    });

    test('un texte vide garde tout', () {
      expect(ids('   '), hasLength(2));
    });
  });

  group('ET entre filtres, OU dans un filtre', () {
    final plat = recipe(
      'plat',
      dishTypes: const ['Plat'],
      cuisines: const ['Italienne'],
    );
    final dessert = recipe(
      'dessert',
      dishTypes: const ['Dessert'],
      cuisines: const ['Française'],
    );
    final entree = recipe(
      'entree',
      dishTypes: const ['Entrée'],
      cuisines: const ['Italienne'],
    );

    test('OU dans une dimension', () {
      const f = RecipeFilter(dishTypes: {'plat', 'dessert'});
      expect(
        applyRecipeFilter([
          plat,
          dessert,
          entree,
        ], filter: f).recipes.map((r) => r.id),
        unorderedEquals(['plat', 'dessert']),
      );
    });

    test('ET entre dimensions', () {
      const f = RecipeFilter(
        dishTypes: {'plat', 'dessert'},
        cuisines: {'italienne'},
      );
      expect(
        applyRecipeFilter([
          plat,
          dessert,
          entree,
        ], filter: f).recipes.map((r) => r.id),
        ['plat'],
      );
    });
  });

  group('temps total', () {
    test('préparation + cuisson, le repos n\'est pas compté', () {
      expect(
        recipeTotalMinutes(recipe('a', prep: 20, cook: 25, rest: 600)),
        45,
      );
    });

    test('une seule des deux valeurs suffit', () {
      expect(recipeTotalMinutes(recipe('a', prep: 10)), 10);
      expect(recipeTotalMinutes(recipe('a', cook: 40)), 40);
      expect(recipeTotalMinutes(recipe('a')), isNull);
    });

    test('sans durée : écartée et comptée', () {
      final out = applyRecipeFilter([
        recipe('vite', prep: 10),
        recipe('long', prep: 90),
        recipe('nul'),
      ], filter: const RecipeFilter(maxTotalMinutes: 30));
      expect(out.recipes.map((r) => r.id), ['vite']);
      expect(out.missingData[RecipeFilterDimension.totalTime], 1);
      expect(
        missingDataLine(RecipeFilterDimension.totalTime, 1),
        '1 recette sans durée écartée',
      );
    });

    test('une durée estimée se branche par le contexte', () {
      final ctx = RecipeFilterContext(
        totalMinutesOf: (r) => recipeTotalMinutes(r) ?? 20,
      );
      final out = applyRecipeFilter(
        [recipe('nul')],
        filter: const RecipeFilter(maxTotalMinutes: 30),
        context: ctx,
      );
      expect(out.recipes, hasLength(1));
    });
  });

  group('calories par portion', () {
    test('totaux / parts, calculés à l\'affichage', () {
      // Bloc calculé pour 4 parts, recette passée à 2 parts.
      final r = recipe('r', portions: 2, nutri: nutrition(1600, 4));
      expect(recipeCaloriesPerPortion(r), 800);
    });

    test('filtre max et recettes sans calories comptées', () {
      final out = applyRecipeFilter([
        recipe('leger', portions: 4, nutri: nutrition(1600, 4)),
        recipe('lourd', portions: 2, nutri: nutrition(1600, 2)),
        recipe('inconnu'),
        recipe('inconnu2'),
      ], filter: const RecipeFilter(maxCaloriesPerPortion: 600));
      expect(out.recipes.map((r) => r.id), ['leger']);
      expect(out.missingData[RecipeFilterDimension.maxCalories], 2);
      expect(
        missingDataLine(RecipeFilterDimension.maxCalories, 2),
        '2 recettes sans calories écartées',
      );
    });
  });

  group('exclusions', () {
    test('sans l\'ingrédient : l\'un OU l\'autre écarte', () {
      final out = applyRecipeFilter(
        [
          recipe('a', ingredients: const ['Coriandre fraîche']),
          recipe('b', ingredients: const ['oignons']),
          recipe('c', ingredients: const ['laitue', 'tomate']),
          recipe('d'),
        ],
        filter: const RecipeFilter(
          excludedIngredients: {'coriandre', 'oignon', 'lait'},
        ),
      );
      // « laitue » n'est pas du lait ; « oignons » est un oignon.
      expect(out.recipes.map((r) => r.id), ['c']);
      expect(out.missingData[RecipeFilterDimension.excludedIngredient], 1);
    });

    test(
      'sans allergène : analyse incomplète ou absente écartée et comptée',
      () {
        final out = applyRecipeFilter([
          recipe(
            'sans',
            allergens: const RecipeAllergens(
              present: ['gluten'],
              complete: true,
            ),
          ),
          recipe(
            'avec',
            allergens: const RecipeAllergens(present: ['lait'], complete: true),
          ),
          recipe(
            'incomplete',
            allergens: const RecipeAllergens(present: [], complete: false),
          ),
          recipe('jamais'),
        ], filter: const RecipeFilter(excludedAllergens: {'lait', 'oeuf'}));
        expect(out.recipes.map((r) => r.id), ['sans']);
        expect(out.missingData[RecipeFilterDimension.excludedAllergen], 2);
        expect(
          missingDataLine(RecipeFilterDimension.excludedAllergen, 2),
          '2 recettes sans analyse d\'allergènes écartées',
        );
      },
    );
  });

  test(
    'une recette écartée par un autre filtre ne compte pas comme sans donnée',
    () {
      final out = applyRecipeFilter([
        recipe('dessert-sans-duree', dishTypes: const ['Dessert']),
      ], filter: const RecipeFilter(dishTypes: {'plat'}, maxTotalMinutes: 30));
      expect(out.recipes, isEmpty);
      expect(out.missingData, isEmpty);
    },
  );

  group('note minimale et tri', () {
    final a = recipe(
      'a',
      titre: 'Bœuf',
      prep: 60,
      createdAt: DateTime(2026, 3),
    );
    final b = recipe(
      'b',
      titre: 'Artichaut',
      prep: 10,
      createdAt: DateTime(2026, 1),
    );
    final c = recipe('c', titre: 'Éclair', createdAt: DateTime(2026, 2));
    const ctx = RecipeFilterContext(myRatings: {'a': 9, 'b': 6});

    List<String> sorted(RecipeSort s) => applyRecipeFilter(
      [a, b, c],
      context: ctx,
      sort: s,
    ).recipes.map((r) => r.id).toList();

    test('mieux notées : note du lecteur, sans note en fin', () {
      expect(sorted(RecipeSort.bestRated), ['a', 'b', 'c']);
    });

    test('plus rapides : sans durée en fin', () {
      expect(sorted(RecipeSort.fastest), ['b', 'a', 'c']);
    });

    test('plus récentes', () {
      expect(sorted(RecipeSort.newest), ['a', 'c', 'b']);
    });

    test('titre A → Z, sans accents', () {
      expect(sorted(RecipeSort.title), ['b', 'a', 'c']);
    });

    test('note minimale : sans note écartée et comptée', () {
      final out = applyRecipeFilter(
        [a, b, c],
        filter: const RecipeFilter(minRating: 7),
        context: ctx,
      );
      expect(out.recipes.map((r) => r.id), ['a']);
      expect(out.missingData[RecipeFilterDimension.minRating], 1);
    });
  });

  group('facettes', () {
    test('nombre par valeur, auteur du lecteur en premier', () {
      final facets = exploreFacets([
        recipe('1', dishTypes: const ['Plat'], createdBy: 'Autre'),
        recipe('2', dishTypes: const ['plat'], createdBy: 'Autre', prep: 10),
        recipe(
          '3',
          dishTypes: const ['Dessert'],
          createdBy: 'moi',
          mealRole: 'plat',
        ),
      ], myUid: 'moi');
      expect(facets.dishTypes.first.label, isIn(['Plat', 'plat']));
      expect(facets.dishTypes.first.count, 2);
      // L'identifiant d'un compte n'est pas une étiquette : pas de minuscules.
      expect(facets.authors.map((f) => f.key), ['moi', 'Autre']);
      expect(facets.mealRoles.single.label, 'Plat');
      expect(facets.totalTimes.first.count, 1);
      expect(facets.allergens, hasLength(kAllergenKeys.length));
    });
  });

  group('préférence enregistrée', () {
    test('aller-retour sources, filtres, tri', () {
      const prefs = ExplorePreferences(
        sources: SearchParams(
          myRecipes: true,
          familyRecipes: false,
          includeDrafts: true,
        ),
        filter: RecipeFilter(
          dishTypes: {'plat'},
          excludedAllergens: {'lait'},
          maxTotalMinutes: 30,
          minRating: 8,
          maxCaloriesPerPortion: 600,
        ),
        sort: RecipeSort.fastest,
      );
      final back = ExplorePreferences.fromMap(prefs.toMap());
      expect(back.sources, prefs.sources);
      expect(back.filter.signature, prefs.filter.signature);
      expect(back.sort, RecipeSort.fastest);
    });

    test('une préférence abîmée reprend les valeurs par défaut', () {
      final back = ExplorePreferences.fromMap({
        'sort': 42,
        'filters': {'dish_types': 'x', 'max_total_minutes': -5},
      });
      expect(back.sort, RecipeSort.bestRated);
      expect(back.filter.isEmpty, isTrue);
      expect(back.sources, const SearchParams());
    });

    test('le filtre change de signature quand une valeur change', () {
      const f = RecipeFilter(dishTypes: {'plat'});
      expect(
        f.signature,
        isNot(f.toggle(RecipeFilterDimension.cuisine, 'x').signature),
      );
      expect(f.toggle(RecipeFilterDimension.dishType, 'plat').isEmpty, isTrue);
      expect(
        const RecipeFilter(
          maxTotalMinutes: 30,
        ).toggle(RecipeFilterDimension.totalTime, '30').maxTotalMinutes,
        isNull,
      );
    });
  });

  test('Chercher sur Google : le texte tel quel, plus « recette »', () {
    final uri = googleRecipeSearchUri(' tarte tatin ');
    expect(uri.host, 'www.google.com');
    expect(uri.queryParameters['q'], 'tarte tatin recette');
  });

  test('une idée enregistrée ne retient plus la sortie de l\'écran', () {
    final a = GeneratedRecipeSuggestion(
      recipe: recipe('a'),
      justification: 'j',
      variantLabel: 'Fidèle',
    );
    final b = GeneratedRecipeSuggestion(
      recipe: recipe('b'),
      justification: 'j',
      variantLabel: 'Rapide',
    );
    expect(AiIdeasSuccess('q', [a, b]).hasUnsaved, isTrue);
    expect(AiIdeasSuccess('q', [a, b], saved: {a: 'd1'}).hasUnsaved, isTrue);
    expect(
      AiIdeasSuccess('q', [a, b], saved: {a: 'd1', b: 'd2'}).hasUnsaved,
      isFalse,
    );
  });
}
