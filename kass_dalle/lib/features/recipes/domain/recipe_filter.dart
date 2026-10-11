/// Filtrer une liste de recettes, sans IA : le sélecteur du planning et
/// l'écran Explorer partagent ce code.
///
/// Tout se calcule sur l'appareil, à partir des champs de la recette. Rien
/// n'est écrit dans la recette : les calories par portion valent
/// `totaux / parts`, calculées à l'affichage ; la note est celle du lecteur,
/// lue sous son compte.
library;

import '../../../core/utils/ingredient_name.dart';
import 'recipe.dart';

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
String recipeTagKey(String tag) => tag.trim().toLowerCase();

/// Texte comparable : minuscules, sans accents, mots séparés par une espace.
String foldSearchText(String value) => stripAccentsPreservingWords(
  value.toLowerCase(),
).replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

/// Temps total d'une recette : préparation + cuisson, en minutes.
///
/// Le repos (marinade, levée) n'y entre pas : il s'affiche à part. Une seule
/// des deux valeurs connue suffit ; aucune des deux, la recette est « sans
/// durée » (`null`).
int? recipeTotalMinutes(Recipe recipe) {
  final prep = recipe.tags.prepTime;
  final cook = recipe.tags.cookTime;
  if (prep == null && cook == null) return null;
  return (prep ?? 0) + (cook ?? 0);
}

/// Calories par portion, calculées à l'affichage (`totaux / parts`).
///
/// `null` quand la recette n'a pas de bloc nutrition ou pas de calories.
double? recipeCaloriesPerPortion(Recipe recipe) {
  final nutrition = recipe.nutrition;
  if (nutrition == null) return null;
  final kcal = nutrition.perPortionFor(recipe.portions)['kcal'];
  if (kcal == null || kcal.isNaN || kcal < 0) return null;
  return kcal;
}

/// Les dimensions d'un filtre. L'ordre est celui de l'affichage.
enum RecipeFilterDimension {
  dishType,
  totalTime,
  cuisine,
  mealRole,
  protein,
  starch,
  difficulty,
  theme,
  excludedIngredient,
  excludedAllergen,
  book,
  author,
  minRating,
  maxCalories;

  /// Ce qui manque à une recette écartée faute de donnée, pour la ligne
  /// « N recettes sans … écartées ».
  String get missingLabel => switch (this) {
    RecipeFilterDimension.dishType => 'type de plat',
    RecipeFilterDimension.totalTime => 'durée',
    RecipeFilterDimension.cuisine => 'cuisine',
    RecipeFilterDimension.mealRole => 'rôle dans le repas',
    RecipeFilterDimension.protein => 'protéine',
    RecipeFilterDimension.starch => 'féculent',
    RecipeFilterDimension.difficulty => 'difficulté',
    RecipeFilterDimension.theme => 'thème ni occasion',
    RecipeFilterDimension.excludedIngredient => 'liste d\'ingrédients',
    RecipeFilterDimension.excludedAllergen => 'analyse d\'allergènes',
    RecipeFilterDimension.book => 'livre',
    RecipeFilterDimension.author => 'auteur',
    RecipeFilterDimension.minRating => 'votre note',
    RecipeFilterDimension.maxCalories => 'calories',
  };
}

/// Une recette face à une dimension du filtre.
enum FilterVerdict { match, mismatch, missing }

/// Seuils proposés pour le temps total, en minutes.
const kTotalTimeThresholds = [15, 30, 45, 60, 120];

/// Seuils proposés pour la note minimale du lecteur (sur 10).
const kMinRatingThresholds = [5, 7, 8];

/// Seuils proposés pour les calories par portion.
const kMaxCaloriesThresholds = [400, 600, 800];

/// Libellé d'un seuil de temps : « ≤ 15 min », « ≤ 1 h ».
String totalTimeLabel(int minutes) {
  if (minutes < 60) return '≤ $minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '≤ $hours h' : '≤ $hours h $rest';
}

/// Libellé d'une durée sur une tuile : « 45 min », « 1 h 20 ».
String durationLabel(int minutes) {
  if (minutes < 60) return '$minutes min';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours h' : '$hours h ${rest.toString().padLeft(2, '0')}';
}

/// Le filtre : des ensembles de clés cochées et des seuils.
///
/// Dans une dimension, une recette convient si elle porte l'une des valeurs
/// cochées (OU) ; entre les dimensions, elle doit convenir à toutes (ET). Une
/// dimension vide ne filtre pas. Les exclusions (ingrédient, allergène)
/// écartent une recette qui contient l'une OU l'autre des valeurs cochées.
///
/// Une recette sans donnée pour une dimension active est écartée — on ne sait
/// pas si elle convient — et comptée à part, pour que l'écran le dise.
class RecipeFilter {
  final Set<String> dishTypes;
  final Set<String> cuisines;
  final Set<String> mealRoles;
  final Set<String> proteins;
  final Set<String> starches;
  final Set<String> difficulties;

  /// Thèmes et occasions confondus : « Thème ou occasion » à l'écran.
  final Set<String> themes;

  /// Mots d'ingrédient à exclure, tels que saisis.
  final Set<String> excludedIngredients;

  /// Clés d'allergène à exclure (`kAllergenKeys`).
  final Set<String> excludedAllergens;
  final Set<String> bookIds;
  final Set<String> authorIds;
  final int? maxTotalMinutes;
  final int? minRating;
  final int? maxCaloriesPerPortion;

  const RecipeFilter({
    this.dishTypes = const {},
    this.cuisines = const {},
    this.mealRoles = const {},
    this.proteins = const {},
    this.starches = const {},
    this.difficulties = const {},
    this.themes = const {},
    this.excludedIngredients = const {},
    this.excludedAllergens = const {},
    this.bookIds = const {},
    this.authorIds = const {},
    this.maxTotalMinutes,
    this.minRating,
    this.maxCaloriesPerPortion,
  });

  static const none = RecipeFilter();

  /// Les ensembles de clés, par dimension.
  Set<String> keysOf(RecipeFilterDimension d) => switch (d) {
    RecipeFilterDimension.dishType => dishTypes,
    RecipeFilterDimension.cuisine => cuisines,
    RecipeFilterDimension.mealRole => mealRoles,
    RecipeFilterDimension.protein => proteins,
    RecipeFilterDimension.starch => starches,
    RecipeFilterDimension.difficulty => difficulties,
    RecipeFilterDimension.theme => themes,
    RecipeFilterDimension.excludedIngredient => excludedIngredients,
    RecipeFilterDimension.excludedAllergen => excludedAllergens,
    RecipeFilterDimension.book => bookIds,
    RecipeFilterDimension.author => authorIds,
    RecipeFilterDimension.totalTime => {
      if (maxTotalMinutes != null) '$maxTotalMinutes',
    },
    RecipeFilterDimension.minRating => {if (minRating != null) '$minRating'},
    RecipeFilterDimension.maxCalories => {
      if (maxCaloriesPerPortion != null) '$maxCaloriesPerPortion',
    },
  };

  /// Les dimensions actives.
  Iterable<RecipeFilterDimension> get activeDimensions =>
      RecipeFilterDimension.values.where((d) => keysOf(d).isNotEmpty);

  bool get isEmpty => activeDimensions.isEmpty;

  /// Nombre de valeurs cochées, pour « Filtres · N ».
  int get count =>
      RecipeFilterDimension.values.fold(0, (sum, d) => sum + keysOf(d).length);

  RecipeFilter copyWith({
    Set<String>? dishTypes,
    Set<String>? cuisines,
    Set<String>? mealRoles,
    Set<String>? proteins,
    Set<String>? starches,
    Set<String>? difficulties,
    Set<String>? themes,
    Set<String>? excludedIngredients,
    Set<String>? excludedAllergens,
    Set<String>? bookIds,
    Set<String>? authorIds,
    int? Function()? maxTotalMinutes,
    int? Function()? minRating,
    int? Function()? maxCaloriesPerPortion,
  }) => RecipeFilter(
    dishTypes: dishTypes ?? this.dishTypes,
    cuisines: cuisines ?? this.cuisines,
    mealRoles: mealRoles ?? this.mealRoles,
    proteins: proteins ?? this.proteins,
    starches: starches ?? this.starches,
    difficulties: difficulties ?? this.difficulties,
    themes: themes ?? this.themes,
    excludedIngredients: excludedIngredients ?? this.excludedIngredients,
    excludedAllergens: excludedAllergens ?? this.excludedAllergens,
    bookIds: bookIds ?? this.bookIds,
    authorIds: authorIds ?? this.authorIds,
    maxTotalMinutes: maxTotalMinutes != null
        ? maxTotalMinutes()
        : this.maxTotalMinutes,
    minRating: minRating != null ? minRating() : this.minRating,
    maxCaloriesPerPortion: maxCaloriesPerPortion != null
        ? maxCaloriesPerPortion()
        : this.maxCaloriesPerPortion,
  );

  /// Coche ou décoche [key] dans [dimension]. Pour un seuil, la même valeur
  /// le retire, une autre le remplace.
  RecipeFilter toggle(RecipeFilterDimension dimension, String key) {
    int? flip(int? current) {
      final value = int.tryParse(key);
      return current == value ? null : value;
    }

    return switch (dimension) {
      RecipeFilterDimension.dishType => copyWith(
        dishTypes: _toggled(dishTypes, key),
      ),
      RecipeFilterDimension.cuisine => copyWith(
        cuisines: _toggled(cuisines, key),
      ),
      RecipeFilterDimension.mealRole => copyWith(
        mealRoles: _toggled(mealRoles, key),
      ),
      RecipeFilterDimension.protein => copyWith(
        proteins: _toggled(proteins, key),
      ),
      RecipeFilterDimension.starch => copyWith(
        starches: _toggled(starches, key),
      ),
      RecipeFilterDimension.difficulty => copyWith(
        difficulties: _toggled(difficulties, key),
      ),
      RecipeFilterDimension.theme => copyWith(themes: _toggled(themes, key)),
      RecipeFilterDimension.excludedIngredient => copyWith(
        excludedIngredients: _toggled(excludedIngredients, key),
      ),
      RecipeFilterDimension.excludedAllergen => copyWith(
        excludedAllergens: _toggled(excludedAllergens, key),
      ),
      RecipeFilterDimension.book => copyWith(bookIds: _toggled(bookIds, key)),
      RecipeFilterDimension.author => copyWith(
        authorIds: _toggled(authorIds, key),
      ),
      RecipeFilterDimension.totalTime => copyWith(
        maxTotalMinutes: () => flip(maxTotalMinutes),
      ),
      RecipeFilterDimension.minRating => copyWith(
        minRating: () => flip(minRating),
      ),
      RecipeFilterDimension.maxCalories => copyWith(
        maxCaloriesPerPortion: () => flip(maxCaloriesPerPortion),
      ),
    };
  }

  /// Raccourcis du sélecteur du planning.
  RecipeFilter toggleDishType(String key) =>
      toggle(RecipeFilterDimension.dishType, key);
  RecipeFilter toggleCuisine(String key) =>
      toggle(RecipeFilterDimension.cuisine, key);

  /// Vrai si [recipe] convient à toutes les dimensions actives. Une donnée
  /// manquante ne convient pas.
  bool matches(
    Recipe recipe, {
    RecipeFilterContext context = RecipeFilterContext.empty,
  }) => activeDimensions.every(
    (d) => verdict(d, recipe, context) == FilterVerdict.match,
  );

  /// Ce que [recipe] donne face à [dimension].
  FilterVerdict verdict(
    RecipeFilterDimension dimension,
    Recipe recipe,
    RecipeFilterContext context,
  ) {
    final keys = keysOf(dimension);
    if (keys.isEmpty) return FilterVerdict.match;
    final tags = recipe.tags;
    switch (dimension) {
      case RecipeFilterDimension.dishType:
        return _anyTag(tags.dishTypes, keys);
      case RecipeFilterDimension.cuisine:
        return _anyTag(tags.cuisines, keys);
      case RecipeFilterDimension.theme:
        return _anyTag([...tags.themes, ...tags.occasions], keys);
      case RecipeFilterDimension.mealRole:
        return _oneValue(tags.mealRole, keys);
      case RecipeFilterDimension.protein:
        return _oneValue(tags.mainProtein, keys);
      case RecipeFilterDimension.starch:
        return _oneValue(tags.mainStarch, keys);
      case RecipeFilterDimension.difficulty:
        return _oneValue(tags.difficulty, keys);
      case RecipeFilterDimension.book:
        return _oneValue(recipe.bookId, keys, normalize: false);
      case RecipeFilterDimension.author:
        return _oneValue(recipe.createdBy, keys, normalize: false);
      case RecipeFilterDimension.excludedIngredient:
        final names = [
          ...recipe.ingredientsIndex,
          ...recipe.ingredients.map((i) => i.name),
        ].map(foldSearchText).where((n) => n.isNotEmpty).toList();
        if (names.isEmpty) return FilterVerdict.missing;
        for (final term in keys.map(foldSearchText)) {
          if (term.isEmpty) continue;
          final word = RegExp('(^| )${RegExp.escape(term)}(s|x)?( |\$)');
          if (names.any(word.hasMatch)) return FilterVerdict.mismatch;
        }
        return FilterVerdict.match;
      case RecipeFilterDimension.excludedAllergen:
        final allergens = recipe.allergens;
        // Jamais analysée ou analyse incomplète : on ne sait pas.
        if (allergens == null || !allergens.complete) {
          return FilterVerdict.missing;
        }
        return allergens.present.any(keys.contains)
            ? FilterVerdict.mismatch
            : FilterVerdict.match;
      case RecipeFilterDimension.totalTime:
        final minutes = context.totalMinutesOf(recipe);
        if (minutes == null) return FilterVerdict.missing;
        return minutes <= maxTotalMinutes!
            ? FilterVerdict.match
            : FilterVerdict.mismatch;
      case RecipeFilterDimension.minRating:
        final rating = context.myRatings[recipe.id];
        if (rating == null) return FilterVerdict.missing;
        return rating >= minRating!
            ? FilterVerdict.match
            : FilterVerdict.mismatch;
      case RecipeFilterDimension.maxCalories:
        final kcal = recipeCaloriesPerPortion(recipe);
        if (kcal == null) return FilterVerdict.missing;
        return kcal <= maxCaloriesPerPortion!
            ? FilterVerdict.match
            : FilterVerdict.mismatch;
    }
  }

  static FilterVerdict _anyTag(List<String> tags, Set<String> keys) {
    final present = tags.map(recipeTagKey).where((t) => t.isNotEmpty);
    if (present.isEmpty) return FilterVerdict.missing;
    return present.any(keys.contains)
        ? FilterVerdict.match
        : FilterVerdict.mismatch;
  }

  static FilterVerdict _oneValue(
    String? value,
    Set<String> keys, {
    bool normalize = true,
  }) {
    if (value == null || value.trim().isEmpty) return FilterVerdict.missing;
    final key = normalize ? recipeTagKey(value) : value;
    return keys.contains(key) ? FilterVerdict.match : FilterVerdict.mismatch;
  }

  static Set<String> _toggled(Set<String> current, String key) {
    final next = {...current};
    if (!next.remove(key)) next.add(key);
    return next;
  }

  // ── Persistance (préférence du lecteur) ──────────────────────────────────

  static const _setFields = {
    RecipeFilterDimension.dishType: 'dish_types',
    RecipeFilterDimension.cuisine: 'cuisines',
    RecipeFilterDimension.mealRole: 'meal_roles',
    RecipeFilterDimension.protein: 'proteins',
    RecipeFilterDimension.starch: 'starches',
    RecipeFilterDimension.difficulty: 'difficulties',
    RecipeFilterDimension.theme: 'themes',
    RecipeFilterDimension.excludedIngredient: 'excluded_ingredients',
    RecipeFilterDimension.excludedAllergen: 'excluded_allergens',
    RecipeFilterDimension.book: 'book_ids',
    RecipeFilterDimension.author: 'author_ids',
  };

  Map<String, dynamic> toMap() => {
    for (final e in _setFields.entries) e.value: keysOf(e.key).toList(),
    'max_total_minutes': maxTotalMinutes,
    'min_rating': minRating,
    'max_kcal_per_portion': maxCaloriesPerPortion,
  };

  /// Lit un filtre enregistré. Une valeur mal formée est ignorée, pas
  /// levée : une préférence illisible ne doit pas fermer l'écran.
  factory RecipeFilter.fromMap(Map<String, dynamic> data) {
    Set<String> set(String field) {
      final raw = data[field];
      return raw is List ? raw.whereType<String>().toSet() : const {};
    }

    int? positive(String field) {
      final raw = data[field];
      return raw is num && raw > 0 ? raw.toInt() : null;
    }

    final f = _setFields;
    return RecipeFilter(
      dishTypes: set(f[RecipeFilterDimension.dishType]!),
      cuisines: set(f[RecipeFilterDimension.cuisine]!),
      mealRoles: set(f[RecipeFilterDimension.mealRole]!),
      proteins: set(f[RecipeFilterDimension.protein]!),
      starches: set(f[RecipeFilterDimension.starch]!),
      difficulties: set(f[RecipeFilterDimension.difficulty]!),
      themes: set(f[RecipeFilterDimension.theme]!),
      excludedIngredients: set(f[RecipeFilterDimension.excludedIngredient]!),
      excludedAllergens: set(f[RecipeFilterDimension.excludedAllergen]!),
      bookIds: set(f[RecipeFilterDimension.book]!),
      authorIds: set(f[RecipeFilterDimension.author]!),
      maxTotalMinutes: positive('max_total_minutes'),
      minRating: positive('min_rating'),
      maxCaloriesPerPortion: positive('max_kcal_per_portion'),
    );
  }

  /// Signature stable, pour savoir si le filtre a changé depuis une demande.
  String get signature {
    final parts = <String>[];
    for (final d in RecipeFilterDimension.values) {
      final keys = keysOf(d).toList()..sort();
      if (keys.isNotEmpty) parts.add('${d.name}=${keys.join(',')}');
    }
    return parts.join(';');
  }
}

/// Ce que le filtre lit hors de la recette.
class RecipeFilterContext {
  /// Notes du lecteur (sur 10), par identifiant de recette.
  final Map<String, int> myRatings;

  /// Temps total d'une recette. Par défaut [recipeTotalMinutes] ; une durée
  /// estimée (lot 3) se branche ici sans toucher au filtre.
  final int? Function(Recipe) totalMinutesOf;

  const RecipeFilterContext({
    this.myRatings = const {},
    this.totalMinutesOf = recipeTotalMinutes,
  });

  static const empty = RecipeFilterContext();
}

/// Les tris de l'écran Explorer.
enum RecipeSort {
  bestRated('best_rated', 'Mieux notées'),
  fastest('fastest', 'Plus rapides'),
  newest('newest', 'Plus récentes'),
  title('title', 'Titre (A → Z)');

  final String storageKey;
  final String label;
  const RecipeSort(this.storageKey, this.label);

  static RecipeSort fromStorage(Object? raw) => RecipeSort.values.firstWhere(
    (s) => s.storageKey == raw,
    orElse: () => RecipeSort.bestRated,
  );
}

/// Vrai si tous les mots de [query] se trouvent dans la recette : titre,
/// ingrédients, étiquettes (cuisines, thèmes, occasions, types de plat).
/// Sans accents ni casse ; un mot peut n'être que le début d'un mot.
bool matchesRecipeQuery(Recipe recipe, String query) {
  final words = foldSearchText(query).split(' ').where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final haystack = foldSearchText(
    [
      recipe.titre,
      ...recipe.ingredientsIndex,
      ...recipe.ingredients.map((i) => i.name),
      ...recipe.tags.cuisines,
      ...recipe.tags.themes,
      ...recipe.tags.occasions,
      ...recipe.tags.dishTypes,
    ].join(' '),
  );
  return words.every(haystack.contains);
}

/// Le résultat d'un filtrage : les recettes retenues, triées, et ce qui a
/// été écarté faute de donnée.
class RecipeFilterOutcome {
  final List<Recipe> recipes;

  /// Recettes qui conviendraient à tout le reste mais n'ont pas de donnée
  /// pour cette dimension. Une recette sans durée ni calories compte dans
  /// les deux lignes.
  final Map<RecipeFilterDimension, int> missingData;

  const RecipeFilterOutcome({
    required this.recipes,
    this.missingData = const {},
  });
}

/// Applique la recherche texte, le filtre et le tri à [corpus].
RecipeFilterOutcome applyRecipeFilter(
  Iterable<Recipe> corpus, {
  String query = '',
  RecipeFilter filter = RecipeFilter.none,
  RecipeFilterContext context = RecipeFilterContext.empty,
  RecipeSort sort = RecipeSort.bestRated,
}) {
  final kept = <Recipe>[];
  final missing = <RecipeFilterDimension, int>{};
  final active = filter.activeDimensions.toList(growable: false);
  for (final recipe in corpus) {
    if (!matchesRecipeQuery(recipe, query)) continue;
    var mismatch = false;
    final lacking = <RecipeFilterDimension>[];
    for (final d in active) {
      switch (filter.verdict(d, recipe, context)) {
        case FilterVerdict.match:
          break;
        case FilterVerdict.mismatch:
          mismatch = true;
        case FilterVerdict.missing:
          lacking.add(d);
      }
      if (mismatch) break;
    }
    if (mismatch) continue;
    if (lacking.isNotEmpty) {
      for (final d in lacking) {
        missing[d] = (missing[d] ?? 0) + 1;
      }
      continue;
    }
    kept.add(recipe);
  }
  kept.sort(recipeComparator(sort, context));
  return RecipeFilterOutcome(recipes: kept, missingData: missing);
}

/// Ordre d'un tri. Les recettes sans la donnée du tri vont en fin de liste,
/// puis le titre départage.
Comparator<Recipe> recipeComparator(
  RecipeSort sort,
  RecipeFilterContext context,
) {
  int byTitle(Recipe a, Recipe b) =>
      foldSearchText(a.titre).compareTo(foldSearchText(b.titre));
  int nullsLast<T extends Comparable<T>>(T? a, T? b, {bool desc = false}) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    return desc ? b.compareTo(a) : a.compareTo(b);
  }

  return switch (sort) {
    RecipeSort.bestRated => (a, b) {
      final c = nullsLast(
        context.myRatings[a.id],
        context.myRatings[b.id],
        desc: true,
      );
      return c != 0 ? c : byTitle(a, b);
    },
    RecipeSort.fastest => (a, b) {
      final c = nullsLast(context.totalMinutesOf(a), context.totalMinutesOf(b));
      return c != 0 ? c : byTitle(a, b);
    },
    RecipeSort.newest => (a, b) {
      final c = b.createdAt.compareTo(a.createdAt);
      return c != 0 ? c : byTitle(a, b);
    },
    RecipeSort.title => byTitle,
  };
}

/// Une valeur de filtre proposée : la clé qui se compare, le libellé qui
/// s'affiche, le nombre de recettes qui la portent.
class RecipeFacet {
  final String key;
  final String label;
  final int count;

  const RecipeFacet({
    required this.key,
    required this.label,
    required this.count,
  });
}

/// Les étiquettes présentes dans le corpus, les plus fréquentes en premier.
///
/// Rien n'est inventé : « asiatique » n'apparaît que si une recette la porte.
/// Le libellé retenu est la graphie la plus fréquente dans le corpus.
({List<RecipeFacet> dishTypes, List<RecipeFacet> cuisines}) recipeTagFacets(
  Iterable<Recipe> recipes,
) => (
  dishTypes: tagFacets(recipes, (r) => r.tags.dishTypes),
  cuisines: tagFacets(recipes, (r) => r.tags.cuisines),
);

/// Les valeurs d'une étiquette présentes dans le corpus, avec leur nombre.
List<RecipeFacet> tagFacets(
  Iterable<Recipe> recipes,
  Iterable<String> Function(Recipe) tagsOf,
) {
  final counts = <String, Map<String, int>>{};
  for (final r in recipes) {
    // Une recette ne compte qu'une fois par clé, même si elle répète l'étiquette.
    final seen = <String>{};
    for (final tag in tagsOf(r)) {
      final trimmed = tag.trim();
      if (trimmed.isEmpty) continue;
      final key = recipeTagKey(trimmed);
      if (!seen.add(key)) continue;
      final spellings = counts.putIfAbsent(key, () => {});
      spellings[trimmed] = (spellings[trimmed] ?? 0) + 1;
    }
  }
  final facets = <RecipeFacet>[];
  for (final entry in counts.entries) {
    final spellings = entry.value.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    final total = entry.value.values.fold(0, (sum, n) => sum + n);
    facets.add(
      RecipeFacet(key: entry.key, label: spellings.first.key, count: total),
    );
  }
  facets.sort((a, b) {
    final byCount = b.count.compareTo(a.count);
    return byCount != 0 ? byCount : a.label.compareTo(b.label);
  });
  return facets;
}

/// Ce que le sélecteur du planning affiche : la recherche par titre, le
/// filtre et les recettes écartées, appliqués dans cet ordre.
List<Recipe> filterPickerRecipes(
  Iterable<Recipe> recipes, {
  String query = '',
  RecipeFilter filter = RecipeFilter.none,
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
