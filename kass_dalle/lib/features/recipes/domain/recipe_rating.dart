import 'package:cloud_firestore/cloud_firestore.dart';

/// Note personnelle d'un utilisateur sur une recette (0-10).
/// Stockée dans la collection `recipe_ratings` avec le document ID `{userId}_{recipeId}`.
class RecipeRating {
  final String userId;
  final String recipeId;
  final int rating; // 0-10
  final DateTime updatedAt;

  const RecipeRating({
    required this.userId,
    required this.recipeId,
    required this.rating,
    required this.updatedAt,
  });

  static String docId(String userId, String recipeId) =>
      '${userId}_$recipeId';

  factory RecipeRating.fromFirestore(Map<String, dynamic> data) {
    return RecipeRating(
      userId: data['user_id'] as String,
      recipeId: data['recipe_id'] as String,
      rating: data['rating'] as int? ?? 0,
      updatedAt: (data['updated_at'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'user_id': userId,
        'recipe_id': recipeId,
        'rating': rating,
        'updated_at': updatedAt,
      };
}
