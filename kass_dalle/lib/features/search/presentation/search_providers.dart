import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../books/data/book_repository.dart';
import '../../groups/presentation/group_providers.dart';
import '../../recipes/data/recipe_rating_repository.dart';
import '../../recipes/data/recipe_repository.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/search_models.dart';
import '../../../core/services/error_reporting.dart';

class _ExploreLibraryResult {
  final List<RecipeSearchResult> results;
  final String? suggestion;
  final String? preferenceInsight;

  const _ExploreLibraryResult({
    required this.results,
    this.suggestion,
    this.preferenceInsight,
  });
}

class _ExploreContextData {
  final String myUid;
  final List<Recipe> recipes;
  final List<Map<String, String>> summaries;
  final List<Map<String, String>> ratedSummaries;
  final String? preferenceInsight;

  const _ExploreContextData({
    required this.myUid,
    required this.recipes,
    required this.summaries,
    required this.ratedSummaries,
    required this.preferenceInsight,
  });
}

class _GenerationVariant {
  final String label;
  final String instruction;

  const _GenerationVariant({required this.label, required this.instruction});
}

/// Notifier pour l'état de la page de recherche.
class SearchNotifier extends Notifier<SearchState> {
  late final RecipeRepository _repo;
  late final RecipeRatingRepository _ratingRepo;
  final BookRepository _bookRepo = BookRepository();

  static const _generationVariants = [
    _GenerationVariant(
      label: 'Fidele',
      instruction:
          'Propose la version la plus fidele, claire et rassurante de la demande.',
    ),
    _GenerationVariant(
      label: 'Rapide',
      instruction:
          'Propose une version plus simple, plus rapide ou plus accessible pour un quotidien charge.',
    ),
    _GenerationVariant(
      label: 'Creative',
      instruction:
          'Propose une version plus originale, gourmande ou surprenante sans sortir du besoin exprime.',
    ),
  ];

  @override
  SearchState build() {
    _repo = ref.read(recipeRepositoryProvider);
    _ratingRepo = ref.read(recipeRatingRepositoryProvider);
    return const SearchIdle();
  }

  Future<void> explore({
    required String query,
    required SearchParams params,
    required ExploreSource source,
  }) async {
    if (query.trim().isEmpty) return;

    state = const SearchLoading();

    try {
      final trimmedQuery = query.trim();
      final shouldUseLibrary =
          source == ExploreSource.all ||
          source == ExploreSource.library ||
          source == ExploreSource.ai;
      final context = shouldUseLibrary
          ? await _loadContext(params: params)
          : await _loadContext(
              params: const SearchParams(
                myRecipes: false,
                familyRecipes: false,
                includeDrafts: false,
              ),
            );

      final libraryFuture =
          source == ExploreSource.all || source == ExploreSource.library
          ? _searchLibrary(query: trimmedQuery, context: context)
          : null;
      final generatedFuture =
          source == ExploreSource.all || source == ExploreSource.ai
          ? _generateAlternatives(query: trimmedQuery, context: context)
          : null;
      final webFuture = source == ExploreSource.web
          ? _buildOptimizedWebSuggestion(trimmedQuery)
          : Future.value(
              source == ExploreSource.all
                  ? _buildDirectWebSuggestion(trimmedQuery)
                  : null,
            );

      final library = libraryFuture != null ? await libraryFuture : null;
      final generated = generatedFuture != null
          ? await generatedFuture
          : const <GeneratedRecipeSuggestion>[];
      final webSuggestion = await webFuture;

      state = SearchSuccess(
        SearchResultData(
          libraryResults: library?.results ?? const [],
          generatedResults: generated,
          webSuggestion: webSuggestion,
          librarySuggestion: library?.suggestion,
          preferenceInsight:
              library?.preferenceInsight ?? context.preferenceInsight,
        ),
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'searchProviders.explore',
        error: e,
        stackTrace: stackTrace,
      );
      state = SearchError('Erreur lors de l\'exploration : $e');
    }
  }

  void reset() => state = const SearchIdle();

  /// Sauvegarde la recette générée comme recette validée dans le livre Kass'Dalle IA.
  ///
  /// Le livre "Mes créations Kass'Dalle ✨" est créé automatiquement s'il
  /// n'existe pas encore pour cet utilisateur.
  Future<String> saveGeneratedRecipe(Recipe recipe) async {
    final uid = ref.read(appUserProvider).value?.uid;
    if (uid == null) throw Exception('Utilisateur non connecté.');

    // Trouver ou créer le livre spécial Kass'Dalle IA.
    final book = await _bookRepo.findOrCreateKassDalleBook(uid);

    final now = DateTime.now();
    final toSave = Recipe(
      id: '',
      titre: recipe.titre,
      langue: recipe.langue,
      rawCooklang: recipe.rawCooklang,
      imageUrls: const [],
      reviewStatus: ReviewStatus.validated,
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      portions: recipe.portions,
      ingredients: recipe.ingredients,
      bookId: book.id,
      bookTitre: book.titre,
    );
    return _repo.createRecipe(toSave);
  }

  Future<_ExploreContextData> _loadContext({
    required SearchParams params,
  }) async {
    final myUid = ref.read(appUserProvider).value?.uid;
    if (myUid == null) {
      throw Exception('Utilisateur non connecté.');
    }

    // Deux publics, deux requêtes. Elles étaient réunies en une seule, et cette
    // réunion coûtait la confidentialité : un corpus mêlant mes recettes et
    // celles de la famille ne peut appliquer qu'une règle, et c'était la plus
    // permissive. Les recettes du livre « Mes Recettes Secrètes » des autres
    // membres entraient donc dans le contexte envoyé au modèle.
    final familyIds = params.familyRecipes
        ? (ref.read(groupMemberIdsProvider).value ?? const <String>{})
              .where((id) => id != myUid)
              .toList(growable: false)
        : const <String>[];

    final results = await Future.wait([
      if (params.myRecipes)
        _repo.getAllByOwners([myUid], includeDrafts: params.includeDrafts)
      else
        Future.value(const <Recipe>[]),
      if (familyIds.isNotEmpty)
        _repo.getAllByOwners(familyIds, excludePrivate: true)
      else
        Future.value(const <Recipe>[]),
    ]);
    final recipes = [...results[0], ...results[1]];

    final userRatings = await _ratingRepo.getAllForUser(myUid);
    final ratingByRecipeId = {
      for (final rating in userRatings) rating.recipeId: rating.rating,
    };

    final summaries = recipes
        .map((recipe) {
          final summary = _buildSummary(recipe);
          final note = ratingByRecipeId[recipe.id];
          return {...summary, 'note': note != null ? '$note/10' : 'non notee'};
        })
        .toList(growable: false);

    final ratedSummaries = summaries
        .where((summary) => summary['note'] != 'non notee')
        .toList(growable: false);

    return _ExploreContextData(
      myUid: myUid,
      recipes: recipes,
      summaries: summaries,
      ratedSummaries: ratedSummaries,
      preferenceInsight: _buildPreferenceInsight(
        recipes: recipes,
        ratingByRecipeId: ratingByRecipeId,
      ),
    );
  }

  Future<_ExploreLibraryResult> _searchLibrary({
    required String query,
    required _ExploreContextData context,
  }) async {
    if (context.summaries.isEmpty) {
      return const _ExploreLibraryResult(
        results: [],
        suggestion:
            'Aucune recette disponible dans ce périmètre. Élargissez à votre famille ou créez une nouvelle recette.',
      );
    }

    final gemini = ref.read(geminiServiceProvider);
    final raw = await gemini.searchRecipes(
      query: query,
      recipes: context.summaries,
      ratedRecipes: context.ratedSummaries,
    );

    final resultsRaw = raw['results'] as List? ?? [];
    final recipeById = {
      for (final recipe in context.recipes) recipe.id: recipe,
    };
    final results = resultsRaw
        .map((entry) {
          final map = Map<String, dynamic>.from(entry as Map);
          final id = map['id'] as String? ?? '';
          final recipe = recipeById[id];
          if (recipe == null) return null;
          return RecipeSearchResult(
            recipe: recipe,
            reason: map['raison'] as String? ?? '',
          );
        })
        .whereType<RecipeSearchResult>()
        .toList(growable: false);

    return _ExploreLibraryResult(
      results: results,
      suggestion: raw['suggestion'] as String?,
      preferenceInsight:
          raw['preference_insight'] as String? ?? context.preferenceInsight,
    );
  }

  Future<List<GeneratedRecipeSuggestion>> _generateAlternatives({
    required String query,
    required _ExploreContextData context,
  }) async {
    final futures = _generationVariants
        .map(
          (variant) => _generateSingleAlternative(
            query: query,
            context: context,
            variant: variant,
          ),
        )
        .toList(growable: false);

    final initial = await Future.wait(futures);
    final unique = <GeneratedRecipeSuggestion>[];

    for (final entry in initial.indexed) {
      final suggestion = entry.$2;
      if (!_containsDuplicate(unique, suggestion)) {
        unique.add(suggestion);
        continue;
      }

      final rerolled = await _generateSingleAlternative(
        query: query,
        context: context,
        variant: _generationVariants[entry.$1],
        avoidTitles: unique.map((item) => item.recipe.titre).toList(),
      );
      if (!_containsDuplicate(unique, rerolled)) {
        unique.add(rerolled);
      }
    }

    return unique;
  }

  Future<GeneratedRecipeSuggestion> _generateSingleAlternative({
    required String query,
    required _ExploreContextData context,
    required _GenerationVariant variant,
    List<String> avoidTitles = const [],
  }) async {
    final gemini = ref.read(geminiServiceProvider);
    final raw = await gemini.generateRecipe(
      query: query,
      preferenceInsight: context.preferenceInsight,
      libraryContext: context.summaries.take(12).toList(growable: false),
      variantLabel: variant.label,
      variantInstruction: variant.instruction,
      siblingVariantLabels: _generationVariants
          .map((item) => item.label)
          .toList(growable: false),
      avoidTitles: avoidTitles,
    );

    return GeneratedRecipeSuggestion(
      recipe: _recipeFromGeneratedRaw(raw, fallbackTitle: query),
      justification: raw['justification'] as String? ?? variant.instruction,
      variantLabel: raw['variant_label'] as String? ?? variant.label,
    );
  }

  Recipe _recipeFromGeneratedRaw(
    Map<String, dynamic> raw, {
    required String fallbackTitle,
  }) {
    final titre = raw['titre'] as String? ?? fallbackTitle;
    final langue = raw['langue'] as String? ?? 'fr';
    final cooklang = raw['cooklang'] as String? ?? '';
    final ingredientsIndex = List<String>.from(
      raw['ingredients_index'] as List? ?? [],
    );
    final ingredientsRaw = raw['ingredients'] as List? ?? [];
    final ingredients = ingredientsRaw
        .map((entry) {
          final map = Map<String, dynamic>.from(entry as Map);
          return RecipeIngredient(
            name: map['name'] as String? ?? '',
            qty: map['qty'] as String? ?? '',
            unit: map['unit'] as String? ?? '',
          );
        })
        .toList(growable: false);
    final tagsRaw = Map<String, dynamic>.from(raw['tags'] as Map? ?? {});
    final tags = RecipeTags(
      themes: List<String>.from(tagsRaw['themes'] as List? ?? []),
      cuisines: List<String>.from(tagsRaw['cuisines'] as List? ?? []),
      occasions: List<String>.from(tagsRaw['occasions'] as List? ?? []),
      dishTypes: List<String>.from(tagsRaw['dish_types'] as List? ?? []),
      difficulty: tagsRaw['difficulty'] as String?,
      prepTime: tagsRaw['prep_time'] as int?,
      cookTime: tagsRaw['cook_time'] as int?,
    );
    final portions = raw['portions'] as int?;
    final now = DateTime.now();
    return Recipe(
      id: '',
      titre: titre,
      langue: langue,
      rawCooklang: cooklang,
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: tags,
      ingredientsIndex: ingredientsIndex,
      createdBy: '',
      createdAt: now,
      updatedAt: now,
      portions: portions,
      ingredients: ingredients,
    );
  }

  bool _containsDuplicate(
    List<GeneratedRecipeSuggestion> existing,
    GeneratedRecipeSuggestion candidate,
  ) {
    for (final current in existing) {
      if (_isDuplicateGeneratedRecipe(current.recipe, candidate.recipe)) {
        return true;
      }
    }
    return false;
  }

  bool _isDuplicateGeneratedRecipe(Recipe left, Recipe right) {
    final leftTitle = _normalizeRecipeToken(left.titre);
    final rightTitle = _normalizeRecipeToken(right.titre);
    if (leftTitle.isNotEmpty && leftTitle == rightTitle) {
      return true;
    }

    final leftIngredients = left.ingredients
        .map((item) => _normalizeRecipeToken(item.name))
        .where((item) => item.isNotEmpty)
        .toSet();
    final rightIngredients = right.ingredients
        .map((item) => _normalizeRecipeToken(item.name))
        .where((item) => item.isNotEmpty)
        .toSet();
    if (leftIngredients.isEmpty || rightIngredients.isEmpty) {
      return false;
    }

    final intersection = leftIngredients.intersection(rightIngredients).length;
    final smallest = leftIngredients.length < rightIngredients.length
        ? leftIngredients.length
        : rightIngredients.length;
    return smallest > 0 && intersection / smallest >= 0.8;
  }

  String _normalizeRecipeToken(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
  }

  String? _buildPreferenceInsight({
    required List<Recipe> recipes,
    required Map<String, num> ratingByRecipeId,
  }) {
    final liked = <String>[];
    final disliked = <String>[];

    for (final recipe in recipes) {
      final rating = ratingByRecipeId[recipe.id];
      if (rating == null) continue;
      if (rating >= 8 && liked.length < 3) {
        liked.add(recipe.titre);
      } else if (rating <= 4 && disliked.length < 2) {
        disliked.add(recipe.titre);
      }
    }

    if (liked.isEmpty && disliked.isEmpty) return null;

    final parts = <String>[];
    if (liked.isNotEmpty) {
      parts.add('Aime particulierement : ${liked.join(', ')}.');
    }
    if (disliked.isNotEmpty) {
      parts.add('A tendance a eviter : ${disliked.join(', ')}.');
    }
    return parts.join(' ');
  }

  Future<WebSearchSuggestion> _buildOptimizedWebSuggestion(String query) async {
    final gemini = ref.read(geminiServiceProvider);
    final optimizedQuery = await gemini.generateWebSearchQuery(query);
    return _buildWebSuggestion(optimizedQuery);
  }

  WebSearchSuggestion _buildDirectWebSuggestion(String query) {
    return _buildWebSuggestion(query);
  }

  WebSearchSuggestion _buildWebSuggestion(String query) {
    final encoded = Uri.encodeComponent('$query recette');
    return WebSearchSuggestion(
      query: query,
      url: 'https://www.google.com/search?q=$encoded',
    );
  }
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

final searchNotifierProvider = NotifierProvider<SearchNotifier, SearchState>(
  SearchNotifier.new,
);
