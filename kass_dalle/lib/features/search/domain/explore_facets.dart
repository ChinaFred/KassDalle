import '../../recipes/domain/allergens.dart';
import '../../recipes/domain/meal_role.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';

/// Les valeurs proposées par chaque filtre de l'écran Explorer, avec leur
/// nombre de recettes (« Plat (40) »), comptées sur les recettes des sources
/// choisies.
///
/// Rien n'est inventé : une cuisine n'apparaît que si une recette la porte.
/// Les seuils (temps, note, calories) sont fixes ; leur nombre dit combien de
/// recettes les respectent.
class ExploreFacets {
  final List<RecipeFacet> dishTypes;
  final List<RecipeFacet> cuisines;
  final List<RecipeFacet> mealRoles;
  final List<RecipeFacet> proteins;
  final List<RecipeFacet> starches;
  final List<RecipeFacet> difficulties;
  final List<RecipeFacet> themes;
  final List<RecipeFacet> books;

  /// Auteurs : clé = uid. Le libellé est posé par l'écran (« Moi », nom du
  /// membre) ; ici, l'uid du lecteur vient en premier.
  final List<RecipeFacet> authors;

  /// Les quatorze allergènes, dans l'ordre du règlement. Le nombre est celui
  /// des recettes qui en contiennent.
  final List<RecipeFacet> allergens;
  final List<RecipeFacet> totalTimes;
  final List<RecipeFacet> minRatings;
  final List<RecipeFacet> maxCalories;

  const ExploreFacets({
    required this.dishTypes,
    required this.cuisines,
    required this.mealRoles,
    required this.proteins,
    required this.starches,
    required this.difficulties,
    required this.themes,
    required this.books,
    required this.authors,
    required this.allergens,
    required this.totalTimes,
    required this.minRatings,
    required this.maxCalories,
  });

  /// Les valeurs d'une dimension. Les exclusions d'ingrédient n'en ont pas :
  /// elles se saisissent.
  List<RecipeFacet> of(RecipeFilterDimension d) => switch (d) {
    RecipeFilterDimension.dishType => dishTypes,
    RecipeFilterDimension.cuisine => cuisines,
    RecipeFilterDimension.mealRole => mealRoles,
    RecipeFilterDimension.protein => proteins,
    RecipeFilterDimension.starch => starches,
    RecipeFilterDimension.difficulty => difficulties,
    RecipeFilterDimension.theme => themes,
    RecipeFilterDimension.book => books,
    RecipeFilterDimension.author => authors,
    RecipeFilterDimension.excludedAllergen => allergens,
    RecipeFilterDimension.totalTime => totalTimes,
    RecipeFilterDimension.minRating => minRatings,
    RecipeFilterDimension.maxCalories => maxCalories,
    RecipeFilterDimension.excludedIngredient => const [],
  };
}

ExploreFacets exploreFacets(
  List<Recipe> recipes, {
  required String myUid,
  RecipeFilterContext context = RecipeFilterContext.empty,
}) {
  List<RecipeFacet> relabel(
    List<RecipeFacet> facets,
    String Function(String key) label,
  ) => [
    for (final f in facets)
      RecipeFacet(key: f.key, label: label(f.key), count: f.count),
  ];

  List<RecipeFacet> single(String? Function(Recipe) valueOf) =>
      tagFacets(recipes, (r) {
        final v = valueOf(r);
        return v == null ? const [] : [v];
      });

  List<RecipeFacet> thresholds(
    List<int> values,
    String Function(int) label,
    bool Function(Recipe, int) keeps,
  ) => [
    for (final v in values)
      RecipeFacet(
        key: '$v',
        label: label(v),
        count: recipes.where((r) => keeps(r, v)).length,
      ),
  ];

  // Identifiants de livre et de compte : comptés tels quels, sans passer en
  // minuscules comme une étiquette — la clé doit rester l'identifiant.
  final bookCounts = <String, int>{};
  final bookTitles = <String, String>{};
  final authorCounts = <String, int>{};
  for (final r in recipes) {
    final id = r.bookId;
    if (id != null && id.isNotEmpty) {
      bookCounts[id] = (bookCounts[id] ?? 0) + 1;
      final title = (r.bookTitre ?? '').trim();
      bookTitles.putIfAbsent(
        id,
        () => title.isEmpty ? 'Livre sans titre' : title,
      );
    }
    if (r.createdBy.isNotEmpty) {
      authorCounts[r.createdBy] = (authorCounts[r.createdBy] ?? 0) + 1;
    }
  }
  final books =
      [
        for (final e in bookCounts.entries)
          RecipeFacet(key: e.key, label: bookTitles[e.key]!, count: e.value),
      ]..sort((a, b) {
        final byCount = b.count.compareTo(a.count);
        return byCount != 0 ? byCount : a.label.compareTo(b.label);
      });
  final authors =
      [
        for (final e in authorCounts.entries)
          RecipeFacet(key: e.key, label: e.key, count: e.value),
      ]..sort((a, b) {
        if (a.key == myUid) return -1;
        if (b.key == myUid) return 1;
        return b.count.compareTo(a.count);
      });

  return ExploreFacets(
    dishTypes: tagFacets(recipes, (r) => r.tags.dishTypes),
    cuisines: tagFacets(recipes, (r) => r.tags.cuisines),
    mealRoles: relabel(single((r) => r.tags.mealRole), mealRoleLabel),
    proteins: relabel(single((r) => r.tags.mainProtein), mainProteinLabel),
    starches: relabel(single((r) => r.tags.mainStarch), mainStarchLabel),
    difficulties: single((r) => r.tags.difficulty),
    themes: tagFacets(recipes, (r) => [...r.tags.themes, ...r.tags.occasions]),
    books: books,
    authors: authors,
    allergens: [
      for (final key in kAllergenKeys)
        RecipeFacet(
          key: key,
          label: allergenLabel(key),
          count: recipes
              .where((r) => r.allergens?.present.contains(key) ?? false)
              .length,
        ),
    ],
    totalTimes: thresholds(kTotalTimeThresholds, totalTimeLabel, (r, v) {
      final m = context.totalMinutesOf(r);
      return m != null && m <= v;
    }),
    minRatings: thresholds(kMinRatingThresholds, (v) => '$v et plus', (r, v) {
      final rating = context.myRatings[r.id];
      return rating != null && rating >= v;
    }),
    maxCalories: thresholds(kMaxCaloriesThresholds, (v) => '≤ $v kcal', (r, v) {
      final kcal = recipeCaloriesPerPortion(r);
      return kcal != null && kcal <= v;
    }),
  );
}

/// « 5 recettes sans calories écartées », « 1 recette sans durée écartée ».
String missingDataLine(RecipeFilterDimension dimension, int count) {
  final plural = count > 1;
  return '$count recette${plural ? 's' : ''} sans ${dimension.missingLabel} '
      'écartée${plural ? 's' : ''}';
}

/// « Aucune recette », « 1 recette », « 12 recettes ».
String recipeCountLabel(int count) => switch (count) {
  0 => 'Aucune recette',
  1 => '1 recette',
  _ => '$count recettes',
};
