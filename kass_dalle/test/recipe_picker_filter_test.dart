import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/recipe_picker_filter.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Ce que le sélecteur de recette propose, et ce qu'il tait.
///
/// Une technique listée entre deux plats ne lève rien : elle se pose sur un
/// repas, et le planning affiche « Techniques du chef » un mardi soir.
void main() {
  Recipe recipe(
    String id, {
    PageType pageType = PageType.recipe,
    List<String> dishTypes = const [],
    List<String> cuisines = const [],
  }) => Recipe(
    id: id,
    titre: 'Recette $id',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(dishTypes: dishTypes, cuisines: cuisines),
    ingredientsIndex: const [],
    createdBy: 'u1',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
    pageType: pageType,
  );

  final baozi = recipe(
    'baozi',
    dishTypes: const ['viande', 'plat complet'],
    cuisines: const ['Asiatique', 'Street food'],
  );
  final tarte = recipe(
    'tarte',
    dishTypes: const ['dessert'],
    cuisines: const ['française'],
  );
  final nems = recipe(
    'nems',
    dishTypes: const ['entrée'],
    cuisines: const ['asiatique'],
  );
  final technique = recipe('technique', pageType: PageType.technique);

  test('seules les pages de type recette se proposent', () {
    expect(pickableRecipes([baozi, technique, tarte]).map((r) => r.id), [
      'baozi',
      'tarte',
    ]);
  });

  group('filtre', () {
    test('sans étiquette cochée, tout passe', () {
      expect(RecipePickerFilter.none.matches(baozi), isTrue);
      expect(RecipePickerFilter.none.isEmpty, isTrue);
    });

    test('un type de plat coché retient les recettes qui le portent', () {
      const f = RecipePickerFilter(dishTypes: {'dessert'});
      expect(f.matches(tarte), isTrue);
      expect(f.matches(baozi), isFalse);
    });

    test('la casse de l\'étiquette ne compte pas', () {
      const f = RecipePickerFilter(cuisines: {'asiatique'});
      expect(f.matches(baozi), isTrue, reason: '« Asiatique » en base');
      expect(f.matches(nems), isTrue, reason: '« asiatique » en base');
      expect(f.matches(tarte), isFalse);
    });

    test('les deux groupes se cumulent', () {
      const f = RecipePickerFilter(
        dishTypes: {'entrée'},
        cuisines: {'asiatique'},
      );
      expect(f.matches(nems), isTrue);
      expect(f.matches(baozi), isFalse, reason: 'asiatique mais pas entrée');
    });

    test('cocher puis décocher revient au filtre vide', () {
      final f = RecipePickerFilter.none.toggleDishType('dessert');
      expect(f.count, 1);
      expect(f.toggleDishType('dessert').isEmpty, isTrue);
    });
  });

  group('valeurs proposées', () {
    test('elles viennent du corpus, les plus fréquentes en premier', () {
      final facets = recipePickerFacets([baozi, tarte, nems]);
      expect(facets.cuisines.first.key, 'asiatique');
      expect(facets.cuisines.first.count, 2);
      expect(
        facets.dishTypes.map((f) => f.key),
        containsAll(['dessert', 'entrée', 'viande']),
      );
    });

    test('la graphie affichée est la plus fréquente', () {
      final facets = recipePickerFacets([
        nems,
        recipe('x', cuisines: const ['asiatique']),
        baozi,
      ]);
      expect(facets.cuisines.first.label, 'asiatique');
    });

    test('un corpus sans étiquette ne propose rien', () {
      final facets = recipePickerFacets([technique]);
      expect(facets.dishTypes, isEmpty);
      expect(facets.cuisines, isEmpty);
    });
  });

  group('liste affichée', () {
    test('recherche, filtre et écartées se combinent', () {
      final shown = filterPickerRecipes(
        [baozi, tarte, nems],
        query: 'recette',
        filter: const RecipePickerFilter(cuisines: {'asiatique'}),
        dismissedRecipeIds: const {'nems'},
      );
      expect(shown.map((r) => r.id), ['baozi']);
    });

    test('les écartées reviennent sur demande', () {
      final shown = filterPickerRecipes(
        [baozi, nems],
        dismissedRecipeIds: const {'nems'},
        showDismissed: true,
      );
      expect(shown.length, 2);
    });
  });
}
