import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import '../../../core/utils/kassdale_cover_generator.dart';
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
    return _col.where('created_by', whereIn: limited).snapshots().map((s) {
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

  /// Trouve ou crée le livre "Mes créations Kass'Dalle ✨" pour un utilisateur.
  ///
  /// Ce livre spécial reçoit toutes les recettes générées par l'IA.
  /// Si le livre n'a pas encore de couverture (création ou migration),
  /// une image de couverture est générée et uploadée automatiquement.
  ///
  /// Retourne `(id, titre)` du livre.
  Future<({String id, String titre})> findOrCreateKassDalleBook(
    String uid,
  ) async {
    const titre = "Mes créations Kass'Dalle ✨";
    const tag = '__kassdale_ia';

    // Chercher d'abord par tag interne (robuste même si l'utilisateur renomme).
    final byTag = await _col
        .where('created_by', isEqualTo: uid)
        .where('tags', arrayContains: tag)
        .limit(1)
        .get();

    if (byTag.docs.isNotEmpty) {
      final doc = byTag.docs.first;
      final bookId = doc.id;
      final bookTitre = doc.data()['titre'] as String? ?? titre;
      // Migration : si le livre existant n'a pas encore de couverture, en générer une.
      final cover = doc.data()['url_couverture'] as String?;
      if (cover == null || cover.isEmpty) {
        unawaited(_uploadGeneratedCover(bookId));
      }
      return (id: bookId, titre: bookTitre);
    }

    // Créer le livre spécial.
    final now = DateTime.now();
    final book = Book(
      id: '',
      titre: titre,
      auteur: "Kass'Dalle",
      langue: 'fr',
      description:
          "Recettes créées par l'intelligence artificielle Kass'Dalle. "
          "Vous pouvez modifier ce livre comme n'importe quel autre.",
      tags: [tag, 'ia', 'kassdale'],
      reviewStatus: BookReviewStatus.validated,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
    );
    final id = await createBook(book);
    unawaited(_uploadGeneratedCover(id));
    return (id: id, titre: titre);
  }

  /// Vérifie si le livre "Mes créations Kass'Dalle ✨" de [uid] n'a pas encore
  /// de couverture et en génère une si nécessaire.
  /// À appeler au démarrage / ouverture de la bibliothèque (migration silencieuse).
  Future<void> ensureKassDalleBookHasCover(String uid) async {
    const tag = '__kassdale_ia';
    try {
      final byTag = await _col
          .where('created_by', isEqualTo: uid)
          .where('tags', arrayContains: tag)
          .limit(1)
          .get();
      if (byTag.docs.isEmpty) return;
      final doc = byTag.docs.first;
      final cover = doc.data()['url_couverture'] as String?;
      if (cover == null || cover.isEmpty) {
        await _uploadGeneratedCover(doc.id);
      }
    } catch (_) {
      // Migration silencieuse — ne pas bloquer l'UI.
    }
  }

  /// Génère la couverture Kass'Dalle et l'associe au livre [bookId].
  /// Silencieux en cas d'erreur (la couverture est optionnelle).
  Future<void> _uploadGeneratedCover(String bookId) async {
    try {
      final bytes = await KassDalleCoverGenerator.generate();
      final ref = FirebaseStorage.instance.ref('covers/$bookId/cover.jpg');
      await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/png'),
      );
      final url = await ref.getDownloadURL();
      await _col.doc(bookId).update({
        'url_couverture': url,
        'updated_at': Timestamp.now(),
      });
    } catch (_) {
      // La couverture est facultative — ne pas bloquer la création du livre.
    }
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
