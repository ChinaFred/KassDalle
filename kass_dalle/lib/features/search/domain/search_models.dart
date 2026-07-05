import '../../recipes/domain/recipe.dart';

enum ExploreSource { all, library, ai, web }

/// Paramètres de filtrage pour la recherche.
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
}

/// Un résultat de recherche : une recette + l'explication de la correspondance.
class RecipeSearchResult {
  final Recipe recipe;
  final String reason;

  const RecipeSearchResult({required this.recipe, required this.reason});
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

class WebSearchSuggestion {
  final String query;
  final String url;

  const WebSearchSuggestion({required this.query, required this.url});
}

/// Résultat global d'une recherche IA.
class SearchResultData {
  final List<RecipeSearchResult> libraryResults;

  final List<GeneratedRecipeSuggestion> generatedResults;

  final WebSearchSuggestion? webSuggestion;

  /// Si aucun résultat, suggestion de reformulation proposée par l'IA.
  final String? librarySuggestion;

  /// Observation de l'IA sur les préférences de l'utilisateur déduite de ses notes.
  final String? preferenceInsight;

  const SearchResultData({
    this.libraryResults = const [],
    this.generatedResults = const [],
    this.webSuggestion,
    this.librarySuggestion,
    this.preferenceInsight,
  });

  bool get isEmpty =>
      libraryResults.isEmpty &&
      generatedResults.isEmpty &&
      webSuggestion == null;
}

/// État de la page de recherche.
sealed class SearchState {
  const SearchState();
}

class SearchIdle extends SearchState {
  const SearchIdle();
}

class SearchLoading extends SearchState {
  const SearchLoading();
}

class SearchSuccess extends SearchState {
  final SearchResultData data;
  const SearchSuccess(this.data);
}

class SearchError extends SearchState {
  final String message;
  const SearchError(this.message);
}
