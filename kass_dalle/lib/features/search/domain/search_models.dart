import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';

/// Les sources de l'écran Explorer : quelles recettes charger.
class SearchParams {
  final bool myRecipes;
  final bool familyRecipes;
  final bool includeDrafts;

  const SearchParams({
    this.myRecipes = true,
    this.familyRecipes = true,
    this.includeDrafts = false,
  });

  SearchParams copyWith({
    bool? myRecipes,
    bool? familyRecipes,
    bool? includeDrafts,
  }) {
    return SearchParams(
      myRecipes: myRecipes ?? this.myRecipes,
      familyRecipes: familyRecipes ?? this.familyRecipes,
      includeDrafts: includeDrafts ?? this.includeDrafts,
    );
  }

  /// Forme enregistrée : `['mine', 'family', 'drafts']`.
  List<String> toList() => [
    if (myRecipes) 'mine',
    if (familyRecipes) 'family',
    if (includeDrafts) 'drafts',
  ];

  factory SearchParams.fromList(Object? raw) {
    if (raw is! List) return const SearchParams();
    final values = raw.whereType<String>().toSet();
    return SearchParams(
      myRecipes: values.contains('mine'),
      familyRecipes: values.contains('family'),
      includeDrafts: values.contains('drafts'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SearchParams &&
      other.myRecipes == myRecipes &&
      other.familyRecipes == familyRecipes &&
      other.includeDrafts == includeDrafts;

  @override
  int get hashCode => Object.hash(myRecipes, familyRecipes, includeDrafts);
}

/// Ce que l'écran Explorer retient pour le lecteur : sources, filtres et tri.
///
/// Une préférence de lecteur, comme le périmètre du planning : elle vit sous
/// `users/{uid}/preferences/explore_filters`, jamais dans un document
/// partagé. Le texte du champ de recherche n'en fait pas partie.
class ExplorePreferences {
  final SearchParams sources;
  final RecipeFilter filter;
  final RecipeSort sort;

  const ExplorePreferences({
    this.sources = const SearchParams(),
    this.filter = RecipeFilter.none,
    this.sort = RecipeSort.bestRated,
  });

  static const defaults = ExplorePreferences();

  ExplorePreferences copyWith({
    SearchParams? sources,
    RecipeFilter? filter,
    RecipeSort? sort,
  }) => ExplorePreferences(
    sources: sources ?? this.sources,
    filter: filter ?? this.filter,
    sort: sort ?? this.sort,
  );

  Map<String, dynamic> toMap() => {
    'sources': sources.toList(),
    'sort': sort.storageKey,
    'filters': filter.toMap(),
  };

  /// Lit la préférence enregistrée. Un champ illisible reprend sa valeur par
  /// défaut : une préférence abîmée ne ferme pas l'écran.
  factory ExplorePreferences.fromMap(Map<String, dynamic> data) {
    final filters = data['filters'];
    return ExplorePreferences(
      sources: data.containsKey('sources')
          ? SearchParams.fromList(data['sources'])
          : const SearchParams(),
      filter: filters is Map
          ? RecipeFilter.fromMap(Map<String, dynamic>.from(filters))
          : RecipeFilter.none,
      sort: RecipeSort.fromStorage(data['sort']),
    );
  }
}

/// Les recettes du périmètre, chargées une fois par choix de sources.
class ExploreCorpus {
  final String myUid;
  final List<Recipe> recipes;

  /// Notes du lecteur (sur 10), par recette.
  final Map<String, int> myRatings;

  /// Observation locale tirée des notes, envoyée à la création d'idées.
  final String? preferenceInsight;

  const ExploreCorpus({
    required this.myUid,
    required this.recipes,
    this.myRatings = const {},
    this.preferenceInsight,
  });
}

/// Une recette retenue, avec la raison donnée par l'IA quand elle vient
/// d'elle. Sans raison, c'est une recette de la bibliothèque, listée par le
/// filtre local.
class RecipeSearchResult {
  final Recipe recipe;
  final String? reason;

  const RecipeSearchResult({required this.recipe, this.reason});
}

class GeneratedRecipeSuggestion {
  final Recipe recipe;
  final String justification;
  final String variantLabel;

  const GeneratedRecipeSuggestion({
    required this.recipe,
    required this.justification,
    required this.variantLabel,
  });
}

/// Adresse de « Voir sur Google » (section « Sur le web ») : le texte tel
/// quel, plus « recette ». Aucun appel d'IA.
Uri googleRecipeSearchUri(String query) =>
    Uri.https('www.google.com', '/search', {'q': '${query.trim()} recette'});

/// Ce qui a été demandé à l'IA : le texte, et l'état des filtres et des
/// sources à ce moment, pour dire quand ils ont changé depuis.
class AiRankingRequest {
  final String query;
  final String filterSignature;
  final SearchParams sources;

  /// Recettes envoyées comme corpus : celles des filtres, sans le texte.
  final List<Recipe> corpus;

  const AiRankingRequest({
    required this.query,
    required this.filterSignature,
    required this.sources,
    required this.corpus,
  });

  /// Vrai si le texte, les filtres ou les sources ne sont plus ceux de la
  /// demande.
  bool isStale({
    required String query,
    required String filterSignature,
    required SearchParams sources,
  }) =>
      query.trim() != this.query ||
      filterSignature != this.filterSignature ||
      sources != this.sources;
}

/// État de la section « Choisies par l'IA ».
sealed class AiRankingState {
  const AiRankingState();
}

class AiRankingIdle extends AiRankingState {
  const AiRankingIdle();
}

class AiRankingLoading extends AiRankingState {
  final AiRankingRequest request;
  const AiRankingLoading(this.request);
}

class AiRankingSuccess extends AiRankingState {
  final AiRankingRequest request;
  final List<RecipeSearchResult> results;

  /// Reformulation proposée par l'IA quand elle ne retient rien.
  final String? suggestion;

  /// Observation de l'IA sur les goûts du lecteur, tirée de ses notes.
  final String? preferenceInsight;

  const AiRankingSuccess({
    required this.request,
    required this.results,
    this.suggestion,
    this.preferenceInsight,
  });
}

class AiRankingError extends AiRankingState {
  final AiRankingRequest request;
  final Object error;
  const AiRankingError(this.request, this.error);
}

/// État de la section « Idées de l'IA ».
sealed class AiIdeasState {
  const AiIdeasState();
}

class AiIdeasIdle extends AiIdeasState {
  const AiIdeasIdle();
}

class AiIdeasLoading extends AiIdeasState {
  final String query;
  const AiIdeasLoading(this.query);
}

class AiIdeasSuccess extends AiIdeasState {
  final String query;
  final List<GeneratedRecipeSuggestion> ideas;

  /// Idées déjà enregistrées, avec l'identifiant de leur brouillon : la
  /// tuile ouvre ce brouillon au lieu d'en permettre un second.
  final Map<GeneratedRecipeSuggestion, String> saved;

  const AiIdeasSuccess(this.query, this.ideas, {this.saved = const {}});

  /// Vrai s'il reste une idée que quitter l'écran ferait perdre.
  bool get hasUnsaved => ideas.any((i) => !saved.containsKey(i));
}

class AiIdeasError extends AiIdeasState {
  final String query;
  final Object error;
  const AiIdeasError(this.query, this.error);
}
