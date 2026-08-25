import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../domain/recipe.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../../core/services/error_report_service.dart';
import '../../books/data/book_repository.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../../../core/services/gemini_service.dart';

class RecipeRepository {
  final FirebaseFirestore _firestore;
  final FirebaseFunctions? _injectedFunctions;
  final ErrorReportService _errorReportService;

  /// Résolu à la première utilisation, pas à la construction.
  ///
  /// `FirebaseFunctions.instanceFor` exige une App Firebase initialisée. Le
  /// faire dans le constructeur imposait cette exigence à tout usage du
  /// repository, y compris aux lectures qui n'appellent aucune Function — et
  /// rendait le repository impossible à instancier hors application.
  FirebaseFunctions get _functions =>
      _injectedFunctions ??
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Résolu paresseusement, pour la même raison que les Functions : instancier
  /// le service exige une App Firebase, et un test qui ne publie aucune image
  /// n'a pas à la fournir.
  final ImageModerationService? _injectedModeration;
  ImageModerationService get _moderation =>
      _injectedModeration ?? ImageModerationService();

  RecipeRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
    ImageModerationService? moderation,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _injectedFunctions = functions,
       _injectedModeration = moderation,
       // Le rapport d'erreur suit le Firestore du repository : en test, il
       // écrit dans le Firestore de test au lieu d'exiger l'App réelle.
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

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
      // `rewrittenCooklang` est volontairement ignoré : le serveur le rend
      // toujours, mais le texte de la recette appartient au livre. La
      // normalisation renomme les ingrédients à sa guise et insère des
      // quantités estimées ; les appliquer au texte réécrivait les phrases de
      // l'auteur. On ne garde que la liste résolue.
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
        cooklang: cooklang,
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
      _errorReportService
          .reportError(
            feature: 'normalize_recipe_referentials',
            error: e,
            stackTrace: st,
            context: {'recipeId': recipeId ?? 'unknown'},
          )
          .ignore();
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
    final withBook = await _withDefaultBook(recipe);
    final toSave = withBook.copyWith(
      rawCooklang: normalized.cooklang,
      ingredients: normalized.ingredients,
      ingredientsIndex: buildIngredientsIndex(normalized.ingredients),
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

  /// Toute recette a un livre.
  ///
  /// Une recette sans livre existait bel et bien : elle s'affichait sous
  /// « Mes recettes libres », une section qui rassemblait les orphelines sans
  /// qu'aucun livre ne les porte. Le livre système du même nom existe pourtant
  /// — il était affiché à côté, vide, ce qui donnait deux endroits pour la même
  /// idée et un compteur qui ne comptait rien.
  ///
  /// La règle est posée ici, à l'entonnoir : quel que soit l'écran d'où vient
  /// la recette, elle atterrit dans un livre. Un défaut appliqué à un seul
  /// écran n'est pas une règle, c'est une habitude.
  Future<Recipe> _withDefaultBook(Recipe recipe) async {
    if ((recipe.bookId ?? '').isNotEmpty) return recipe;
    try {
      final book = await BookRepository().findOrCreateLibresBook(
        recipe.createdBy,
        '',
      );
      return recipe.copyWith(bookId: book.id, bookTitre: book.titre);
    } catch (e, stackTrace) {
      // Le livre par défaut est introuvable : la recette est enregistrée sans
      // lui plutôt que perdue. Elle réapparaîtra dans les orphelines, ce qui
      // est un moindre mal — mais l'échec doit se voir.
      _errorReportService.reportError(
        feature: 'recipeRepository.withDefaultBook',
        error: e,
        stackTrace: stackTrace,
        context: {'titre': recipe.titre},
      );
      return recipe;
    }
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
      ingredientsIndex: buildIngredientsIndex(normalized.ingredients),
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

  /// Recalcule le bloc nutritionnel d'une recette.
  ///
  /// Ne prend pas de nombre de parts : le calcul se fait aux portions déclarées
  /// de la recette. Les valeurs par portion sont une division des totaux, faite
  /// à l'affichage pour le contexte qui la demande.
  Future<void> recomputeNutrition({required String recipeId}) async {
    await _functions.httpsCallable('computeRecipeNutritionFn').call<dynamic>({
      'recipeId': recipeId,
    });
  }

  /// Valide un brouillon : statut = validated. La recette est sauvegardée
  /// telle quelle (sans normalisation du contenu). Le calcul nutritionnel
  /// est déclenché automatiquement par le trigger Firestore onRecipeNutritionAutoSync.
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
    // Sauvegarde AS-IS : pas de normalisation, pas de réécriture.
    // L'utilisateur a validé la recette telle qu'il la voit.
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
      'ingredients_index': buildIngredientsIndex(ingredientsStructured),
      'ingredients': ingredientsStructured.map((i) => i.toMap()).toList(),
      'portions': portions,
      'book_id': bookId,
      'book_titre': bookTitre,
      'page_number': ?pageNumberOverride,
      // La réserve de fidélité est LEVÉE, pas seulement masquée.
      //
      // Elle a fait son office : elle a dit où regarder, quelqu'un a regardé et
      // a tranché — c'est le sens même de valider. La garder en base
      // reviendrait à conserver un doute que personne ne peut plus lever, et
      // à rouvrir le débat au premier écran qui déciderait de l'afficher.
      'fidelity_level': FieldValue.delete(),
      'fidelity_findings': FieldValue.delete(),
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

  /// Envoie une image d'illustration et retourne son URL publiée.
  ///
  /// Passe par la quarantaine et la modération : `illustrations/` est fermé en
  /// écriture côté règles Storage. Lève [ImageNotPublished] si l'image est
  /// retenue ou refusée.
  Future<String> uploadIllustration(
    String uid,
    Uint8List bytes,
    String fileName,
  ) async {
    final ext = fileName.contains('.') ? fileName.split('.').last : 'jpg';
    return _moderation.publish(
      PendingImage(
        bytes: bytes,
        filename: fileName,
        contentType: 'image/$ext',
        target: ModerationTarget.draftIllustration,
      ),
    );
  }

  /// Envoie une photo d'illustration de recette et retourne son URL publiée.
  Future<String> uploadRecipePhoto(String recipeId, Uint8List bytes) async {
    return _moderation.publish(
      PendingImage(
        bytes: bytes,
        filename: 'illus.jpg',
        contentType: 'image/jpeg',
        target: ModerationTarget.recipeIllustration,
        ownerId: recipeId,
      ),
    );
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
