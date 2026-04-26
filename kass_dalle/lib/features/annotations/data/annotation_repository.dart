import 'package:cloud_firestore/cloud_firestore.dart';
import '../domain/annotation.dart';

class AnnotationRepository {
  final FirebaseFirestore _firestore;

  AnnotationRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String recipeId) =>
      _firestore.collection('recipes').doc(recipeId).collection('annotations');

  // ── Lecture ─────────────────────────────────────────────────────────────────

  Stream<List<Annotation>> watchAnnotations(String recipeId) {
    return _col(recipeId)
        .orderBy('created_at', descending: true)
        .snapshots()
        .map(
          (s) => s.docs
              .map((d) => Annotation.fromFirestore(d.id, recipeId, d.data()))
              .toList(),
        );
  }

  // ── Création ─────────────────────────────────────────────────────────────────

  Future<String> addAnnotation({
    required String recipeId,
    required String uid,
    required String authorName,
    required String text,
    required AnnotationType type,
  }) async {
    final ref = await _col(recipeId).add({
      'uid': uid,
      'author_name': authorName,
      'text': text,
      'type': type.name,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': null,
    });
    return ref.id;
  }

  // ── Mise à jour ──────────────────────────────────────────────────────────────

  Future<void> updateAnnotation({
    required String recipeId,
    required String annotationId,
    required String text,
    required AnnotationType type,
  }) async {
    await _col(recipeId).doc(annotationId).update({
      'text': text,
      'type': type.name,
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  // ── Suppression ──────────────────────────────────────────────────────────────

  Future<void> deleteAnnotation({
    required String recipeId,
    required String annotationId,
  }) async {
    await _col(recipeId).doc(annotationId).delete();
  }
}
