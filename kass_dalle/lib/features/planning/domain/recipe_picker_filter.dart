import '../../recipes/domain/recipe.dart';

/// Les recettes qu'on peut poser sur un repas : les pages de type recette.
///
/// Une technique, une page de matériel ou une note d'ingrédient est une page
/// de livre, pas un plat. Validées comme les autres, elles arrivaient dans le
/// sélecteur et dans le corpus envoyé à l'IA — « Techniques du chef » entre
/// deux plats.
List<Recipe> pickableRecipes(Iterable<Recipe> recipes) =>
    recipes.where((r) => r.pageType == PageType.recipe).toList(growable: false);

/// Clé de comparaison d'une étiquette : « Asiatique » et « asiatique » sont
/// la même cuisine.
String pickerTagKey(String tag) => tag.trim().toLowerCase();

/// Filtre du sélecteur : types de plat et cuisines, en clés normalisées.
///
/// Dans un groupe, une recette convient si elle porte l'une des étiquettes
/// cochées ; entre les groupes, elle doit convenir aux deux. Un groupe vide
/// ne filtre pas.
class RecipePickerFilter {
  final Set<String> dishTypes;
  final Set<String> cuisines;

  const RecipePickerFilter({
    this.dishTypes = const {},
    this.cuisines = const {},
  });

  static const none = RecipePickerFilter();

  bool get isEmpty => dishTypes.isEmpty && cuisines.isEmpty;

  /// Nombre d'étiquettes cochées, pour le badge de l'icône.
  int get count => dishTypes.length + cuisines.length;

  bool matches(Recipe recipe) {
    if (dishTypes.isNotEmpty &&
        !recipe.tags.dishTypes.any(
          (t) => dishTypes.contains(pickerTagKey(t)),
        )) {
      return false;
    }
    if (cuisines.isNotEmpty &&
        !recipe.tags.cuisines.any((t) => cuisines.contains(pickerTagKey(t)))) {
      return false;
    }
    return true;
  }

  RecipePickerFilter toggleDishType(String key) => RecipePickerFilter(
    dishTypes: _toggled(dishTypes, key),
    cuisines: cuisines,
  );

  RecipePickerFilter toggleCuisine(String key) => RecipePickerFilter(
    dishTypes: dishTypes,
    cuisines: _toggled(cuisines, key),
  );

  static Set<String> _toggled(Set<String> current, String key) {
    final next = {...current};
    if (!next.remove(key)) next.add(key);
    return next;
  }
}

/// Une valeur de filtre proposée : la clé qui se compare, le libellé qui
/// s'affiche, le nombre de recettes qui la portent.
class PickerFacet {
  final String key;
  final String label;
  final int count;

  const PickerFacet({
    required this.key,
    required this.label,
    required this.count,
  });
}

/// Les étiquettes présentes dans le corpus, les plus fréquentes en premier.
///
/// Rien n'est inventé : « asiatique » n'apparaît que si une recette la porte.
/// Le libellé retenu est la graphie la plus fréquente dans le corpus.
({List<PickerFacet> dishTypes, List<PickerFacet> cuisines}) recipePickerFacets(
  Iterable<Recipe> recipes,
) {
  final dish = <String, Map<String, int>>{};
  final cuisine = <String, Map<String, int>>{};
  for (final r in recipes) {
    _countTags(dish, r.tags.dishTypes);
    _countTags(cuisine, r.tags.cuisines);
  }
  return (dishTypes: _facetsOf(dish), cuisines: _facetsOf(cuisine));
}

void _countTags(Map<String, Map<String, int>> into, Iterable<String> tags) {
  // Une recette ne compte qu'une fois par clé, même si elle répète l'étiquette.
  final seen = <String>{};
  for (final tag in tags) {
    final trimmed = tag.trim();
    if (trimmed.isEmpty) continue;
    final key = pickerTagKey(trimmed);
    if (!seen.add(key)) continue;
    final spellings = into.putIfAbsent(key, () => {});
    spellings[trimmed] = (spellings[trimmed] ?? 0) + 1;
  }
}

List<PickerFacet> _facetsOf(Map<String, Map<String, int>> counts) {
  final facets = <PickerFacet>[];
  for (final entry in counts.entries) {
    final spellings = entry.value.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    final total = entry.value.values.fold(0, (sum, n) => sum + n);
    facets.add(
      PickerFacet(key: entry.key, label: spellings.first.key, count: total),
    );
  }
  facets.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.label.compareTo(b.label);
  });
  return facets;
}

/// Ce que le sélecteur affiche : la recherche, le filtre et les recettes
/// écartées, appliqués dans cet ordre.
List<Recipe> filterPickerRecipes(
  Iterable<Recipe> recipes, {
  String query = '',
  RecipePickerFilter filter = RecipePickerFilter.none,
  Set<String> dismissedRecipeIds = const {},
  bool showDismissed = false,
}) {
  final q = query.trim().toLowerCase();
  return recipes
      .where((r) {
        if (!showDismissed && dismissedRecipeIds.contains(r.id)) return false;
        if (!filter.matches(r)) return false;
        return q.isEmpty || r.titre.toLowerCase().contains(q);
      })
      .toList(growable: false);
}
