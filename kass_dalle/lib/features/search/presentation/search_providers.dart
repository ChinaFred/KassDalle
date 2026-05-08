import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/gemini_service.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/presentation/group_providers.dart';
import '../../recipes/data/recipe_repository.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/search_models.dart';

const _geminiApiKey = String.fromEnvironment(
  'GEMINI_API_KEY',
  defaultValue: '',
);

/// Notifier pour l'état de la page de recherche.
class SearchNotifier extends StateNotifier<SearchState> {
  final RecipeRepository _repo;
  final Ref _ref;

  SearchNotifier(this._repo, this._ref) : super(const SearchIdle());

  Future<void> search({
    required String query,
    required SearchParams params,
  }) async {
    if (query.trim().isEmpty) return;

    state = const SearchLoading();

    try {
      final myUid = _ref.read(appUserProvider).valueOrNull?.uid;
      if (myUid == null) {
        state = const SearchError('Utilisateur non connecté.');
        return;
      }

      // Constituer la liste des UIDs à interroger
      final ownerIds = <String>[];
      if (params.myRecipes) ownerIds.add(myUid);
      if (params.familyRecipes) {
        final memberIds =
            _ref.read(groupMemberIdsProvider).valueOrNull ?? {};
        ownerIds.addAll(memberIds);
      }

      if (ownerIds.isEmpty) {
        state = const SearchError(
          'Sélectionnez au moins une source (mes recettes ou famille).',
        );
        return;
      }

      // Charger les recettes depuis Firestore
      final recipes = await _repo.getAllByOwners(
        ownerIds,
        includeDrafts: params.includeDrafts && params.myRecipes,
      );

      if (recipes.isEmpty) {
        state = const SearchSuccess(
          SearchResultData(
            results: [],
            suggestion:
                'Aucune recette trouvée dans la sélection. Essayez d\'ajouter des recettes à votre collection.',
          ),
        );
        return;
      }

      // Construire les résumés compacts pour Gemini
      final summaries = recipes.map((r) => _buildSummary(r)).toList();

      // Appel Gemini
      if (_geminiApiKey.isEmpty) {
        state = const SearchError('Clé Gemini non configurée.');
        return;
      }
      final gemini = GeminiService(_geminiApiKey);
      final raw = await gemini.searchRecipes(
        query: query.trim(),
        recipes: summaries,
      );

      // Parser la réponse
      final resultsRaw = (raw['results'] as List? ?? []);
      final suggestion = raw['suggestion'] as String?;

      // Mapper les IDs aux recettes
      final recipeById = {for (final r in recipes) r.id: r};
      final results = resultsRaw
          .map((e) {
            final map = Map<String, dynamic>.from(e as Map);
            final id = map['id'] as String? ?? '';
            final reason = map['raison'] as String? ?? '';
            final recipe = recipeById[id];
            if (recipe == null) return null;
            return RecipeSearchResult(recipe: recipe, reason: reason);
          })
          .whereType<RecipeSearchResult>()
          .toList();

      state = SearchSuccess(
        SearchResultData(results: results, suggestion: suggestion),
      );
    } catch (e) {
      state = SearchError('Erreur lors de la recherche : $e');
    }
  }

  void reset() => state = const SearchIdle();
}

/// Construit un résumé compact d'une recette pour l'envoi à Gemini.
Map<String, String> _buildSummary(Recipe recipe) {
  final ingredients = recipe.ingredientsIndex.take(20).join(', ');
  final themes = recipe.tags.themes.join(', ');
  final cuisines = recipe.tags.cuisines.join(', ');
  final difficulty = recipe.tags.difficulty ?? '';
  final statusLabel = switch (recipe.reviewStatus) {
    ReviewStatus.validated => 'validée',
    ReviewStatus.draft => 'brouillon',
    ReviewStatus.inReview => 'en révision',
  };

  return {
    'id': recipe.id,
    'titre': recipe.titre,
    'livre': recipe.bookTitre ?? 'Sans livre',
    'ingredients': ingredients,
    'themes': themes,
    'cuisines': cuisines,
    'difficulte': difficulty,
    'statut': statusLabel,
  };
}

final searchNotifierProvider =
    StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final repo = ref.watch(recipeRepositoryProvider);
  return SearchNotifier(repo, ref);
});
