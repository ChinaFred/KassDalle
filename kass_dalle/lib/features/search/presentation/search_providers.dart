import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../books/data/book_repository.dart';
import '../../groups/presentation/group_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../data/explore_preferences_repository.dart';
import '../domain/search_models.dart';

// ── Préférence du lecteur : sources, filtres, tri ─────────────────────────────

final explorePreferencesRepositoryProvider =
    Provider<ExplorePreferencesRepository>(
      (ref) => ExplorePreferencesRepository(),
    );

/// Sources, filtres et tri de l'écran Explorer, relus à l'ouverture et
/// enregistrés à chaque changement sous `users/{uid}/preferences/explore_filters`.
class ExplorePreferencesNotifier extends AsyncNotifier<ExplorePreferences> {
  Timer? _saveTimer;

  @override
  Future<ExplorePreferences> build() async {
    ref.onDispose(() => _saveTimer?.cancel());
    final uid = ref.watch(appUserProvider.select((u) => u.value?.uid));
    if (uid == null) return ExplorePreferences.defaults;
    return ref.read(explorePreferencesRepositoryProvider).load(uid);
  }

  /// Applique [next] tout de suite et l'enregistre une demi-seconde plus
  /// tard : cocher cinq puces d'affilée n'écrit qu'une fois.
  void apply(ExplorePreferences next) {
    state = AsyncData(next);
    final uid = ref.read(appUserProvider).value?.uid;
    if (uid == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(ref.read(explorePreferencesRepositoryProvider).save(uid, next));
    });
  }
}

final explorePreferencesProvider =
    AsyncNotifierProvider<ExplorePreferencesNotifier, ExplorePreferences>(
      ExplorePreferencesNotifier.new,
    );

// ── Corpus : les recettes des sources choisies ───────────────────────────────

/// Les recettes des sources choisies, et les notes du lecteur.
///
/// Deux publics, deux requêtes. Elles étaient réunies en une seule, et cette
/// réunion coûtait la confidentialité : un corpus mêlant mes recettes et
/// celles de la famille ne peut appliquer qu'une règle, et c'était la plus
/// permissive. Les recettes du livre « Mes Recettes Secrètes » des autres
/// membres entraient donc dans le contexte envoyé au modèle.
final exploreCorpusProvider = FutureProvider.autoDispose
    .family<ExploreCorpus, SearchParams>((ref, params) async {
      final myUid = ref.watch(appUserProvider.select((u) => u.value?.uid));
      if (myUid == null) throw StateError('Utilisateur non connecté.');
      final repo = ref.read(recipeRepositoryProvider);
      final ratingRepo = ref.read(recipeRatingRepositoryProvider);

      final familyIds = params.familyRecipes
          ? (ref.watch(groupMemberIdsProvider).value ?? const <String>{})
                .where((id) => id != myUid)
                .toList(growable: false)
          : const <String>[];

      final results = await Future.wait([
        if (params.myRecipes)
          repo.getAllByOwners([myUid], includeDrafts: params.includeDrafts)
        else
          Future.value(const <Recipe>[]),
        if (familyIds.isNotEmpty)
          repo.getAllByOwners(familyIds, excludePrivate: true)
        else
          Future.value(const <Recipe>[]),
      ]);
      final recipes = [...results[0], ...results[1]];

      final userRatings = await ratingRepo.getAllForUser(myUid);
      final myRatings = {
        for (final rating in userRatings) rating.recipeId: rating.rating,
      };

      return ExploreCorpus(
        myUid: myUid,
        recipes: recipes,
        myRatings: myRatings,
        preferenceInsight: buildPreferenceInsight(
          recipes: recipes,
          ratingByRecipeId: myRatings,
        ),
      );
    });

/// Observation locale tirée des notes du lecteur, envoyée à la création
/// d'idées. `null` sans note marquante.
String? buildPreferenceInsight({
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
    parts.add('Aime particulièrement : ${liked.join(', ')}.');
  }
  if (disliked.isNotEmpty) {
    parts.add('A tendance à éviter : ${disliked.join(', ')}.');
  }
  return parts.join(' ');
}

/// Construit un résumé compact d'une recette pour l'envoi au modèle.
Map<String, String> buildRecipeSummary(Recipe recipe, {int? myRating}) {
  final statusLabel = switch (recipe.reviewStatus) {
    ReviewStatus.validated => 'validée',
    ReviewStatus.draft => 'brouillon',
    ReviewStatus.inReview => 'en révision',
  };
  return {
    'id': recipe.id,
    'titre': recipe.titre,
    'livre': recipe.bookTitre ?? 'Sans livre',
    'ingredients': recipe.ingredientsIndex.take(20).join(', '),
    'themes': recipe.tags.themes.join(', '),
    'cuisines': recipe.tags.cuisines.join(', '),
    'difficulte': recipe.tags.difficulty ?? '',
    'statut': statusLabel,
    // Inchangé depuis la version précédente : le prompt lit « non notee ».
    'note': myRating != null ? '$myRating/10' : 'non notee',
  };
}

// ── « Chercher avec l'IA » : classement facturé ──────────────────────────────

/// La section « Choisies par l'IA ».
///
/// Le corpus envoyé est celui des filtres, sans le texte : le texte est la
/// demande. La liste locale reste utilisable pendant le chargement. Une
/// réponse arrivée après une nouvelle demande est ignorée.
class AiRankingNotifier extends Notifier<AiRankingState> {
  @override
  AiRankingState build() => const AiRankingIdle();

  Future<void> rank(
    AiRankingRequest request,
    Map<String, int> myRatings,
  ) async {
    // Une demande identique déjà en cours ne repart pas : un second appui
    // coûterait un second appel facturé pour la même réponse.
    if (state case AiRankingLoading(request: final current)
        when !current.isStale(
          query: request.query,
          filterSignature: request.filterSignature,
          sources: request.sources,
        )) {
      return;
    }
    state = AiRankingLoading(request);
    try {
      final summaries = [
        for (final r in request.corpus)
          buildRecipeSummary(r, myRating: myRatings[r.id]),
      ];
      final rated = summaries
          .where((s) => s['note'] != 'non notee')
          .toList(growable: false);
      final raw = await ref
          .read(geminiServiceProvider)
          .searchRecipes(
            query: request.query,
            recipes: summaries,
            ratedRecipes: rated,
          );
      if (!_isCurrent(request)) return;

      final byId = {for (final r in request.corpus) r.id: r};
      final results = (raw['results'] as List? ?? const [])
          .map((entry) {
            final map = Map<String, dynamic>.from(entry as Map);
            final recipe = byId[map['id'] as String? ?? ''];
            if (recipe == null) return null;
            final reason = (map['raison'] as String? ?? '').trim();
            return RecipeSearchResult(
              recipe: recipe,
              reason: reason.isEmpty ? null : reason,
            );
          })
          .whereType<RecipeSearchResult>()
          .toList(growable: false);
      state = AiRankingSuccess(
        request: request,
        results: results,
        suggestion: _nonEmpty(raw['suggestion']),
        preferenceInsight: _nonEmpty(raw['preference_insight']),
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'searchProviders.aiRanking',
        error: e,
        stackTrace: stackTrace,
        context: {
          'query_length': request.query.length,
          'corpus_size': request.corpus.length,
          'filters': request.filterSignature,
        },
      );
      if (_isCurrent(request)) state = AiRankingError(request, e);
    }
  }

  bool _isCurrent(AiRankingRequest request) => switch (state) {
    AiRankingLoading(request: final r) => identical(r, request),
    _ => false,
  };

  /// Ferme la section.
  void close() => state = const AiRankingIdle();
}

final aiRankingProvider =
    NotifierProvider.autoDispose<AiRankingNotifier, AiRankingState>(
      AiRankingNotifier.new,
    );

// ── « Imaginer 3 recettes » ──────────────────────────────────────────────────

class _GenerationVariant {
  final String label;
  final String instruction;

  const _GenerationVariant({required this.label, required this.instruction});
}

/// La section « Idées de l'IA » : trois recettes imaginées sur le texte du
/// champ, sur demande seulement.
class AiIdeasNotifier extends Notifier<AiIdeasState> {
  static const _generationVariants = [
    _GenerationVariant(
      label: 'Fidèle',
      instruction:
          'Propose la version la plus fidèle, claire et rassurante de la demande.',
    ),
    _GenerationVariant(
      label: 'Rapide',
      instruction:
          'Propose une version plus simple, plus rapide ou plus accessible pour un quotidien chargé.',
    ),
    _GenerationVariant(
      label: 'Créative',
      instruction:
          'Propose une version plus originale, gourmande ou surprenante sans sortir du besoin exprimé.',
    ),
  ];

  @override
  AiIdeasState build() => const AiIdeasIdle();

  Future<void> imagine(String query, ExploreCorpus corpus) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    // Trois rédactions déjà en cours : pas de second lot facturé.
    if (state is AiIdeasLoading) return;
    state = AiIdeasLoading(trimmed);
    try {
      final context = [
        for (final r in corpus.recipes.take(12))
          buildRecipeSummary(r, myRating: corpus.myRatings[r.id]),
      ];
      final ideas = await _generateAlternatives(
        query: trimmed,
        context: context,
        preferenceInsight: corpus.preferenceInsight,
      );
      if (state case AiIdeasLoading(query: final q) when q == trimmed) {
        state = AiIdeasSuccess(trimmed, ideas);
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'searchProviders.aiIdeas',
        error: e,
        stackTrace: stackTrace,
        context: {'query_length': trimmed.length},
      );
      if (state case AiIdeasLoading(query: final q) when q == trimmed) {
        state = AiIdeasError(trimmed, e);
      }
    }
  }

  /// Ferme la section.
  void close() => state = const AiIdeasIdle();

  /// Note qu'une idée a été enregistrée : quitter l'écran ne la perd plus.
  void markSaved(GeneratedRecipeSuggestion idea, String draftId) {
    if (state case AiIdeasSuccess(:final query, :final ideas, :final saved)) {
      state = AiIdeasSuccess(query, ideas, saved: {...saved, idea: draftId});
    }
  }

  /// Enregistre une recette imaginée en brouillon dans « Mes créations
  /// Kass'Dalle ✨ », créé s'il n'existe pas encore pour ce compte.
  ///
  /// En brouillon : une recette rédigée par l'IA se relit avant de rejoindre
  /// la bibliothèque.
  Future<String> saveGeneratedRecipe(Recipe recipe) async {
    final uid = ref.read(appUserProvider).value?.uid;
    if (uid == null) throw StateError('Utilisateur non connecté.');

    final book = await BookRepository().findOrCreateKassDalleBook(uid);

    final now = DateTime.now();
    final toSave = Recipe(
      id: '',
      titre: recipe.titre,
      langue: recipe.langue,
      rawCooklang: recipe.rawCooklang,
      draftCooklang: recipe.rawCooklang,
      imageUrls: recipe.imageUrls,
      reviewStatus: ReviewStatus.draft,
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      portions: recipe.portions,
      ingredients: recipe.ingredients,
      origin: RecipeOrigin.ai,
      bookId: book.id,
      bookTitre: book.titre,
    );
    return ref.read(recipeRepositoryProvider).createRecipe(toSave);
  }

  Future<List<GeneratedRecipeSuggestion>> _generateAlternatives({
    required String query,
    required List<Map<String, String>> context,
    required String? preferenceInsight,
  }) async {
    final initial = await Future.wait([
      for (final variant in _generationVariants)
        _generateSingle(
          query: query,
          context: context,
          preferenceInsight: preferenceInsight,
          variant: variant,
        ),
    ]);
    final unique = <GeneratedRecipeSuggestion>[];

    for (final entry in initial.indexed) {
      final suggestion = entry.$2;
      if (!_containsDuplicate(unique, suggestion)) {
        unique.add(suggestion);
        continue;
      }
      final rerolled = await _generateSingle(
        query: query,
        context: context,
        preferenceInsight: preferenceInsight,
        variant: _generationVariants[entry.$1],
        avoidTitles: unique.map((item) => item.recipe.titre).toList(),
      );
      if (!_containsDuplicate(unique, rerolled)) unique.add(rerolled);
    }
    return unique;
  }

  Future<GeneratedRecipeSuggestion> _generateSingle({
    required String query,
    required List<Map<String, String>> context,
    required String? preferenceInsight,
    required _GenerationVariant variant,
    List<String> avoidTitles = const [],
  }) async {
    final raw = await ref
        .read(geminiServiceProvider)
        .generateRecipe(
          query: query,
          preferenceInsight: preferenceInsight,
          libraryContext: context,
          variantLabel: variant.label,
          variantInstruction: variant.instruction,
          siblingVariantLabels: _generationVariants
              .map((item) => item.label)
              .toList(growable: false),
          avoidTitles: avoidTitles,
        );
    return GeneratedRecipeSuggestion(
      recipe: recipeFromGeneratedRaw(raw, fallbackTitle: query),
      justification: raw['justification'] as String? ?? variant.instruction,
      variantLabel: raw['variant_label'] as String? ?? variant.label,
    );
  }

  bool _containsDuplicate(
    List<GeneratedRecipeSuggestion> existing,
    GeneratedRecipeSuggestion candidate,
  ) => existing.any(
    (current) => isDuplicateGeneratedRecipe(current.recipe, candidate.recipe),
  );
}

final aiIdeasProvider =
    NotifierProvider.autoDispose<AiIdeasNotifier, AiIdeasState>(
      AiIdeasNotifier.new,
    );

/// Recette en mémoire à partir de la réponse de `generateRecipeFn`.
Recipe recipeFromGeneratedRaw(
  Map<String, dynamic> raw, {
  required String fallbackTitle,
}) {
  final ingredients = (raw['ingredients'] as List? ?? const [])
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
  final now = DateTime.now();
  return Recipe(
    id: '',
    titre: raw['titre'] as String? ?? fallbackTitle,
    langue: raw['langue'] as String? ?? 'fr',
    rawCooklang: raw['cooklang'] as String? ?? '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.draft,
    tags: RecipeTags(
      themes: List<String>.from(tagsRaw['themes'] as List? ?? []),
      cuisines: List<String>.from(tagsRaw['cuisines'] as List? ?? []),
      occasions: List<String>.from(tagsRaw['occasions'] as List? ?? []),
      dishTypes: List<String>.from(tagsRaw['dish_types'] as List? ?? []),
      difficulty: tagsRaw['difficulty'] as String?,
      prepTime: (tagsRaw['prep_time'] as num?)?.toInt(),
      cookTime: (tagsRaw['cook_time'] as num?)?.toInt(),
    ),
    ingredientsIndex: List<String>.from(
      raw['ingredients_index'] as List? ?? [],
    ),
    createdBy: '',
    createdAt: now,
    updatedAt: now,
    portions: (raw['portions'] as num?)?.toInt(),
    ingredients: ingredients,
  );
}

/// Deux idées trop proches : même titre, ou 80 % d'ingrédients en commun.
bool isDuplicateGeneratedRecipe(Recipe left, Recipe right) {
  final leftTitle = foldSearchText(left.titre);
  if (leftTitle.isNotEmpty && leftTitle == foldSearchText(right.titre)) {
    return true;
  }
  Set<String> names(Recipe r) => r.ingredients
      .map((item) => foldSearchText(item.name))
      .where((item) => item.isNotEmpty)
      .toSet();
  final leftIngredients = names(left);
  final rightIngredients = names(right);
  if (leftIngredients.isEmpty || rightIngredients.isEmpty) return false;
  final intersection = leftIngredients.intersection(rightIngredients).length;
  final smallest = leftIngredients.length < rightIngredients.length
      ? leftIngredients.length
      : rightIngredients.length;
  return intersection / smallest >= 0.8;
}

String? _nonEmpty(Object? raw) {
  if (raw is! String) return null;
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : trimmed;
}

// ── Ctrl/Cmd+K ───────────────────────────────────────────────────────────────

/// Demande de focus du champ de l'Explorer, posée par le shell sur Ctrl/Cmd+K.
///
/// Un drapeau plutôt qu'un appel direct : l'écran peut ne pas encore exister
/// quand le raccourci part (navigation vers `/search`). Il consomme la
/// demande à son ouverture, ou dès qu'elle arrive s'il est déjà affiché.
class ExploreSearchFocusRequest extends Notifier<bool> {
  @override
  bool build() => false;

  void request() => state = true;

  void consume() => state = false;
}

final exploreSearchFocusRequestProvider =
    NotifierProvider<ExploreSearchFocusRequest, bool>(
      ExploreSearchFocusRequest.new,
    );
