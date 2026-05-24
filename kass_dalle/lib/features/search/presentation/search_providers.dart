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

/// Notifier pour l'état de la page de recherche.
class SearchNotifier extends Notifier<SearchState> {
  late final RecipeRepository _repo;
  late final RecipeRatingRepository _ratingRepo;
  final BookRepository _bookRepo = BookRepository();

  @override
  SearchState build() {
    _repo = ref.read(recipeRepositoryProvider);
    _ratingRepo = ref.read(recipeRatingRepositoryProvider);
    return const SearchIdle();
  }

  Future<void> search({
    required String query,
    required SearchParams params,
  }) async {
    if (query.trim().isEmpty) return;

    state = const SearchLoading();

    try {
      final myUid = ref.read(appUserProvider).value?.uid;
      if (myUid == null) {
        state = const SearchError('Utilisateur non connecté.');
        return;
      }

      // Constituer la liste des UIDs à interroger
      final ownerIds = <String>[];
      if (params.myRecipes) ownerIds.add(myUid);
      if (params.familyRecipes) {
        final memberIds = ref.read(groupMemberIdsProvider).value ?? {};
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

      // Charger les notes personnelles de l'utilisateur
      final userRatings = await _ratingRepo.getAllForUser(myUid);
      final ratingByRecipeId = {
        for (final r in userRatings) r.recipeId: r.rating,
      };

      // Construire les résumés compacts pour Gemini (avec note)
      final summaries = recipes.map((r) {
        final s = _buildSummary(r);
        final note = ratingByRecipeId[r.id];
        return {...s, 'note': note != null ? '$note/10' : 'non notée'};
      }).toList();

      // Résumés des recettes notées seulement (pour inférence des préférences)
      final ratedSummaries = summaries
          .where((s) => s['note'] != 'non notée')
          .toList();

      // Appel Gemini
      final gemini = ref.read(geminiServiceProvider);
      final raw = await gemini.searchRecipes(
        query: query.trim(),
        recipes: summaries,
        ratedRecipes: ratedSummaries,
      );

      // Parser la réponse
      final resultsRaw = (raw['results'] as List? ?? []);
      final suggestion = raw['suggestion'] as String?;
      final preferenceInsight = raw['preference_insight'] as String?;

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
        SearchResultData(
          results: results,
          suggestion: suggestion,
          preferenceInsight: preferenceInsight,
        ),
      );
    } catch (e) {
      state = SearchError('Erreur lors de la recherche : $e');
    }
  }

  void reset() => state = const SearchIdle();

  /// Génère une recette originale via Gemini selon la requête et les préférences.
  Future<void> generateRecipe({
    required String query,
    String? preferenceInsight,
  }) async {
    state = const SearchGenerating();
    try {
      final gemini = ref.read(geminiServiceProvider);
      final raw = await gemini.generateRecipe(
        query: query,
        preferenceInsight: preferenceInsight,
      );

      final titre = raw['titre'] as String? ?? query;
      final langue = raw['langue'] as String? ?? 'fr';
      final cooklang = raw['cooklang'] as String? ?? '';
      final ingredientsIndex = List<String>.from(
        raw['ingredients_index'] as List? ?? [],
      );
      final ingredientsRaw = raw['ingredients'] as List? ?? [];
      final ingredients = ingredientsRaw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return RecipeIngredient(
          name: m['name'] as String? ?? '',
          qty: m['qty'] as String? ?? '',
          unit: m['unit'] as String? ?? '',
        );
      }).toList();
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
      final recipe = Recipe(
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
      state = SearchGenerated(recipe);
    } catch (e) {
      state = SearchError('Erreur lors de la génération : $e');
    }
  }

  /// Sauvegarde la recette générée comme brouillon dans le livre Kass'Dalle IA.
  ///
  /// Le livre "Mes créations Kass'Dalle ✨" est créé automatiquement s'il
  /// n'existe pas encore pour cet utilisateur.
  Future<void> saveGeneratedRecipe(Recipe recipe) async {
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
      reviewStatus: ReviewStatus.draft,
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
    await _repo.createRecipe(toSave);
    state = const SearchIdle();
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


