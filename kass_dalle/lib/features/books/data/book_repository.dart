import 'package:cloud_firestore/cloud_firestore.dart';
import '../domain/book.dart';

class BookRepository {
  final FirebaseFirestore _firestore;

  BookRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('books');

  // ── Lecture ─────────────────────────────────────────────────────────────────

  /// Livres dont [uid] est propriétaire.
  Stream<List<Book>> watchMyBooks(String uid) {
    return _col
        .where('created_by', isEqualTo: uid)
        .orderBy('updated_at', descending: true)
        .snapshots()
        .map(
          (s) => s.docs.map((d) => Book.fromFirestore(d.id, d.data())).toList(),
        );
  }

  /// Livres partagés avec [uid] par quelqu'un d'autre.
  Stream<List<Book>> watchSharedBooks(String uid) {
    return _col
        .where('shared_with', arrayContains: uid)
        .orderBy('updated_at', descending: true)
        .snapshots()
        .map(
          (s) => s.docs.map((d) => Book.fromFirestore(d.id, d.data())).toList(),
        );
  }

  /// Tous les livres (admin uniquement).
  Stream<List<Book>> watchAllBooks() {
    return _col
        .orderBy('updated_at', descending: true)
        .snapshots()
        .map(
          (s) => s.docs.map((d) => Book.fromFirestore(d.id, d.data())).toList(),
        );
  }

  /// Livres validés des utilisateurs listés (membres d'un groupe).
  /// Filtrage review_status côté client pour éviter les index composites.
  Stream<List<Book>> watchValidatedBooksByOwners(List<String> ownerIds) {
    if (ownerIds.isEmpty) return Stream.value([]);
    final limited = ownerIds.take(30).toList();
    return _col
        .where('created_by', whereIn: limited)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Book.fromFirestore(d.id, d.data()))
              .where((b) => b.reviewStatus == BookReviewStatus.validated)
              .toList();
          list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return list;
        });
  }

  /// Brouillons livre de l'utilisateur connecté.
  Stream<List<Book>> watchDraftBooks(String uid) {
    return _col
        .where('created_by', isEqualTo: uid)
        .where('review_status', isEqualTo: BookReviewStatus.draft.name)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Book.fromFirestore(d.id, d.data()))
              .toList();
          list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
          return list;
        });
  }

  Future<Book?> getBook(String bookId) async {
    final doc = await _col.doc(bookId).get();
    if (!doc.exists) return null;
    return Book.fromFirestore(doc.id, doc.data()!);
  }

  // ── Écriture ─────────────────────────────────────────────────────────────────

  Future<String> createBook(Book book) async {
    final ref = await _col.add(book.toFirestore());
    return ref.id;
  }

  Future<void> updateBook(Book book) async {
    await _col.doc(book.id).update(book.toFirestore());
  }

  Future<void> deleteBook(String bookId) async {
    await _col.doc(bookId).delete();
  }

  // ── Partage ──────────────────────────────────────────────────────────────────

  /// Partage un livre avec [targetUid].
  Future<void> shareBook(String bookId, String targetUid) async {
    await _col.doc(bookId).update({
      'shared_with': FieldValue.arrayUnion([targetUid]),
    });
  }

  /// Retire le partage d'un livre avec [targetUid].
  Future<void> unshareBook(String bookId, String targetUid) async {
    await _col.doc(bookId).update({
      'shared_with': FieldValue.arrayRemove([targetUid]),
    });
  }
}
