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

  Future<Recipe?> getRecipe(String recipeId) async {
    final doc = await _col.doc(recipeId).get();
    if (!doc.exists) return null;
    return Recipe.fromFirestore(doc.id, doc.data()!);
  }

  // ── Création ─────────────────────────────────────────────────────────────────

  Future<String> createRecipe(Recipe recipe) async {
    final ref = await _col.add(recipe.toFirestore());
    return ref.id;
  }

  // ── Mise à jour ──────────────────────────────────────────────────────────────

  Future<void> updateRecipe(Recipe recipe) async {
    await _col.doc(recipe.id).update(recipe.toFirestore());
  }

  /// Valide un brouillon : rawCooklang ← draftCooklang édité, statut = validated.
  Future<void> validateDraft({
    required String recipeId,
    required String editedCooklang,
    required String titre,
    String? bookId,
    String? bookTitre,
  }) async {
    final ingredients = extractIngredients(editedCooklang);
    await _col.doc(recipeId).update({
      'titre': titre,
      'raw_cooklang': editedCooklang,
      'draft_cooklang': editedCooklang,
      'review_status': ReviewStatus.validated.name,
      'ingredients_index': ingredients,
      'book_id': bookId,
      'book_titre': bookTitre,
      'updated_at': DateTime.now(),
    });
  }

  Future<void> deleteRecipe(String recipeId) async {
    await _col.doc(recipeId).delete();
  }
}
