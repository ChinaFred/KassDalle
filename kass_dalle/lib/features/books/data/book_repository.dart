import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/services.dart';
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
          .where(
            (b) =>
                b.reviewStatus == BookReviewStatus.validated && !b.isPrivate,
          )
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
      // Migration : si le livre existant n'a pas encore de couverture, utiliser l'asset.
      final cover = doc.data()['url_couverture'] as String?;
      if (cover == null || cover.isEmpty) {
        unawaited(_uploadAssetCover('assets/mycreations.png', bookId));
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
    unawaited(_uploadAssetCover('assets/mycreations.png', id));
    return (id: id, titre: titre);
  }

  /// Upload un asset Flutter vers Firebase Storage comme couverture de [bookId].
  /// Met à jour [url_couverture] dans Firestore.
  Future<void> _uploadAssetCover(String assetPath, String bookId) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      final contentType = assetPath.endsWith('.png') ? 'image/png' : 'image/jpeg';
      final storageRef = FirebaseStorage.instance.ref('covers/$bookId/cover.jpg');
      final task = await storageRef.putData(
        bytes,
        SettableMetadata(contentType: contentType),
      );
      final url = await task.ref.getDownloadURL();
      await _col.doc(bookId).update({
        'url_couverture': url,
        'updated_at': Timestamp.now(),
      });
    } catch (_) {
      // Migration silencieuse — ne pas bloquer l'UI.
    }
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
        // Utiliser l'asset par défaut pour "Mes créations Kass'Dalle"
        await _uploadAssetCover('assets/mycreations.png', doc.id);
      }
    } catch (_) {
      // Migration silencieuse — ne pas bloquer l'UI.
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

  // ── Livres système ───────────────────────────────────────────────────────────

  /// Trouve ou crée le livre "Mes recettes libres" pour [uid].
  Future<({String id, String titre})> findOrCreateLibresBook(
    String uid,
    String displayName,
  ) async {
    const tag = Book.tagLibres;
    const titre = 'Mes recettes libres';

    final byTag = await _col
        .where('created_by', isEqualTo: uid)
        .where('tags', arrayContains: tag)
        .limit(1)
        .get();

    if (byTag.docs.isNotEmpty) {
      final doc = byTag.docs.first;
      final cover = doc.data()['url_couverture'] as String?;
      if (cover == null || cover.isEmpty) {
        unawaited(_uploadAssetCover('assets/opensource.png', doc.id));
      }
      return (id: doc.id, titre: doc.data()['titre'] as String? ?? titre);
    }

    final now = DateTime.now();
    final book = Book(
      id: '',
      titre: titre,
      auteur: displayName,
      langue: 'fr',
      description: 'Mes recettes créées en dehors de tout livre.',
      tags: [tag],
      reviewStatus: BookReviewStatus.validated,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      isPrivate: false,
    );
    final id = await createBook(book);
    unawaited(_uploadAssetCover('assets/opensource.png', id));
    return (id: id, titre: titre);
  }

  /// Trouve ou crée le livre "Mes Recettes Secrètes" pour [uid].
  Future<({String id, String titre})> findOrCreateSecretesBook(
    String uid,
    String displayName,
  ) async {
    const tag = Book.tagSecretes;
    const titre = 'Mes Recettes Secrètes';

    final byTag = await _col
        .where('created_by', isEqualTo: uid)
        .where('tags', arrayContains: tag)
        .limit(1)
        .get();

    if (byTag.docs.isNotEmpty) {
      final doc = byTag.docs.first;
      final cover = doc.data()['url_couverture'] as String?;
      if (cover == null || cover.isEmpty) {
        unawaited(_uploadAssetCover('assets/Secret.png', doc.id));
      }
      return (id: doc.id, titre: doc.data()['titre'] as String? ?? titre);
    }

    final now = DateTime.now();
    final book = Book(
      id: '',
      titre: titre,
      auteur: displayName,
      langue: 'fr',
      description: 'Mes recettes privées — non visibles par la famille.',
      tags: [tag],
      reviewStatus: BookReviewStatus.validated,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      isPrivate: true,
    );
    final id = await createBook(book);
    unawaited(_uploadAssetCover('assets/Secret.png', id));
    return (id: id, titre: titre);
  }

  /// Migration : attache toutes les recettes sans livre de [uid] au livre
  /// "Mes recettes libres" [libresBookId].
  Future<void> migrateLibresRecipes(
    String uid,
    String libresBookId,
    String libresTitre,
  ) async {
    try {
      final snapshot = await _firestore
          .collection('recipes')
          .where('created_by', isEqualTo: uid)
          .where('book_id', isNull: true)
          .get();

      if (snapshot.docs.isEmpty) return;

      final batch = _firestore.batch();
      final now = Timestamp.now();
      for (final doc in snapshot.docs) {
        batch.update(doc.reference, {
          'book_id': libresBookId,
          'book_titre': libresTitre,
          'updated_at': now,
        });
      }
      await batch.commit();
    } catch (_) {
      // Migration silencieuse.
    }
  }

  /// Initialise les trois livres système pour [uid] et migre les recettes libres.
  /// À appeler au démarrage / ouverture de la bibliothèque.
  Future<void> ensureSystemBooks(String uid, String displayName) async {
    try {
      // 1. Livre Kass'Dalle (couverture générée si absente)
      unawaited(ensureKassDalleBookHasCover(uid));
      // 2. Livre "Mes recettes libres"
      final libres = await findOrCreateLibresBook(uid, displayName);
      // 3. Migration des recettes sans livre
      unawaited(migrateLibresRecipes(uid, libres.id, libres.titre));
      // 4. Livre "Mes Recettes Secrètes"
      unawaited(findOrCreateSecretesBook(uid, displayName));
    } catch (_) {
      // Silencieux — ne pas bloquer l'UI.
    }
  }
}
