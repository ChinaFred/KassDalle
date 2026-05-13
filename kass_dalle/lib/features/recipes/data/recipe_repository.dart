import 'package:cloud_firestore/cloud_firestore.dart';
import '../domain/recipe.dart';
import '../../../core/services/gemini_service.dart';

class RecipeRepository {
  final FirebaseFirestore _firestore;

  RecipeRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('recipes');

  // ── Lecture ─────────────────────────────────────────────────────────────────

  Stream<List<Recipe>> watchDrafts(String uid) {
    return _col
        .where('created_by', isEqualTo: uid)
        .where(
          'review_status',
          whereIn: [ReviewStatus.draft.name, ReviewStatus.inReview.name],
        )
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Recipe.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return list;
        });
  }

  Stream<List<Recipe>> watchByBook(String bookId) {
    return _col
        .where('book_id', isEqualTo: bookId)
        .where('review_status', isEqualTo: ReviewStatus.validated.name)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Recipe.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return list;
        });
  }

  /// Brouillons rattachés à un livre donné.
  Stream<List<Recipe>> watchDraftsByBook(String bookId) {
    return _col
        .where('book_id', isEqualTo: bookId)
        .where(
          'review_status',
          whereIn: [ReviewStatus.draft.name, ReviewStatus.inReview.name],
        )
        .snapshots()
        .map(
          (s) =>
              s.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList(),
        );
  }

  /// Brouillons sans livre (recettes libres) de l'utilisateur.
  Stream<List<Recipe>> watchDraftsUnattached(String uid) {
    return _col
        .where('created_by', isEqualTo: uid)
        .where(
          'review_status',
          whereIn: [ReviewStatus.draft.name, ReviewStatus.inReview.name],
        )
        .where('book_id', isNull: true)
        .snapshots()
        .map(
          (s) =>
              s.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList(),
        );
  }

  /// Recettes validées sans livre (recettes libres) de l'utilisateur.
  Stream<List<Recipe>> watchUnattached(String uid) {
    return _col
        .where('created_by', isEqualTo: uid)
        .where('review_status', isEqualTo: ReviewStatus.validated.name)
        .where('book_id', isNull: true)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Recipe.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return list;
        });
  }

  /// Recettes libres validées de plusieurs utilisateurs (membres d'un groupe).
  /// Filtrage client-side pour éviter les index composites.
  Stream<List<Recipe>> watchUnattachedByOwners(List<String> ownerIds) {
    if (ownerIds.isEmpty) return Stream.value([]);
    final limited = ownerIds.take(30).toList();
    return _col.where('created_by', whereIn: limited).snapshots().map((s) {
      final list = s.docs
          .map((d) => Recipe.fromFirestore(d.id, d.data()))
          .where(
            (r) =>
                r.reviewStatus == ReviewStatus.validated &&
                (r.bookId == null || r.bookId!.isEmpty),
          )
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    });
  }

  /// Brouillons (draft + inReview) de plusieurs utilisateurs (membres d'un groupe).
  /// Filtrage client-side pour éviter les index composites.
  Stream<List<Recipe>> watchDraftsByOwners(List<String> ownerIds) {
    if (ownerIds.isEmpty) return Stream.value([]);
    final limited = ownerIds.take(30).toList();
    return _col.where('created_by', whereIn: limited).snapshots().map((s) {
      final list = s.docs
          .map((d) => Recipe.fromFirestore(d.id, d.data()))
          .where(
            (r) =>
                r.reviewStatus == ReviewStatus.draft ||
                r.reviewStatus == ReviewStatus.inReview,
          )
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    });
  }

  Future<Recipe?> getRecipe(String recipeId) async {
    final doc = await _col.doc(recipeId).get();
    if (!doc.exists) return null;
    return Recipe.fromFirestore(doc.id, doc.data()!);
  }

  /// Écoute en temps réel le document d'une recette.
  Stream<Recipe?> watchRecipe(String recipeId) {
    return _col
        .doc(recipeId)
        .snapshots()
        .map(
          (doc) =>
              doc.exists ? Recipe.fromFirestore(doc.id, doc.data()!) : null,
        );
  }

  /// Charge toutes les recettes pour une liste d'utilisateurs.
  ///
  /// [ownerIds] : liste des UIDs propriétaires (max 30).
  /// [includeDrafts] : si true, inclut aussi les brouillons (draft + inReview).
  /// Si false, ne charge que les recettes validées.
  ///
  /// Utilisé par la recherche IA pour constituer le corpus à analyser.
  Future<List<Recipe>> getAllByOwners(
    List<String> ownerIds, {
    bool includeDrafts = false,
  }) async {
    if (ownerIds.isEmpty) return [];
    final limited = ownerIds.take(30).toList();

    final statuses = [
      ReviewStatus.validated.name,
      if (includeDrafts) ...[
        ReviewStatus.draft.name,
        ReviewStatus.inReview.name,
      ],
    ];

    final snap = await _col
        .where('created_by', whereIn: limited)
        .where('review_status', whereIn: statuses)
        .get();

    return snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList();
  }

  /// Tous les brouillons (draft + inReview) — admin uniquement.
  Stream<List<Recipe>> watchAllDrafts() {
    return _col
        .where(
          'review_status',
          whereIn: [ReviewStatus.draft.name, ReviewStatus.inReview.name],
        )
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Recipe.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return list;
        });
  }

  // ── Création ─────────────────────────────────────────────────────────────────

  Future<String> createRecipe(Recipe recipe) async {
    final ref = await _col.add(recipe.toFirestore());
    return ref.id;
  }

  /// Crée une copie de [recipe] comme brouillon pour [newOwnerUid].
  /// Le brouillon copié est indépendant de l'original (pas de lien).
  /// Retourne l'id du nouveau brouillon.
  Future<String> copyRecipeAsDraft({
    required Recipe recipe,
    required String newOwnerUid,
  }) async {
    final now = DateTime.now();
    // Pour une recette validée, on utilise rawCooklang (contenu final).
    // Pour un brouillon, on préfère draftCooklang (version éditée).
    final isValidated = recipe.reviewStatus == ReviewStatus.validated;
    final content = isValidated
        ? recipe.rawCooklang
        : (recipe.draftCooklang ?? recipe.rawCooklang);
    final copy = Recipe(
      id: '',
      titre: recipe.titre,
      bookId: null,
      bookTitre: null,
      pageNumber: null,
      langue: recipe.langue,
      rawCooklang: content,
      draftCooklang: content,
      imageUrls: const [],
      reviewStatus: isValidated ? ReviewStatus.validated : ReviewStatus.draft,
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      ingredients: recipe.ingredients,
      portions: recipe.portions,
      createdBy: newOwnerUid,
      createdAt: now,
      updatedAt: now,
    );
    return createRecipe(copy);
  }

  // ── Mise à jour ──────────────────────────────────────────────────────────────

  Future<void> updateRecipe(Recipe recipe) async {
    await _col.doc(recipe.id).update(recipe.toFirestore());
  }

  /// Valide un brouillon : rawCooklang ← draftCooklang édité, statut = validated.
  /// Lève [StateError] si [callerUid] n'est pas le propriétaire de la recette.
  Future<void> validateDraft({
    required String recipeId,
    required String editedCooklang,
    required String titre,
    required String callerUid,
    String? bookId,
    String? bookTitre,
    int? pageNumberOverride,
    RecipeTags? tagsOverride,
    int? portionsOverride,
    List<RecipeIngredient>? ingredientsOverride,
  }) async {
    // Vérification d'appartenance avant écriture.
    final doc = await _col.doc(recipeId).get();
    if (!doc.exists) throw StateError('Recette introuvable.');
    final owner = doc.data()?['created_by'] as String?;
    if (owner != callerUid) {
      throw StateError(
        'Vous ne pouvez pas valider le brouillon d\'un autre utilisateur.',
      );
    }
    final ingredients = extractIngredients(editedCooklang);
    final ingredientsStructured =
        ingredientsOverride ?? extractIngredientsStructured(editedCooklang);
    final portions = portionsOverride ?? extractPortions(editedCooklang);
    final tags = tagsOverride ?? extractRecipeTags(editedCooklang);
    await _col.doc(recipeId).update({
      'titre': titre,
      'raw_cooklang': editedCooklang,
      'draft_cooklang': editedCooklang,
      'review_status': ReviewStatus.validated.name,
      'tags': tags.toMap(),
      'ingredients_index': ingredients,
      'ingredients': ingredientsStructured.map((i) => i.toMap()).toList(),
      'portions': portions,
      'book_id': bookId,
      'book_titre': bookTitre,
      'page_number': ?pageNumberOverride,
      'updated_at': DateTime.now(),
    });
  }

  Future<void> deleteRecipe(String recipeId) async {
    await _col.doc(recipeId).delete();
  }

  /// Récupère toutes les recettes validées (pour migration admin).
  Future<List<Recipe>> fetchAllValidated() async {
    final snap = await _col
        .where('review_status', isEqualTo: ReviewStatus.validated.name)
        .get();
    return snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList();
  }

  /// Met à jour le contenu CookLang brut d'une recette.
  Future<void> updateRawCooklang(String recipeId, String cooklang) async {
    await _col.doc(recipeId).update({
      'raw_cooklang': cooklang,
      'updated_at': DateTime.now(),
    });
  }

  /// Met à jour les illustrations d'un brouillon (ajout des photos extraites du scan).
  Future<void> updateRecipeIllustrations(
    String recipeId,
    List<String> imageUrls,
  ) async {
    await _col.doc(recipeId).update({
      'image_urls': imageUrls,
      'updated_at': DateTime.now(),
    });
  }

  /// Met à jour en lot les dish_types de plusieurs recettes.
  Future<void> batchUpdateDishTypes(Map<String, List<String>> updates) async {
    const batchMax = 500;
    final entries = updates.entries.toList();
    for (var i = 0; i < entries.length; i += batchMax) {
      final chunk = entries.sublist(i, (i + batchMax).clamp(0, entries.length));
      final batch = _firestore.batch();
      final now = DateTime.now();
      for (final e in chunk) {
        batch.update(_col.doc(e.key), {
          'tags.dish_types': e.value,
          'updated_at': now,
        });
      }
      await batch.commit();
    }
  }

  /// Ajoute une URL d'illustration à la recette.
  Future<void> addImageUrl(String recipeId, String url) async {
    await _col.doc(recipeId).update({
      'image_urls': FieldValue.arrayUnion([url]),
      'updated_at': DateTime.now(),
    });
  }

  /// Retire une URL d'illustration de la recette.
  Future<void> removeImageUrl(String recipeId, String url) async {
    await _col.doc(recipeId).update({
      'image_urls': FieldValue.arrayRemove([url]),
      'updated_at': DateTime.now(),
    });
  }

  /// Attache des recettes validées existantes à un livre.
  Future<void> attachValidatedRecipesToBook({
    required List<String> recipeIds,
    required String bookId,
    required String bookTitre,
  }) async {
    if (recipeIds.isEmpty) return;

    final batch = _firestore.batch();
    final now = DateTime.now();
    for (final recipeId in recipeIds) {
      batch.update(_col.doc(recipeId), {
        'book_id': bookId,
        'book_titre': bookTitre,
        'updated_at': now,
      });
    }
    await batch.commit();
  }

  /// Détache une recette d'un livre.
  Future<void> detachRecipeFromBook(String recipeId) async {
    await _col.doc(recipeId).update({
      'book_id': null,
      'book_titre': null,
      'updated_at': DateTime.now(),
    });
  }

  /// Détache toutes les recettes (validées et brouillons) d'un livre.
  Future<void> detachAllRecipesFromBook(String bookId) async {
    final snapshot = await _col.where('book_id', isEqualTo: bookId).get();
    if (snapshot.docs.isEmpty) return;

    final batch = _firestore.batch();
    final now = DateTime.now();
    for (final doc in snapshot.docs) {
      batch.update(doc.reference, {
        'book_id': null,
        'book_titre': null,
        'updated_at': now,
      });
    }
    await batch.commit();
  }

  /// Supprime toutes les recettes (validées et brouillons) d'un livre.
  Future<void> deleteAllRecipesOfBook(String bookId) async {
    final snapshot = await _col.where('book_id', isEqualTo: bookId).get();
    if (snapshot.docs.isEmpty) return;

    final batch = _firestore.batch();
    for (final doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }
}
