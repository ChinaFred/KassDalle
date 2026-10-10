import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/recipe_rating.dart';

class RecipeRatingRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  RecipeRatingRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('recipe_ratings');

  /// Observe la note de [userId] pour [recipeId].
  Stream<RecipeRating?> watch(String userId, String recipeId) {
    return _col.doc(RecipeRating.docId(userId, recipeId)).snapshots().map((
      snap,
    ) {
      if (!snap.exists || snap.data() == null) return null;
      return RecipeRating.fromFirestore(snap.data()!);
    });
  }

  /// Observe toutes les notes posées sur [recipeId], tous membres confondus.
  ///
  /// Le filtre par groupe se fait dans l'appelant : la requête ne porte que
  /// sur `recipe_id`, que la règle `recipe_ratings` sait prouver. Une lecture
  /// en panne est rapportée, puis transmise à l'écran, qui affiche « Notes de
  /// la famille indisponibles » plutôt qu'une moyenne fausse.
  Stream<List<RecipeRating>> watchAllForRecipe(String recipeId) {
    return _col
        .where('recipe_id', isEqualTo: recipeId)
        .snapshots()
        .map((snap) => snap.docs.map(_decodeOrNull).nonNulls.toList())
        .transform(
          StreamTransformer<
            List<RecipeRating>,
            List<RecipeRating>
          >.fromHandlers(
            handleError: (error, stackTrace, sink) {
              unawaited(
                _errorReportService.reportError(
                  feature: 'recipes.ratings_watch',
                  error: error,
                  stackTrace: stackTrace,
                  context: {'recipe_id': recipeId},
                ),
              );
              sink.addError(error, stackTrace);
            },
          ),
        );
  }

  /// Une note illisible (écrite avant la validation des règles) est
  /// rapportée et écartée : elle ne doit pas masquer celles des autres.
  RecipeRating? _decodeOrNull(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    try {
      return RecipeRating.fromFirestore(d.data());
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'recipes.rating_decode',
          error: e,
          stackTrace: st,
          context: {'rating_id': d.id},
        ),
      );
      return null;
    }
  }

  /// Enregistre ou met à jour la note. Un échec est rapporté puis relancé :
  /// l'écran l'annonce à l'utilisateur.
  Future<void> setRating({
    required String userId,
    required String recipeId,
    required int rating,
  }) async {
    assert(rating >= 0 && rating <= 10);
    try {
      await _col.doc(RecipeRating.docId(userId, recipeId)).set({
        'user_id': userId,
        'recipe_id': recipeId,
        'rating': rating,
        'updated_at': DateTime.now(),
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'recipes.rating_set',
        error: e,
        stackTrace: st,
        context: {'recipe_id': recipeId, 'rating': rating},
      );
      rethrow;
    }
  }

  /// Charge toutes les notes d'un utilisateur en une seule requête.
  Future<List<RecipeRating>> getAllForUser(String userId) async {
    final snap = await _col.where('user_id', isEqualTo: userId).get();
    return snap.docs.map(_decodeOrNull).nonNulls.toList();
  }

  /// Supprime la note. Un échec est rapporté puis relancé.
  Future<void> deleteRating({
    required String userId,
    required String recipeId,
  }) async {
    try {
      await _col.doc(RecipeRating.docId(userId, recipeId)).delete();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'recipes.rating_delete',
        error: e,
        stackTrace: st,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }
}
