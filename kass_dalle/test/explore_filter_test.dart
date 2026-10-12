import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/allergens.dart';
import 'package:kass_dalle/features/recipes/domain/estimated_times.dart';
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
    RecipeEstimatedTimes? estimated,
    String cooklang = '',
    String createdBy = 'moi',
    DateTime? createdAt,
    String? mealRole,
  }) => Recipe(
    id: id,
    titre: titre ?? 'Recette $id',
    langue: 'fr',
    rawCooklang: cooklang,
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
    estimatedTimes: estimated,
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
      expect(ids('lait chandeleur'), ['crepes']);
      expect(ids('lait poulet'), isEmpty);
    });

    test('un texte vide garde tout', () {
      expect(ids('   '), hasLength(2));
    });
  });

  group('texte : début de mot, sections, petits ingrédients', () {
    final sable = recipe(
      'sable',
      titre: 'Sablés bretons',
      ingredients: const ['farine', 'beurre demi-sel', 'sucre'],
    );
    final poisson = recipe(
      'poisson',
      titre: 'Cabillaud rôti',
      ingredients: const ['cabillaud', 'poivre blanc', 'citron'],
    );
    final blanquette = recipe(
      'blanquette',
      titre: 'Blanquette de veau',
      ingredients: const ['veau', 'carottes', 'crème'],
      cuisines: const ['Française'],
    );
    final pouletCoreen = recipe(
      'poulet_coreen',
      titre: 'Poulet coréen',
      ingredients: const ['poulet', 'gochujang'],
    );
    final bibimbap = recipe(
      'bibimbap',
      titre: 'Bibimbap',
      ingredients: const ['riz', 'boeuf', 'gousse d\'ail'],
      cuisines: const ['Coréenne'],
    );
    final pouletCoco = recipe(
      'poulet_coco',
      titre: 'Poulet au curry',
      ingredients: const ['poulet', 'lait de coco', 'huile d\'olive'],
    );
    final ailTitre = recipe(
      'ail_titre',
      titre: 'Soupe à l\'ail',
      ingredients: const ['ail', 'pain'],
    );
    final ailIngredient = recipe(
      'ail_ingredient',
      titre: 'Gigot rôti',
      ingredients: const ['gigot', 'gousses d\'ail', 'romarin'],
    );
    final ailes = recipe(
      'ailes',
      titre: 'Poêlée de légumes',
      ingredients: const ['ailes de poulet', 'courgettes'],
    );
    final corpus = [
      sable,
      poisson,
      blanquette,
      pouletCoreen,
      bibimbap,
      pouletCoco,
      ailTitre,
      ailIngredient,
      ailes,
    ];

    RecipeFilterOutcome run(String q, {RecipeSort sort = RecipeSort.title}) =>
        applyRecipeFilter(corpus, query: q, sort: sort);
    List<String> idsIn(RecipeFilterOutcome out, RecipeQuerySection s) =>
        (out.sections[s] ?? const []).map((r) => r.id).toList();

    test('« bla » ne trouve ni « sablé » ni « poivre blanc »', () {
      final out = run('bla');
      expect(out.recipes.map((r) => r.id), ['blanquette']);
      expect(idsIn(out, RecipeQuerySection.title), ['blanquette']);
    });

    test('« blanquette » : dans le titre', () {
      final out = run('blanquette');
      expect(idsIn(out, RecipeQuerySection.title), ['blanquette']);
      expect(out.sections.keys, [RecipeQuerySection.title]);
    });

    test('« coréen » : le titre d\'abord, la cuisine ensuite', () {
      final out = run('coréen');
      expect(idsIn(out, RecipeQuerySection.title), ['poulet_coreen']);
      expect(idsIn(out, RecipeQuerySection.tags), ['bibimbap']);
      expect(idsIn(out, RecipeQuerySection.ingredients), isEmpty);
    });

    test('« poulet coco » : dans les ingrédients, avec « lait de coco »', () {
      final out = run('poulet coco');
      expect(idsIn(out, RecipeQuerySection.ingredients), ['poulet_coco']);
      expect(out.matchedIngredients['poulet_coco'], ['lait de coco']);
      expect(
        matchedIngredientsLine(out.matchedIngredients['poulet_coco']!),
        'Avec : lait de coco',
      );
    });

    test('« ail » ne cherche que dans les titres', () {
      final out = run('ail');
      expect(out.recipes.map((r) => r.id), ['ail_titre']);
      expect(titleOnlyQueryWords('ail'), ['ail']);
      expect(
        titleOnlyWordsLine(titleOnlyQueryWords('sel ail')),
        '« sel » et « ail » ne sont cherchés que dans les titres.',
      );
      expect(
        titleOnlyWordsLine(['sel']),
        '« sel » n\'est cherché que dans les titres.',
      );
      expect(titleOnlyQueryWords('poulet coco'), isEmpty);
    });

    test('un petit ingrédient de la recette n\'est pas lu', () {
      // « olive » n'est que dans « huile d'olive » : rien ne sort.
      expect(run('olive').recipes, isEmpty);
      expect(isSearchMinorIngredient('huile d\'olive'), isTrue);
      expect(isSearchMinorIngredient('gousses d\'ail'), isTrue);
      expect(isSearchMinorIngredient('oignons rouges'), isTrue);
      expect(isSearchMinorIngredient('poivre blanc'), isTrue);
      expect(isSearchMinorIngredient('lait de coco'), isFalse);
      expect(isSearchMinorIngredient('ailes de poulet'), isFalse);
      expect(isSearchMinorIngredient('selle d\'agneau'), isFalse);
    });

    test('le compteur compte toutes les sections, tri dans chacune', () {
      final out = run('poulet');
      expect(
        idsIn(out, RecipeQuerySection.title),
        ['poulet_coreen', 'poulet_coco']..sort((a, b) => a.compareTo(b)),
      );
      expect(idsIn(out, RecipeQuerySection.ingredients), ['ailes']);
      expect(out.recipes, hasLength(3));
      // Ordre des sections fixe, quel que soit le tri.
      expect(out.recipes.last.id, 'ailes');
    });

    test('sans texte : pas de sections', () {
      final out = run('');
      expect(out.sections, isEmpty);
      expect(out.recipes, hasLength(corpus.length));
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

  group('durées estimées', () {
    test('lecture du champ : terminé seulement, durées positives', () {
      expect(
        RecipeEstimatedTimes.fromMap({
          'status': 'done',
          'prep': 20,
          'cook': null,
        })?.prep,
        20,
      );
      expect(
        RecipeEstimatedTimes.fromMap({'status': 'pending', 'prep': 20}),
        isNull,
      );
      expect(
        RecipeEstimatedTimes.fromMap({
          'status': 'done',
          'prep': null,
          'cook': 0,
        }),
        isNull,
      );
      expect(RecipeEstimatedTimes.fromMap('texte'), isNull);
      // Champ vidé par le serveur (les deux durées sont lues) : aucune
      // estimation, ni sur la fiche, ni dans Explorer.
      final videe = RecipeEstimatedTimes.fromMap({
        'status': 'done',
        'fingerprint': 'f',
        'prep': null,
        'cook': null,
      });
      expect(videe, isNull);
      final r = recipe('videe', estimated: videe);
      expect(recipeTimes(r).isEstimated, isFalse);
      expect(recipeShownEstimate(r), isNull);
    });

    test('une durée lue garde la priorité sur l\'estimation', () {
      final r = recipe(
        'a',
        prep: 15,
        estimated: const RecipeEstimatedTimes(prep: 40, cook: 25),
      );
      final times = recipeTimes(r);
      expect(times.prep, 15);
      expect(times.prepEstimated, isFalse);
      expect(times.cook, 25);
      expect(times.cookEstimated, isTrue);
      expect(times.total, 40);
      expect(times.isEstimated, isTrue);
      // Durées lues seules : la cuisson estimée ne compte pas.
      expect(recipeTotalMinutes(r), 15);
      expect(recipeTotalMinutesWithEstimates(r), 40);
      // La fiche n'affiche que la cuisson estimée.
      final shown = recipeShownEstimate(r);
      expect(shown?.prep, isNull);
      expect(shown?.cook, 25);
    });

    test('durée lue dans le texte seul : 20 min, pas d\'estimation de la '
        'préparation', () {
      final r = recipe(
        'texte',
        cooklang: '>> temps_preparation: 20\nÉplucher.',
        estimated: const RecipeEstimatedTimes(prep: 45, cook: 30),
      );
      expect(recipeTotalMinutes(r), 20);
      final times = recipeTimes(r);
      expect(times.prep, 20);
      expect(times.prepEstimated, isFalse);
      expect(times.cook, 30);
      expect(times.total, 50);
      expect(recipeShownEstimate(r)?.prep, isNull);
      expect(recipeShownEstimate(r)?.cook, 30);
      // Sans estimation de cuisson : « 20 min », rien d'estimé.
      final seule = recipe(
        'texte-seul',
        cooklang: '>> temps_preparation: 20\nÉplucher.',
        estimated: const RecipeEstimatedTimes(prep: 45),
      );
      expect(recipeTimes(seule).total, 20);
      expect(recipeTimes(seule).isEstimated, isFalse);
      expect(recipeShownEstimate(seule), isNull);
      expect(
        exploreDurationText(
          recipeTimes(seule).total!,
          estimated: recipeTimes(seule).isEstimated,
        ),
        '20 min',
      );
      // Le filtre la retient comme une durée lue, interrupteur décoché.
      const filter = RecipeFilter(
        maxTotalMinutes: 30,
        countEstimatedTimes: false,
      );
      expect(
        applyRecipeFilter(
          [seule],
          filter: filter,
          context: RecipeFilterContext.forFilter(filter),
        ).recipes,
        hasLength(1),
      );
    });

    test('sans estimation, rien n\'est marqué estimé', () {
      final times = recipeTimes(recipe('a', prep: 10, cook: 20));
      expect(times.isEstimated, isFalse);
      expect(recipeShownEstimate(recipe('a', prep: 10)), isNull);
    });

    final lue = recipe('lue', prep: 10);
    final estimee = recipe(
      'estimee',
      estimated: const RecipeEstimatedTimes(prep: 10, cook: 15),
    );
    // Titre en « A » : par titre, elle passerait devant « estimee ».
    final estimeeLongue = recipe(
      'estimee-longue',
      titre: 'A longue',
      estimated: const RecipeEstimatedTimes(prep: 30, cook: 60),
    );
    final nulle = recipe('nulle');
    final corpus = [lue, estimee, estimeeLongue, nulle];

    test('interrupteur coché : l\'estimation entre dans le filtre', () {
      const filter = RecipeFilter(maxTotalMinutes: 30);
      expect(filter.countEstimatedTimes, isTrue);
      final out = applyRecipeFilter(
        corpus,
        filter: filter,
        context: RecipeFilterContext.forFilter(filter),
      );
      expect(out.recipes.map((r) => r.id), ['estimee', 'lue']);
      expect(out.missingData[RecipeFilterDimension.totalTime], 1);
      expect(out.estimatedTimeExcluded, 0);
    });

    test('interrupteur décoché : estimées écartées et comptées à part', () {
      const filter = RecipeFilter(
        maxTotalMinutes: 30,
        countEstimatedTimes: false,
      );
      final out = applyRecipeFilter(
        corpus,
        filter: filter,
        context: RecipeFilterContext.forFilter(filter),
      );
      expect(out.recipes.map((r) => r.id), ['lue']);
      // « estimee-longue » (90 min) ne passerait pas même estimée : elle
      // compte parmi les recettes sans durée.
      expect(out.estimatedTimeExcluded, 1);
      expect(out.missingData[RecipeFilterDimension.totalTime], 2);
      expect(estimatedExcludedLine(1), '1 recette à durée estimée écartée');
      expect(estimatedExcludedLine(3), '3 recettes à durée estimée écartées');
    });

    test('plus rapides : l\'estimation range la recette si cochée', () {
      List<String> fastest(RecipeFilter f) => applyRecipeFilter(
        corpus,
        filter: f,
        context: RecipeFilterContext.forFilter(f),
        sort: RecipeSort.fastest,
      ).recipes.map((r) => r.id).toList();
      expect(fastest(RecipeFilter.none), [
        'lue',
        'estimee',
        'estimee-longue',
        'nulle',
      ]);
      // Décoché : sans durée lue, en fin de liste, par titre.
      expect(fastest(const RecipeFilter(countEstimatedTimes: false)), [
        'lue',
        'estimee-longue',
        'estimee',
        'nulle',
      ]);
    });

    test('l\'interrupteur s\'enregistre, et « Effacer tout » le garde', () {
      const f = RecipeFilter(dishTypes: {'plat'}, countEstimatedTimes: false);
      final back = RecipeFilter.fromMap(f.toMap());
      expect(back.countEstimatedTimes, isFalse);
      expect(back.signature, f.signature);
      expect(
        f.signature,
        isNot(const RecipeFilter(dishTypes: {'plat'}).signature),
      );
      expect(RecipeFilter.fromMap(const {}).countEstimatedTimes, isTrue);
      expect(f.cleared.isEmpty, isTrue);
      expect(f.cleared.countEstimatedTimes, isFalse);
      // Un réglage, pas une valeur cochée.
      expect(f.count, 1);
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

  test('Voir sur Google : le texte tel quel, plus « recette »', () {
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
