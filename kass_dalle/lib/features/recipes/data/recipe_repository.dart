import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import '../domain/recipe.dart';
import '../domain/recipe_viewer.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../../core/services/error_report_service.dart';
import '../../books/data/book_repository.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../../../core/services/gemini_service.dart';

/// Confidentialité qu'une recette doit porter dans le livre [bookId] : celle
/// du livre, `false` pour un livre introuvable — la même réponse que
/// `expectedPrivacy` côté serveur. `null` sans livre : la recette garde alors
/// la confidentialité qu'elle porte (une page détachée d'un livre privé reste
/// privée), comme `privacyWithoutBook` côté serveur.
///
/// Les règles Firestore exigent la confidentialité du livre à toute écriture
/// qui pose ou change le livre d'une recette : une recette créée ou déplacée
/// dans un livre privé avec `is_private: false` restait lisible par la
/// famille jusqu'au passage du déclencheur `onRecipeWritten`.
Future<bool?> privacyOfBook(FirebaseFirestore firestore, String? bookId) async {
  if (bookId == null || bookId.isEmpty) return null;
  final snap = await firestore.collection('books').doc(bookId).get();
  return snap.data()?['is_private'] == true;
}

/// Le livre d'une recette change-t-il ? `null` et chaîne vide valent « sans
/// livre ».
bool bookChanges(String? before, String? after) =>
    (before ?? '') != (after ?? '');

/// [data] avec la confidentialité du livre, ou inchangée sans livre
/// ([bookPrivacy] nul) : une recette libre privée ne redevient pas publique à
/// l'enregistrement.
Map<String, dynamic> withBookPrivacy(
  Map<String, dynamic> data,
  bool? bookPrivacy,
) => bookPrivacy == null ? data : {...data, 'is_private': bookPrivacy};

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

  /// Confidentialité à écrire pour [recipeId] rangée dans [newBookId], ou
  /// `null` pour garder la valeur courante.
  ///
  /// Le livre n'est lu que si la recette en change. L'auteur d'une page
  /// rangée dans le livre privé d'un autre ne peut pas lire ce livre :
  /// relire le livre à chaque enregistrement l'empêchait d'enregistrer sa
  /// page. Les règles, elles, ne contrôlent la confidentialité qu'à un
  /// changement de livre ou de `is_private`.
  Future<bool?> _privacyIfBookChanges(
    String recipeId,
    String? newBookId,
  ) async {
    final current = await _col.doc(recipeId).get();
    final before = current.data()?['book_id'] as String?;
    if (!bookChanges(before, newBookId)) return null;
    return privacyOfBook(_firestore, newBookId);
  }

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

  // ── Requêtes prouvables par les règles ────────────────────────────────────
  //
  // Firestore refuse une requête entière si ses règles ne peuvent pas prouver,
  // sur les seuls filtres, que chaque résultat est lisible. Pour un autre
  // qu'un administrateur, une requête par livre ou par statut se scinde donc :
  // les siennes (`created_by == uid`), et les recettes partagées
  // (`is_private == false`) des comptes de ses groupes (`created_by in`, par
  // lots). Les règles ne laissent lire une recette partagée d'un autre que
  // s'il partage un groupe avec le lecteur (`group_reach`, v0.23.19). Un
  // lecteur ne relit pas les brouillons des autres : pour lui, une requête de
  // brouillons ne porte que sur les siens.

  /// Firestore borne une requête à 30 disjonctions : le produit des valeurs
  /// de ses filtres `in`. Une requête de [base] qui porte déjà un `in` à
  /// [baseDisjunctions] valeurs reçoit des lots de comptes d'autant plus
  /// petits.
  static List<List<String>> _peerChunks(
    List<String> peers, {
    int baseDisjunctions = 1,
  }) {
    final size = 30 ~/ baseDisjunctions;
    return [
      for (var i = 0; i < peers.length; i += size)
        peers.sublist(i, (i + size).clamp(0, peers.length)),
    ];
  }

  /// Les recettes partagées de [base] écrites par les comptes des groupes du
  /// lecteur, une requête par lot.
  static List<Query<Map<String, dynamic>>> _sharedByPeers(
    Query<Map<String, dynamic>> base,
    RecipeViewer viewer, {
    int baseDisjunctions = 1,
  }) => [
    for (final chunk in _peerChunks(
      viewer.groupPeers,
      baseDisjunctions: baseDisjunctions,
    ))
      base
          .where('is_private', isEqualTo: false)
          .where('created_by', whereIn: chunk),
  ];

  List<Query<Map<String, dynamic>>> _visibleQueries(
    Query<Map<String, dynamic>> base,
    RecipeViewer viewer, {
    bool drafts = false,
  }) {
    if (viewer.isAdmin) return [base];
    final mine = base.where('created_by', isEqualTo: viewer.uid);
    if (drafts && !viewer.canEdit) return [mine];
    // Une requête de brouillons porte déjà `review_status in [draft, inReview]`.
    return [
      mine,
      ..._sharedByPeers(base, viewer, baseDisjunctions: drafts ? 2 : 1),
    ];
  }

  List<Recipe> _toRecipes(QuerySnapshot<Map<String, dynamic>> snap) =>
      snap.docs.map((d) => Recipe.fromFirestore(d.id, d.data())).toList();

  /// Fusionne les flux de [queries], sans doublon (une recette partagée qui
  /// m'appartient sort des deux requêtes). Rien n'est émis tant que chaque
  /// requête n'a pas rendu son premier résultat : une liste partielle se
  /// lirait comme un livre incomplet.
  ///
  /// Une requête refusée remonte à l'écran par le flux, et au rapport
  /// d'erreurs : un refus ici signale une requête que les règles ne prouvent
  /// plus, et il ne doit pas se lire seulement comme un livre vide.
  Stream<List<Recipe>> _watchVisible(
    List<Query<Map<String, dynamic>>> queries, {
    required String action,
    required Map<String, Object?> context,
  }) {
    final latest = List<Map<String, Recipe>?>.filled(queries.length, null);
    final subs = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    late final StreamController<List<Recipe>> ctrl;
    ctrl = StreamController<List<Recipe>>(
      onListen: () {
        for (var i = 0; i < queries.length; i++) {
          subs.add(
            queries[i].snapshots().listen(
              (snap) {
                latest[i] = {for (final r in _toRecipes(snap)) r.id: r};
                if (latest.every((m) => m != null)) {
                  ctrl.add({for (final m in latest) ...m!}.values.toList());
                }
              },
              onError: (Object e, StackTrace st) {
                unawaited(
                  _errorReportService.reportError(
                    feature: 'recipe_visible_query',
                    error: e,
                    stackTrace: st,
                    context: {'action': action, 'query_index': i, ...context},
                  ),
                );
                ctrl.addError(e, st);
              },
            ),
          );
        }
      },
      onCancel: () async {
        for (final sub in subs) {
          await sub.cancel();
        }
      },
    );
    return ctrl.stream;
  }

  /// Lecture ponctuelle de [queries], fusionnée sans doublon.
  Future<List<Recipe>> _getVisible(
    List<Query<Map<String, dynamic>>> queries, {
    required String action,
    required Map<String, Object?> context,
  }) async {
    try {
      final snaps = await Future.wait(queries.map((q) => q.get()));
      return {
        for (final snap in snaps)
          for (final r in _toRecipes(snap)) r.id: r,
      }.values.toList();
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'recipe_visible_query',
          error: e,
          stackTrace: st,
          context: {'action': action, ...context},
        ),
      );
      rethrow;
    }
  }

  /// Combien de recettes de ce livre le lecteur voit, tous statuts confondus.
  ///
  /// Sert à annoncer ce qu'un basculement de confidentialité va emporter. Une
  /// agrégation plutôt qu'un `get()` : on veut un nombre, pas les documents,
  /// et lire cent recettes pour en compter cent est facturé cent fois.
  ///
  /// Hors administrateur, des comptes disjoints : les miennes, puis les
  /// recettes partagées des comptes de mes groupes. Une recette d'un compte
  /// hors de mes groupes rangée dans mon livre n'est pas comptée — je ne peux
  /// pas la lire.
  Future<int> countInBook(String bookId, RecipeViewer viewer) async {
    final base = _col.where('book_id', isEqualTo: bookId);
    if (viewer.isAdmin) {
      final snap = await base.count().get();
      return snap.count ?? 0;
    }
    final counts = await Future.wait([
      base.where('created_by', isEqualTo: viewer.uid).count().get(),
      for (final q in _sharedByPeers(base, viewer)) q.count().get(),
    ]);
    return counts.fold<int>(0, (total, c) => total + (c.count ?? 0));
  }

  /// Combien de pages de ce livre, ajoutées par d'autres membres, le lecteur
  /// ne pourra ni supprimer ni détacher — annoncé avant de supprimer le livre.
  ///
  /// Zéro pour un administrateur, qui agit sur toutes. Sinon, les pages
  /// partagées des comptes de mes groupes ; les pages privées d'un autre, ou
  /// d'un compte hors de mes groupes, ne sont pas lisibles, donc pas comptées.
  Future<int> countOthersInBook(String bookId, RecipeViewer viewer) async {
    if (viewer.isAdmin) return 0;
    final base = _col.where('book_id', isEqualTo: bookId);
    final counts = await Future.wait([
      for (final q in _sharedByPeers(base, viewer)) q.count().get(),
    ]);
    return counts.fold<int>(0, (total, c) => total + (c.count ?? 0));
  }

  Query<Map<String, dynamic>> _validatedOfBook(String bookId) => _col
      .where('book_id', isEqualTo: bookId)
      .where('review_status', isEqualTo: ReviewStatus.validated.name);

  static int _byPage(Recipe a, Recipe b) {
    final pa = a.pageNumber;
    final pb = b.pageNumber;
    if (pa == null && pb == null) return a.titre.compareTo(b.titre);
    if (pa == null) return 1;
    if (pb == null) return -1;
    return pa.compareTo(pb);
  }

  Stream<List<Recipe>> watchByBook(String bookId, RecipeViewer viewer) {
    return _watchVisible(
      _visibleQueries(_validatedOfBook(bookId), viewer),
      action: 'watch_by_book',
      context: {'book_id': bookId},
    ).map((list) {
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    });
  }

  /// Toutes les pages validées d'un livre (recettes + pages non-recettes),
  /// triées par numéro de page (null en dernier), puis par titre.
  Stream<List<Recipe>> watchAllPagesByBook(String bookId, RecipeViewer viewer) {
    return _watchVisible(
      _visibleQueries(_validatedOfBook(bookId), viewer),
      action: 'watch_all_pages_by_book',
      context: {'book_id': bookId},
    ).map((list) => list..sort(_byPage));
  }

  /// Toutes les pages validées d'un livre en lecture ponctuelle.
  ///
  /// Utilisé notamment pour les exports PDF complets.
  Future<List<Recipe>> getAllValidatedPagesByBook(
    String bookId,
    RecipeViewer viewer,
  ) async {
    final list = await _getVisible(
      _visibleQueries(_validatedOfBook(bookId), viewer),
      action: 'get_all_validated_pages_by_book',
      context: {'book_id': bookId},
    );
    return list..sort(_byPage);
  }

  /// Brouillons rattachés à un livre donné : ceux que le lecteur peut relire.
  Stream<List<Recipe>> watchDraftsByBook(String bookId, RecipeViewer viewer) {
    final base = _col
        .where('book_id', isEqualTo: bookId)
        .where(
          'review_status',
          whereIn: [ReviewStatus.draft.name, ReviewStatus.inReview.name],
        );
    return _watchVisible(
      _visibleQueries(base, viewer, drafts: true),
      action: 'watch_drafts_by_book',
      context: {'book_id': bookId},
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
  ///
  /// Confidentialité et statut partent dans la requête : la règle Firestore
  /// ne laisse lire à un lecteur que les recettes partagées ET validées des
  /// autres, et refuserait la requête entière sans ces deux filtres. Des
  /// filtres d'égalité seuls ne demandent pas d'index composite. Le livre
  /// absent se filtre côté client : « champ absent » ne s'exprime pas en
  /// requête.
  Stream<List<Recipe>> watchUnattachedByOwners(List<String> ownerIds) {
    if (ownerIds.isEmpty) return Stream.value([]);
    final limited = ownerIds.take(30).toList();
    return _col
        .where('created_by', whereIn: limited)
        .where('is_private', isEqualTo: false)
        .where('review_status', isEqualTo: ReviewStatus.validated.name)
        .snapshots()
        .map((s) {
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
  /// Statut filtré côté client, confidentialité dans la requête — même raison.
  Stream<List<Recipe>> watchDraftsByOwners(List<String> ownerIds) {
    if (ownerIds.isEmpty) return Stream.value([]);
    final limited = ownerIds.take(30).toList();
    return _col
        .where('created_by', whereIn: limited)
        .where('is_private', isEqualTo: false)
        .snapshots()
        .map((s) {
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
  /// [excludePrivate] : écarte les recettes des livres privés.
  ///
  /// Utilisé par la recherche IA pour constituer le corpus à analyser.
  ///
  /// La confidentialité est un paramètre, et non une valeur fixe, parce que la
  /// réponse dépend de QUI l'on interroge. Mes propres recettes secrètes ont
  /// leur place dans ma recherche ; celles des autres, jamais. Un seul appel
  /// mêlant les deux publics ne pouvait pas trancher, et laissait donc tout
  /// passer.
  Future<List<Recipe>> getAllByOwners(
    List<String> ownerIds, {
    bool includeDrafts = false,
    bool excludePrivate = false,
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

    if (excludePrivate) {
      query = query.where('is_private', isEqualTo: false);
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
    final ref = await _col.add(
      withBookPrivacy(
        toSave.toFirestore(),
        await privacyOfBook(_firestore, toSave.bookId),
      ),
    );
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
      origin: RecipeOrigin.copy,
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
    await _col
        .doc(recipe.id)
        .update(
          withBookPrivacy(
            toSave.toFirestore(),
            await _privacyIfBookChanges(recipe.id, toSave.bookId),
          ),
        );
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

    /// « Non classé » choisi dans la relecture : le rôle posé par l'import
    /// part, et ce qui en dépendait avec lui. Sans ce drapeau, un rôle absent
    /// de [tagsOverride] laisse celui de la base.
    bool clearMealRole = false,

    /// La protéine et le féculent de [tagsOverride] viennent du formulaire de
    /// relecture : un champ `null` y vaut « Non renseigné » et s'efface en
    /// base, marqueur d'examen compris. Sans ce drapeau (validation en lot),
    /// un champ absent laisse celui de la base : le déclencheur ou le
    /// backfill a pu le poser depuis la lecture du brouillon.
    bool mainIngredientsFromForm = false,
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
    final readTags = tagsOverride ?? extractRecipeTags(editedCooklang);
    // Un rôle connu qui ne porte ni protéine ni féculent (entrée, dessert,
    // snack) : les deux champs et le marqueur partent, quelle que soit
    // l'origine des tags. Une valeur restée d'un ancien rôle ne vaut plus.
    final roleDropsMainIngredients =
        readTags.mealRole != null && !readTags.carriesMainIngredients;
    final tags = roleDropsMainIngredients
        ? readTags.withMainIngredients()
        : readTags;
    final deleteMissingMainIngredients =
        tags.mealRole != null &&
        (roleDropsMainIngredients || mainIngredientsFromForm);
    await _col.doc(recipeId).update({
      'titre': titre,
      'raw_cooklang': editedCooklang,
      'draft_cooklang': editedCooklang,
      'review_status': ReviewStatus.validated.name,
      // Champ par champ, et non la carte entière : le rôle dans un repas
      // (`meal_role`, `contains`, `suggested_sides`) est posé par l'import ou
      // par le backfill ; les tags relus depuis le CookLang ne le portent pas,
      // et le formulaire ne le porte que si l'utilisateur ou l'IA l'a posé.
      // Réécrire `tags` en bloc l'effacerait sans un mot.
      for (final e in tags.toMap().entries) 'tags.${e.key}': e.value,
      // Effacement champ par champ de ce que `toMap` n'écrit pas : rôle sans
      // protéine ni féculent, ou « Non renseigné » choisi dans la relecture.
      // `toMap` n'écrit jamais une clé nulle, donc aucune ne se dispute ici.
      if (deleteMissingMainIngredients) ...{
        if (tags.mainProtein == null) 'tags.main_protein': FieldValue.delete(),
        if (tags.mainStarch == null) 'tags.main_starch': FieldValue.delete(),
        if (tags.mainIngredientsCheckedAt == null)
          'tags.main_ingredients_checked_at': FieldValue.delete(),
      },
      // Seul cas où l'on efface : « Non classé » choisi dans la liste. Et
      // seulement si l'objet relu n'en porte pas, sinon deux écritures se
      // disputeraient la même clé.
      if (clearMealRole && tags.mealRole == null) ...{
        'tags.meal_role': FieldValue.delete(),
        'tags.contains': FieldValue.delete(),
        'tags.suggested_sides': FieldValue.delete(),
        'tags.main_protein': FieldValue.delete(),
        'tags.main_starch': FieldValue.delete(),
        'tags.main_ingredients_checked_at': FieldValue.delete(),
      },
      'ingredients_index': buildIngredientsIndex(ingredientsStructured),
      'ingredients': ingredientsStructured.map((i) => i.toMap()).toList(),
      'portions': portions,
      'book_id': bookId,
      'book_titre': bookTitre,
      // Sans livre, la confidentialité actuelle est gardée (pas d'écriture).
      'is_private': ?await _privacyIfBookChanges(recipeId, bookId),
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
      data['thumbnail_urls'] = alignThumbnails(imageUrls, thumbnailUrls);
    }
    await _col.doc(recipeId).update(data);
  }

  /// Rend une liste de vignettes utilisable pour [imageUrls], ou les URLs
  /// pleine résolution si l'appariement est perdu.
  ///
  /// L'onglet Photos lit `thumbnail_urls[i]` pour la photo `i`. Deux listes de
  /// tailles différentes ne laissent pas la fin sans vignette : elles
  /// décalent, et la première carte affiche la photo d'une autre. Trois
  /// recettes ont fini avec deux photos et une seule vignette — celle de la
  /// seconde —, chaque fois après un ajout d'illustration sur un brouillon
  /// sans vignettes : `newThumbs` partait d'une liste vide, et la vignette
  /// ajoutée atterrissait en position 0.
  ///
  /// Quand les tailles diffèrent, rien ne dit à quelle photo chaque vignette
  /// appartient. On ne devine pas : les URLs pleine résolution sont plus
  /// lourdes à charger, ce sont les bonnes photos.
  static List<String> alignThumbnails(
    List<String> imageUrls,
    List<String> thumbnailUrls,
  ) => thumbnailUrls.length == imageUrls.length
      ? thumbnailUrls
      : List<String>.from(imageUrls);

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

  /// Recettes d'un livre que [viewer] peut modifier : toutes pour un
  /// administrateur, les siennes sinon — la règle Firestore refuse la
  /// modification de la recette d'un autre, et un lot refusé l'est en entier.
  Query<Map<String, dynamic>> _modifiableOfBook(
    String bookId,
    RecipeViewer viewer,
  ) {
    final base = _col.where('book_id', isEqualTo: bookId);
    return viewer.isAdmin
        ? base
        : base.where('created_by', isEqualTo: viewer.uid);
  }

  /// Détache d'un livre toutes les recettes (validées et brouillons) que
  /// [viewer] peut modifier. Celles des autres gardent leur rattachement.
  Future<void> detachAllRecipesFromBook(
    String bookId,
    RecipeViewer viewer,
  ) async {
    final snapshot = await _modifiableOfBook(bookId, viewer).get();
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

  /// Supprime toutes les recettes (validées et brouillons) d'un livre que
  /// [viewer] peut supprimer. Celles des autres restent.
  Future<void> deleteAllRecipesOfBook(
    String bookId,
    RecipeViewer viewer,
  ) async {
    final snapshot = await _modifiableOfBook(bookId, viewer).get();
    if (snapshot.docs.isEmpty) return;

    final batch = _firestore.batch();
    for (final doc in snapshot.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }
}
