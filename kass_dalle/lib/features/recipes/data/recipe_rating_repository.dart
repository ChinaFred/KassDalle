import 'package:cloud_firestore/cloud_firestore.dart';
import '../domain/recipe_rating.dart';

class RecipeRatingRepository {
  final FirebaseFirestore _firestore;

  RecipeRatingRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('recipe_ratings');

  /// Observe la note de [userId] pour [recipeId].
  Stream<RecipeRating?> watch(String userId, String recipeId) {
    return _col
        .doc(RecipeRating.docId(userId, recipeId))
        .snapshots()
        .map((snap) {
      if (!snap.exists || snap.data() == null) return null;
      return RecipeRating.fromFirestore(snap.data()!);
    });
  }

  /// Enregistre ou met à jour la note.
  Future<void> setRating({
    required String userId,
    required String recipeId,
    required int rating,
  }) async {
    assert(rating >= 0 && rating <= 10);
    await _col.doc(RecipeRating.docId(userId, recipeId)).set({
      'user_id': userId,
      'recipe_id': recipeId,
      'rating': rating,
      'updated_at': DateTime.now(),
    });
  }

  /// Supprime la note.
  Future<void> deleteRating({
    required String userId,
    required String recipeId,
  }) async {
    await _col.doc(RecipeRating.docId(userId, recipeId)).delete();
  }
}
