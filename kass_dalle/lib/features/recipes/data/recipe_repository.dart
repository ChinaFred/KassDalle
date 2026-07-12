import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../domain/recipe.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';

class RecipeRepository {
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  RecipeRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('recipes');

  Future<
    ({
      String cooklang,
      List<RecipeIngredient> ingredients,
      int renamedUnits,
      int renamedIngredients,
    })
  >
  _normalizeReferentials({
    required String cooklang,
    required List<RecipeIngredient> ingredients,
    String? recipeId,
  }) async {
    try {
      final raw = await _functions
          .httpsCallable('normalizeRecipeReferentialsFn')
          .call<Map<String, dynamic>>({
            'recipeId': recipeId,
            'cooklang': cooklang,
            'ingredients': ingredients.map((i) => i.toMap()).toList(),
          });
      final data = Map<String, dynamic>.from(raw.data);
      final rewrittenCooklang =
          data['rewrittenCooklang'] as String? ?? cooklang;
      final resolvedRaw = data['resolvedIngredients'] as List? ?? const [];
      final stats = Map<String, dynamic>.from(
        data['stats'] as Map? ?? const {},
      );
      final resolvedIngredients = resolvedRaw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .map(RecipeIngredient.fromMap)
          .where((i) => i.name.trim().isNotEmpty)
          .toList(growable: false);

      return (
        cooklang: rewrittenCooklang,
        ingredients: resolvedIngredients.isEmpty
            ? ingredients
            : resolvedIngredients,
        renamedUnits: (stats['renamedUnits'] as num?)?.toInt() ?? 0,
        renamedIngredients: (stats['renamedIngredients'] as num?)?.toInt() ?? 0,
      );
    } catch (e, st) {
      // Fallback robuste: ne bloque jamais la sauvegarde si le callable échoue.
      // Erreur rapportée via ErrorReportService pour visibilité production.
      debugPrint('[RecipeRepository] _normalizeReferentials échec: $e');
      _errorReportService.reportError(
        feature: 'normalize_recipe_referentials',
        error: e,
        stackTrace: st,
        context: {'recipeId': recipeId ?? 'unknown'},
      ).ignore();
      return (
        cooklang: cooklang,
        ingredients: ingredients,
        renamedUnits: 0,
        renamedIngredients: 0,
      );
    }
  }

  // ── Lecture ─────────────────────────────────────────────────────────────────

  Future<Recipe?> getById(String id) async {
    final doc = await _col.doc(id).get();
    if (!doc.exists) return null;
    return Recipe.fromFirestore(doc.id, doc.data()!);
  }

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

  /// Toutes les pages validées d'un livre (recettes + pages non-recettes),
  /// triées par numéro de page (null en dernier), puis par titre.
  Stream<List<Recipe>> watchAllPagesByBook(String bookId) {
    return _col
        .where('book_id', isEqualTo: bookId)
        .where('review_status', isEqualTo: ReviewStatus.validated.name)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Recipe.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) {
            final pa = a.pageNumber;
            final pb = b.pageNumber;
            if (pa == null && pb == null) return a.titre.compareTo(b.titre);
            if (pa == null) return 1;
            if (pb == null) return -1;
            return pa.compareTo(pb);
          });
          return list;
        });
  }

  /// Toutes les pages validées d'un livre en lecture ponctuelle.
  ///
  /// Utilisé notamment pour les exports PDF complets.
  Future<List<Recipe>> getAllValidatedPagesByBook(String bookId) async {
    final snap = await _col
        .where('book_id', isEqualTo: bookId)
        .where('review_status', isEqualTo: ReviewStatus.validated.name)
        .get();

    final list = snap.docs
        .map((d) => Recipe.fromFirestore(d.id, d.data()))
        .toList();
    list.sort((a, b) {
      final pa = a.pageNumber;
      final pb = b.pageNumber;
      if (pa == null && pb == null) return a.titre.compareTo(b.titre);
      if (pa == null) return 1;
      if (pb == null) return -1;
      return pa.compareTo(pb);
    });
    return list;
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

    // Quand includeDrafts est vrai, on veut tous les statuts → pas de filtre sur
    // review_status (évite le double whereIn non supporté par Firestore sans index).
    // Quand false, on filtre uniquement les recettes validées avec isEqualTo.
    Query<Map<String, dynamic>> query = _col.where(
      'created_by',
      whereIn: limited,
    );

    if (!includeDrafts) {
      query = query.where(
        'review_status',
        isEqualTo: ReviewStatus.validated.name,
      );
    }

    final snap = await query.get();
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

  Future<String> createRecipe(
    Recipe recipe, {
    void Function({
      required String normalizedCooklang,
      required List<RecipeIngredient> normalizedIngredients,
      required int renamedUnits,
      required int renamedIngredients,
    })?
    onNormalizationApplied,
  }) async {
    final normalized = await _normalizeReferentials(
      cooklang: recipe.rawCooklang,
      ingredients: recipe.ingredients,
    );
    final toSave = recipe.copyWith(
      rawCooklang: normalized.cooklang,
      ingredients: normalized.ingredients,
      ingredientsIndex: normalized.ingredients
          .map((i) => i.name.trim().toLowerCase())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList(growable: false),
    );
    onNormalizationApplied?.call(
      normalizedCooklang: normalized.cooklang,
      normalizedIngredients: normalized.ingredients,
      renamedUnits: normalized.renamedUnits,
      renamedIngredients: normalized.renamedIngredients,
    );
    final ref = await _col.add(toSave.toFirestore());
    return ref.id;
  }

  /// Crée une copie de [recipe] comme brouillon pour [newOwnerUid].
  /// Le brouillon copié est indépendant de l'original (pas de lien).
  /// Retourne l'id du nouveau brouillon.
  Future<String> copyRecipeAsDraft({
    required Recipe recipe,
    required String newOwnerUid,
    bool forceDraft = false,
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
      reviewStatus: forceDraft
          ? ReviewStatus.draft
          : (isValidated ? ReviewStatus.validated : ReviewStatus.draft),
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      ingredients: recipe.ingredients,
      portions: recipe.portions,
      createdBy: newOwnerUid,
      createdAt: now,
      updatedAt: now,
      sourceRecipeId: recipe.id,
    );
    return createRecipe(copy);
  }

  // ── Mise à jour ──────────────────────────────────────────────────────────────

  Future<void> updateRecipe(
    Recipe recipe, {
    void Function({
      required String normalizedCooklang,
      required List<RecipeIngredient> normalizedIngredients,
      required int renamedUnits,
      required int renamedIngredients,
    })?
    onNormalizationApplied,
  }) async {
    final normalized = await _normalizeReferentials(
      recipeId: recipe.id,
      cooklang: recipe.rawCooklang,
      ingredients: recipe.ingredients,
    );
    final toSave = recipe.copyWith(
      rawCooklang: normalized.cooklang,
      ingredients: normalized.ingredients,
      ingredientsIndex: normalized.ingredients
          .map((i) => i.name.trim().toLowerCase())
          .where((n) => n.isNotEmpty)
          .toSet()
          .toList(growable: false),
    );
    onNormalizationApplied?.call(
      normalizedCooklang: normalized.cooklang,
      normalizedIngredients: normalized.ingredients,
      renamedUnits: normalized.renamedUnits,
      renamedIngredients: normalized.renamedIngredients,
    );
    await _col.doc(recipe.id).update(toSave.toFirestore());
  }

  // ── Portions persistées (par utilisateur et recette) ─────────────────────

  CollectionReference<Map<String, dynamic>> _portionOverrideCol(String uid) {
    return _firestore
        .collection('users')
        .doc(uid)
        .collection('nutrition_portion_overrides');
  }

  Stream<int?> watchPortionsOverride(String uid, String recipeId) {
    return _portionOverrideCol(uid).doc(recipeId).snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return null;
      final value = data['selected_portions'];
      return value is int ? value : null;
    });
  }

  Future<int?> getPortionsOverride(String uid, String recipeId) async {
    final snap = await _portionOverrideCol(uid).doc(recipeId).get();
    final data = snap.data();
    if (data == null) return null;
    final value = data['selected_portions'];
    return value is int ? value : null;
  }

  Future<void> savePortionsOverride({
    required String uid,
    required String recipeId,
    required int selectedPortions,
  }) async {
    await _portionOverrideCol(uid).doc(recipeId).set({
      'selected_portions': selectedPortions,
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> recomputeNutrition({
    required String recipeId,
    required int selectedPortions,
  }) async {
    await _functions.httpsCallable('computeRecipeNutritionFn').call<dynamic>({
      'recipeId': recipeId,
      'selectedPortions': selectedPortions,
    });
  }

  /// Valide un brouillon : rawCooklang ← draftCooklang édité, statut = validated.
  /// Les droits sont appliqués côté Firestore (owner ou editor/admin).
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
    void Function({
      required String normalizedCooklang,
      required List<RecipeIngredient> normalizedIngredients,
      required int renamedUnits,
      required int renamedIngredients,
    })?
    onNormalizationApplied,
  }) async {
    if (callerUid.isEmpty) {
      throw StateError('Utilisateur non authentifié.');
    }
    final ingredientsStructuredRaw =
        ingredientsOverride ?? extractIngredientsStructured(editedCooklang);
    final normalized = await _normalizeReferentials(
      recipeId: recipeId,
      cooklang: editedCooklang,
      ingredients: ingredientsStructuredRaw,
    );
    onNormalizationApplied?.call(
      normalizedCooklang: normalized.cooklang,
      normalizedIngredients: normalized.ingredients,
      renamedUnits: normalized.renamedUnits,
      renamedIngredients: normalized.renamedIngredients,
    );
    final ingredients = extractIngredients(normalized.cooklang);
    final ingredientsStructured = normalized.ingredients;
    final portions = portionsOverride ?? extractPortions(editedCooklang);
    final tags = tagsOverride ?? extractRecipeTags(editedCooklang);
    await _col.doc(recipeId).update({
      'titre': titre,
      'raw_cooklang': normalized.cooklang,
      'draft_cooklang': normalized.cooklang,
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

  /// Met à jour les illustrations d'un brouillon (ajout des photos extraites du scan).
  /// Si [thumbnailUrls] est fourni, met également à jour les vignettes (même ordre que [imageUrls]).
  Future<void> updateRecipeIllustrations(
    String recipeId,
    List<String> imageUrls, {
    List<String>? thumbnailUrls,
  }) async {
    final data = <String, dynamic>{
      'image_urls': imageUrls,
      'updated_at': DateTime.now(),
    };
    if (thumbnailUrls != null) {
      data['thumbnail_urls'] = thumbnailUrls;
    }
    await _col.doc(recipeId).update(data);
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

  /// Met à jour le type de page d'un brouillon.
  Future<void> updatePageType(String recipeId, PageType pageType) async {
    final stored = switch (pageType) {
      PageType.ingredientNote => 'ingredient_note',
      _ => pageType.name,
    };
    await _col.doc(recipeId).update({
      'page_type': stored,
      'updated_at': DateTime.now(),
    });
  }

  /// Envoie une image d'illustration sur Storage et retourne son URL.
  /// Chemin : `illustrations/$uid/<timestamp>_$fileName`
  Future<String> uploadIllustration(
    String uid,
    Uint8List bytes,
    String fileName,
  ) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = fileName.contains('.') ? fileName.split('.').last : 'jpg';
    final storageRef = FirebaseStorage.instance.ref(
      'illustrations/$uid/${ts}_editor.$ext',
    );
    final task = await storageRef.putData(
      bytes,
      SettableMetadata(contentType: 'image/$ext'),
    );
    return task.ref.getDownloadURL();
  }

  /// Envoie une photo d'illustration sur Storage et retourne son URL.
  /// Chemin : `recipes/$recipeId/illus_<timestamp>.jpg`
  Future<String> uploadRecipePhoto(String recipeId, Uint8List bytes) async {
    final path =
        'recipes/$recipeId/illus_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final storageRef = FirebaseStorage.instance.ref(path);
    final snapshot = await storageRef.putData(
      bytes,
      SettableMetadata(contentType: 'image/jpeg'),
    );
    return snapshot.ref.getDownloadURL();
  }

  /// Envoie un fichier source (scan texte) sur Storage et retourne son URL.
  /// Chemin : `scans/$uid/$filename`
  Future<String> uploadScanFile(
    String uid,
    List<int> data,
    String filename,
    String contentType,
  ) async {
    final safeFilename = filename
        .replaceAll(RegExp(r'[^a-zA-Z0-9._\-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final storageRef = FirebaseStorage.instance.ref(
      'quarantine/$uid/$safeFilename',
    );
    final snap = await storageRef.putData(
      Uint8List.fromList(data),
      SettableMetadata(contentType: contentType),
    );
    final promoted = await GeminiService().scanAndPromoteUpload(
      storagePath: snap.ref.fullPath,
    );
    return promoted.downloadUrl;
  }

  /// Efface le fichier source du brouillon (url, nom, pages supplémentaires).
  Future<void> clearSourceFile(String recipeId) async {
    await _col.doc(recipeId).update({
      'source_file_url': null,
      'source_file_name': null,
      'additional_source_file_urls': [],
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
