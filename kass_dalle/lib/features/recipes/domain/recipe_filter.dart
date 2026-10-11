/// Filtrer une liste de recettes, sans IA : le sélecteur du planning et
/// l'écran Explorer partagent ce code.
///
/// Tout se calcule sur l'appareil, à partir des champs de la recette. Rien
/// n'est écrit dans la recette : les calories par portion valent
/// `totaux / parts`, calculées à l'affichage ; la note est celle du lecteur,
/// lue sous son compte.
library;

import '../../../core/services/cooklang_parser.dart' show readDurations;
import '../../../core/utils/ingredient_name.dart';
import '../../../core/utils/nutrition_quantity_converter.dart';
import 'estimated_times.dart';
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

/// Temps total d'une recette : préparation + cuisson, en minutes, durées
/// lues seules (`tags`, puis métadonnées CookLang).
///
/// Le repos (marinade, levée) n'y entre pas : il s'affiche à part. Une seule
/// des deux valeurs connue suffit ; aucune des deux, la recette est « sans
/// durée » (`null`).
int? recipeTotalMinutes(Recipe recipe) =>
    recipeTimes(recipe, includeEstimated: false).total;

/// Temps total, une durée estimée par l'IA comblant une durée absente.
int? recipeTotalMinutesWithEstimates(Recipe recipe) =>
    recipeTimes(recipe).total;

/// Les durées d'une recette, et lesquelles viennent de l'estimation.
class RecipeTimes {
  final int? prep;
  final int? cook;
  final bool prepEstimated;
  final bool cookEstimated;

  const RecipeTimes({
    this.prep,
    this.cook,
    this.prepEstimated = false,
    this.cookEstimated = false,
  });

  /// Préparation + cuisson ; `null` quand aucune des deux n'est connue.
  int? get total =>
      prep == null && cook == null ? null : (prep ?? 0) + (cook ?? 0);

  /// Vrai quand au moins une composante du total est estimée.
  bool get isEstimated => prepEstimated || cookEstimated;
}

/// L'estimation à afficher sur la fiche : seulement les durées que la
/// recette ne donne pas, ni dans `tags` ni dans son texte CookLang. `null`
/// quand il n'y a rien à afficher.
RecipeEstimatedTimes? recipeShownEstimate(Recipe recipe) {
  final times = recipeTimes(recipe);
  if (!times.isEstimated) return null;
  return RecipeEstimatedTimes(
    prep: times.prepEstimated ? times.prep : null,
    cook: times.cookEstimated ? times.cook : null,
  );
}

/// Durées lues d'une recette, mémorisées par instance : le tri « Plus
/// rapides » les relit à chaque comparaison, et la lecture des métadonnées
/// parcourt le texte.
final _readDurationsCache = Expando<_ReadDurations>('readDurations');

class _ReadDurations {
  final int? prep;
  final int? cook;
  const _ReadDurations(this.prep, this.cook);
}

_ReadDurations _readDurationsOf(Recipe recipe) =>
    _readDurationsCache[recipe] ??= () {
      final read = readDurations(
        prepTime: recipe.tags.prepTime,
        cookTime: recipe.tags.cookTime,
        cooklangs: [recipe.draftCooklang, recipe.rawCooklang],
      );
      return _ReadDurations(read.prep, read.cook);
    }();

/// Durées d'une recette, composante par composante : la durée lue d'abord
/// (`tags.prep_time` / `cook_time`, puis les métadonnées CookLang du
/// brouillon et du texte validé — `readDurations`, même règle que le
/// serveur), l'estimation de l'IA (`estimated_times`) à défaut, si
/// [includeEstimated].
RecipeTimes recipeTimes(Recipe recipe, {bool includeEstimated = true}) {
  final read = _readDurationsOf(recipe);
  final estimate = includeEstimated ? recipe.estimatedTimes : null;
  final prepEstimated = read.prep == null && estimate?.prep != null;
  final cookEstimated = read.cook == null && estimate?.cook != null;
  return RecipeTimes(
    prep: read.prep ?? (prepEstimated ? estimate!.prep : null),
    cook: read.cook ?? (cookEstimated ? estimate!.cook : null),
    prepEstimated: prepEstimated,
    cookEstimated: cookEstimated,
  );
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

/// Une durée telle qu'un lecteur d'écran la dit : « 20 minutes »,
/// « 1 heure 30 », « 2 heures ».
String spokenDuration(int minutes) {
  if (minutes < 60) return '$minutes minute${minutes > 1 ? 's' : ''}';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  final h = '$hours heure${hours > 1 ? 's' : ''}';
  return rest == 0 ? h : '$h $rest';
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

  /// « Compter les durées estimées » : une durée estimée par l'IA comble une
  /// durée absente dans le filtre « Temps total » et le tri « Plus rapides ».
  /// Coché par défaut. Ce n'est pas une valeur cochée : il ne compte pas
  /// dans « Filtres · N ».
  final bool countEstimatedTimes;

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
    this.countEstimatedTimes = true,
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

  /// Toutes les valeurs décochées, réglage « Compter les durées estimées »
  /// gardé : « Effacer tout » retire des choix, pas une préférence.
  RecipeFilter get cleared =>
      RecipeFilter(countEstimatedTimes: countEstimatedTimes);

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
    bool? countEstimatedTimes,
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
    countEstimatedTimes: countEstimatedTimes ?? this.countEstimatedTimes,
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
    'count_estimated_times': countEstimatedTimes,
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
      // Absent ou illisible : coché, la valeur par défaut.
      countEstimatedTimes: data['count_estimated_times'] is bool
          ? data['count_estimated_times'] as bool
          : true,
    );
  }

  /// Signature stable, pour savoir si le filtre a changé depuis une demande.
  String get signature {
    final parts = <String>[];
    for (final d in RecipeFilterDimension.values) {
      final keys = keysOf(d).toList()..sort();
      if (keys.isNotEmpty) parts.add('${d.name}=${keys.join(',')}');
    }
    if (!countEstimatedTimes) parts.add('estimated=off');
    return parts.join(';');
  }
}

/// Ce que le filtre lit hors de la recette.
class RecipeFilterContext {
  /// Notes du lecteur (sur 10), par identifiant de recette.
  final Map<String, int> myRatings;

  /// Temps total d'une recette. Par défaut [recipeTotalMinutes], durées lues
  /// seules : le sélecteur du planning n'emploie pas l'estimation.
  final int? Function(Recipe) totalMinutesOf;

  const RecipeFilterContext({
    this.myRatings = const {},
    this.totalMinutesOf = recipeTotalMinutes,
  });

  /// Le contexte d'Explorer : l'estimation comble une durée absente quand
  /// [RecipeFilter.countEstimatedTimes] est coché.
  factory RecipeFilterContext.forFilter(
    RecipeFilter filter, {
    Map<String, int> myRatings = const {},
  }) => RecipeFilterContext(
    myRatings: myRatings,
    totalMinutesOf: filter.countEstimatedTimes
        ? recipeTotalMinutesWithEstimates
        : recipeTotalMinutes,
  );

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

// ── Recherche par texte ──────────────────────────────────────────────────────

/// Les sections de la recherche par texte, dans l'ordre de l'écran. Une
/// recette va dans la première où tous les mots tapés se trouvent.
enum RecipeQuerySection {
  /// Tous les mots dans le titre.
  title('Dans le titre'),

  /// Tous les mots dans le titre et les étiquettes (cuisines, thèmes,
  /// occasions, types de plat), sans être tous dans le titre.
  tags('Par cuisine, type ou thème'),

  /// Tous les mots dans le titre, les étiquettes et les ingrédients
  /// principaux : les petits ingrédients n'y comptent pas.
  ingredients('Dans les ingrédients principaux');

  final String label;
  const RecipeQuerySection(this.label);
}

/// Ce qui a fait retenir une recette par la recherche par texte.
class RecipeQueryMatch {
  final RecipeQuerySection section;

  /// Section ingrédients : les ingrédients qui ont correspondu, tels
  /// qu'écrits dans la recette (« vin blanc »). Vide ailleurs.
  final List<String> ingredients;

  const RecipeQueryMatch(this.section, {this.ingredients = const []});
}

/// Les petits ingrédients propres à la recherche : présents dans presque
/// toutes les recettes, ils feraient sortir la moitié de la bibliothèque.
/// Comparés au premier mot du nom replié, au singulier ou au pluriel.
///
/// S'y ajoutent les assaisonnements dosés à la pincée
/// ([NutritionQuantityConverter.isSeasoning], lu sans être modifié). Cette
/// liste ne sert qu'à la recherche par texte : le filtre « Sans
/// l'ingrédient » et la nutrition ne la lisent pas.
const kSearchMinorIngredientWords = {
  'huile',
  'beurre',
  'vinaigre',
  'eau',
  'persil',
  'ciboulette',
  'coriandre',
  'basilic',
  'menthe',
  'sucre',
  'farine',
  'ail',
  'oignon',
};

/// Les mots de mesure qui précèdent un petit ingrédient : « gousse d'ail »,
/// « noix de beurre », « filet d'huile d'olive ».
const _measureWords = {
  'gousse',
  'brin',
  'branche',
  'botte',
  'bouquet',
  'feuille',
  'tige',
  'noix',
  'noisette',
  'filet',
  'trait',
  'pincee',
  'cuillere',
  'cuilleree',
};

/// Le mot replié au singulier : « oignons » → « oignon », « eaux » → « eau ».
String _singular(String word) {
  if (word.length > 3 && (word.endsWith('s') || word.endsWith('x'))) {
    return word.substring(0, word.length - 1);
  }
  return word;
}

/// Vrai pour un petit ingrédient : un assaisonnement dosé à la pincée, ou un
/// nom dont le premier mot — après une mesure comme « gousse d' » — est dans
/// [kSearchMinorIngredientWords].
bool isSearchMinorIngredient(String name) {
  if (NutritionQuantityConverter.isSeasoning(name)) return true;
  final words = foldSearchText(
    name,
  ).split(' ').where((w) => w.isNotEmpty).toList();
  var i = 0;
  while (i < words.length - 1 && _measureWords.contains(_singular(words[i]))) {
    i++;
    // « gousse d'ail », « noix de beurre », « filet d'huile ».
    while (i < words.length - 1 && (words[i] == 'de' || words[i] == 'd')) {
      i++;
    }
  }
  return i < words.length &&
      kSearchMinorIngredientWords.contains(_singular(words[i]));
}

/// Les mots tapés que la recherche ne cherche que dans les titres : ceux qui
/// nomment un petit ingrédient (« sel », « ail »). Mots tels que tapés
/// (« Sésame »), dans l'ordre de la saisie. La forme repliée ne sert qu'à
/// reconnaître le petit ingrédient et à écarter un doublon (« Sésame
/// sesame » ne cite que le premier).
List<String> titleOnlyQueryWords(String query) {
  final words = <String>[];
  final seen = <String>{};
  for (final typed in query.split(_typedWordSeparator)) {
    final folded = foldSearchText(typed);
    if (folded.isEmpty) continue;
    // Un mot tapé qui se replie en plusieurs (cas d'un caractère que le
    // repli découpe) : chaque partie, sous sa forme repliée.
    final parts = folded.split(' ');
    for (final part in parts) {
      if (part.isEmpty || !seen.add(part)) continue;
      if (_isMinorWord(part)) words.add(parts.length == 1 ? typed : part);
    }
  }
  return words;
}

/// Ce qui sépare deux mots tapés : tout sauf une lettre (accentuée comprise)
/// ou un chiffre — le même découpage que [foldSearchText], avant repli.
final _typedWordSeparator = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

bool _isMinorWord(String word) =>
    kSearchMinorIngredientWords.contains(_singular(word)) ||
    NutritionQuantityConverter.isSeasoning(word);

List<String> _queryWords(String query) =>
    foldSearchText(query).split(' ').where((w) => w.isNotEmpty).toList();

List<String> _wordsOf(Iterable<String> values) => [
  for (final v in values)
    ...foldSearchText(v).split(' ').where((w) => w.isNotEmpty),
];

/// Un mot tapé correspond quand un mot du texte commence par lui : « blanq »
/// trouve « blanquette », « bla » ne trouve pas « sablé ».
bool _hasWordStartingWith(List<String> words, String typed) =>
    words.any((w) => w.startsWith(typed));

/// La section où [recipe] se range pour [query], ou `null` si un mot tapé ne
/// s'y trouve nulle part. Texte vide : `null` aussi — il n'y a pas de
/// section sans texte, [applyRecipeFilter] garde alors tout.
///
/// Sans accents ni casse. Tous les mots tapés doivent correspondre. Un mot
/// tapé qui nomme un petit ingrédient n'est cherché que dans le titre ; les
/// petits ingrédients de la recette ne sont pas lus.
RecipeQueryMatch? matchRecipeQuery(Recipe recipe, String query) {
  final typed = _queryWords(query);
  if (typed.isEmpty) return null;
  final title = _wordsOf([recipe.titre]);
  if (typed.every((w) => _hasWordStartingWith(title, w))) {
    return const RecipeQueryMatch(RecipeQuerySection.title);
  }
  // Un petit ingrédient tapé et absent du titre : rien d'autre n'est lu.
  if (typed.any((w) => _isMinorWord(w) && !_hasWordStartingWith(title, w))) {
    return null;
  }
  final tags = _wordsOf([
    ...recipe.tags.cuisines,
    ...recipe.tags.themes,
    ...recipe.tags.occasions,
    ...recipe.tags.dishTypes,
  ]);
  final outsideTitle = typed
      .where((w) => !_hasWordStartingWith(title, w))
      .toList();
  if (outsideTitle.every((w) => _hasWordStartingWith(tags, w))) {
    return const RecipeQueryMatch(RecipeQuerySection.tags);
  }
  final remaining = outsideTitle
      .where((w) => !_hasWordStartingWith(tags, w))
      .toList();
  // Les noms affichés d'abord, l'index ensuite : « Avec : » cite la recette
  // telle qu'elle est écrite.
  final seen = <String>{};
  final ingredients = <String>[];
  for (final name in [
    ...recipe.ingredients.map((i) => i.name),
    ...recipe.ingredientsIndex,
  ]) {
    final folded = foldSearchText(name);
    if (folded.isEmpty || !seen.add(folded)) continue;
    if (isSearchMinorIngredient(name)) continue;
    ingredients.add(name.trim());
  }
  final cited = <String>[];
  for (final w in remaining) {
    final hit = ingredients.firstWhere(
      (name) => _hasWordStartingWith(_wordsOf([name]), w),
      orElse: () => '',
    );
    if (hit.isEmpty) return null;
    if (!cited.contains(hit)) cited.add(hit);
  }
  return RecipeQueryMatch(RecipeQuerySection.ingredients, ingredients: cited);
}

/// Le résultat d'un filtrage : les recettes retenues, triées, et ce qui a
/// été écarté faute de donnée.
class RecipeFilterOutcome {
  /// Toutes les recettes retenues. Avec du texte, dans l'ordre des sections
  /// ([sections]), le tri appliqué dans chacune.
  final List<Recipe> recipes;

  /// Avec du texte : les recettes de chaque section, triées, sections vides
  /// absentes. Sans texte : vide — la liste est simple.
  final Map<RecipeQuerySection, List<Recipe>> sections;

  /// Section ingrédients : les ingrédients qui ont fait retenir chaque
  /// recette, par identifiant.
  final Map<String, List<String>> matchedIngredients;

  /// Recettes qui conviendraient à tout le reste mais n'ont pas de donnée
  /// pour cette dimension. Une recette sans durée ni calories compte dans
  /// les deux lignes.
  final Map<RecipeFilterDimension, int> missingData;

  /// « Compter les durées estimées » décoché : recettes sans durée lue,
  /// écartées par « Temps total », que leur durée estimée aurait retenues.
  /// Comptées ici et non dans [missingData].
  final int estimatedTimeExcluded;

  const RecipeFilterOutcome({
    required this.recipes,
    this.sections = const {},
    this.matchedIngredients = const {},
    this.missingData = const {},
    this.estimatedTimeExcluded = 0,
  });
}

/// Applique la recherche texte, le filtre et le tri à [corpus].
///
/// Avec du texte, chaque recette retenue se range dans une section
/// ([matchRecipeQuery]) ; le tri s'applique dans chaque section, et l'ordre
/// des sections est fixe. Le total ([RecipeFilterOutcome.recipes]) compte
/// toutes les sections.
RecipeFilterOutcome applyRecipeFilter(
  Iterable<Recipe> corpus, {
  String query = '',
  RecipeFilter filter = RecipeFilter.none,
  RecipeFilterContext context = RecipeFilterContext.empty,
  RecipeSort sort = RecipeSort.bestRated,
}) {
  final hasQuery = _queryWords(query).isNotEmpty;
  final bySection = <RecipeQuerySection, List<Recipe>>{};
  final matchedIngredients = <String, List<String>>{};
  final missing = <RecipeFilterDimension, int>{};
  var estimatedExcluded = 0;
  final active = filter.activeDimensions.toList(growable: false);
  for (final recipe in corpus) {
    final match = hasQuery ? matchRecipeQuery(recipe, query) : null;
    if (hasQuery && match == null) continue;
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
        if (d == RecipeFilterDimension.totalTime &&
            _keptByEstimate(recipe, filter)) {
          estimatedExcluded++;
        } else {
          missing[d] = (missing[d] ?? 0) + 1;
        }
      }
      continue;
    }
    // Sans texte, une seule liste : rangée sous « titre », rendue à plat.
    final section = match?.section ?? RecipeQuerySection.title;
    bySection.putIfAbsent(section, () => []).add(recipe);
    if (match != null && match.ingredients.isNotEmpty) {
      matchedIngredients[recipe.id] = match.ingredients;
    }
  }
  final comparator = recipeComparator(sort, context);
  final sections = <RecipeQuerySection, List<Recipe>>{};
  final kept = <Recipe>[];
  for (final section in RecipeQuerySection.values) {
    final recipes = bySection[section];
    if (recipes == null || recipes.isEmpty) continue;
    recipes.sort(comparator);
    sections[section] = List.unmodifiable(recipes);
    kept.addAll(recipes);
  }
  return RecipeFilterOutcome(
    recipes: kept,
    sections: hasQuery ? sections : const {},
    matchedIngredients: matchedIngredients,
    missingData: missing,
    estimatedTimeExcluded: estimatedExcluded,
  );
}

/// Vrai quand [recipe], écartée faute de durée lue, aurait été retenue par
/// sa durée estimée — interrupteur « Compter les durées estimées » décoché.
bool _keptByEstimate(Recipe recipe, RecipeFilter filter) {
  if (filter.countEstimatedTimes) return false;
  final estimated = recipeTotalMinutesWithEstimates(recipe);
  final max = filter.maxTotalMinutes;
  return estimated != null && max != null && estimated <= max;
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
