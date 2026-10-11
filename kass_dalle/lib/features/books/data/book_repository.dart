import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import '../../../core/services/error_report_service.dart';
import '../../moderation/data/image_moderation_service.dart';
import '../domain/book.dart';

class BookRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;
  final ImageModerationService _moderation;

  BookRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
    ImageModerationService? moderation,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       // Le rapport d'erreur suit le Firestore du repository : en test, il
       // écrit dans le Firestore de test au lieu d'exiger l'App réelle.
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore),
       _moderation = moderation ?? ImageModerationService();

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
  ///
  /// La confidentialité part dans la requête : la règle Firestore ne laisse
  /// lire le livre d'un autre que s'il porte `is_private == false`, et refuse
  /// la requête entière si ce filtre manque. Le statut reste filtré côté
  /// client.
  Stream<List<Book>> watchValidatedBooksByOwners(List<String> ownerIds) {
    if (ownerIds.isEmpty) return Stream.value([]);
    final limited = ownerIds.take(30).toList();
    return _col
        .where('created_by', whereIn: limited)
        .where('is_private', isEqualTo: false)
        .snapshots()
        .map((s) {
          final list = s.docs
              .map((d) => Book.fromFirestore(d.id, d.data()))
              .where(
                (b) =>
                    b.reviewStatus == BookReviewStatus.validated &&
                    !b.isPrivate,
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

  /// Envoie la couverture d'un livre et retourne son URL publiée.
  ///
  /// Passe par la quarantaine et la modération : `covers/` est fermé en
  /// écriture côté règles Storage, seul le serveur y dépose. Lève
  /// [ImageNotPublished] si l'image est retenue ou refusée — l'appelant doit le
  /// dire à l'utilisateur, pas l'avaler.
  Future<String> uploadCover(String bookId, Uint8List bytes) async {
    return _moderation.publish(
      PendingImage(
        bytes: bytes,
        filename: 'cover.jpg',
        contentType: 'image/jpeg',
        target: ModerationTarget.bookCover,
        ownerId: bookId,
      ),
    );
  }

  /// Met à jour [url_couverture] dans Firestore.
  Future<void> _uploadAssetCover(String assetPath, String bookId) async {
    try {
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      final contentType = assetPath.endsWith('.png')
          ? 'image/png'
          : 'image/jpeg';
      // Origine « asset » : c'est notre propre image, livrée avec
      // l'application. Elle emprunte le même chemin — c'est ce qui permet de
      // fermer `covers/` en écriture — et le serveur la dispense d'analyse
      // après avoir reconnu son empreinte (`moderation/origin.ts`). Une image
      // de `assets/` modifiée doit voir son empreinte mise à jour là-bas.
      final url = await _moderation.publish(
        PendingImage(
          bytes: bytes,
          filename: assetPath.split('/').last,
          contentType: contentType,
          target: ModerationTarget.bookCover,
          ownerId: bookId,
          origin: ModerationOrigin.asset,
        ),
      );
      await _col.doc(bookId).update({
        'url_couverture': url,
        'updated_at': Timestamp.now(),
      });
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'book_upload_asset_cover',
          error: e,
          stackTrace: st,
          context: {'asset_path': assetPath, 'book_id': bookId},
        ),
      );
    }
  }

  Future<void> updateBook(Book book) async {
    await _col.doc(book.id).update(book.toFirestore());
  }

  /// Supprime un livre — sauf s'il est un livre système.
  ///
  /// Le menu masquait déjà « Supprimer » sur ces livres-là, mais une règle qui
  /// ne vit que dans un menu est à un appel de distance d'être enfreinte. Et
  /// perdre « Mes recettes libres » ou « Mes créations Kass'Dalle » ne perd pas
  /// qu'un livre : c'est la destination par défaut de toute recette sans livre
  /// qui disparaît, et les recettes qu'ils portent se retrouvent orphelines.
  ///
  /// Le refus est aussi posé dans les Security Rules : c'est la seule barrière
  /// qu'un client ne peut pas contourner.
  Future<void> deleteBook(String bookId) async {
    final snap = await _col.doc(bookId).get();
    final data = snap.data();
    if (data != null) {
      final book = Book.fromFirestore(snap.id, data);
      if (book.isSystemBook) {
        throw StateError(
          'Le livre « ${book.titre} » est un livre système : il peut être '
          'renommé, jamais supprimé.',
        );
      }
    }
    await _col.doc(bookId).delete();
  }

  // ── Ordre d'affichage (préférence par utilisateur) ───────────────────────

  /// L'ordre des livres dans la bibliothèque appartient au lecteur, pas au
  /// livre : plusieurs membres de la famille voient les mêmes livres et les
  /// rangent chacun à leur façon. Il vit donc sous l'utilisateur.
  DocumentReference<Map<String, dynamic>> _bookOrderDoc(String uid) =>
      _firestore
          .collection('users')
          .doc(uid)
          .collection('preferences')
          .doc('book_order');

  /// Ordre choisi par [uid], sous forme d'identifiants de livres.
  ///
  /// Une lecture en panne ne masque pas la bibliothèque : l'erreur est
  /// rapportée et le flux se tait, les livres s'affichent alors dans leur
  /// ordre naturel (dernière modification d'abord).
  Stream<List<String>> watchBookOrder(String uid) {
    return _bookOrderDoc(uid)
        .snapshots()
        .map(
          (doc) =>
              List<String>.from(doc.data()?['book_ids'] as List? ?? const []),
        )
        .handleError((Object e, StackTrace st) {
          unawaited(
            _errorReportService.reportError(
              feature: 'book_order_watch',
              error: e,
              stackTrace: st,
              context: {'uid': uid},
            ),
          );
        });
  }

  /// Enregistre l'ordre visible de [uid]. Écrit le document en entier : une
  /// liste partielle serait un rangement partiel.
  Future<void> saveBookOrder(String uid, List<String> bookIds) async {
    await _bookOrderDoc(
      uid,
    ).set({'book_ids': bookIds, 'updated_at': Timestamp.now()});
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

  /// Fait créer « Mes recettes du web » par le serveur, puis pose sa
  /// couverture si elle manque. Best-effort : ouvrir la bibliothèque ne doit
  /// pas échouer pour ce livre, mais l'échec est rapporté.
  Future<void> _ensureWebBookCover(
    String uid,
    Future<String> Function() ensureWebBook,
  ) async {
    try {
      final bookId = await ensureWebBook();
      if (bookId.isEmpty) return;
      final doc = await _col.doc(bookId).get();
      final cover = doc.data()?['url_couverture'] as String?;
      if (cover == null || cover.isEmpty) {
        await _uploadAssetCover(webBookCoverAsset, bookId);
      }
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'book_ensure_web_book',
          error: e,
          stackTrace: st,
          context: {'uid': uid},
        ),
      );
    }
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
  /// Rattache au livre des recettes libres celles qui n'ont pas de livre.
  ///
  /// Rend le nombre de recettes déplacées — sans quoi l'opération est
  /// indistinguable d'une opération qui n'a rien trouvé.
  ///
  /// Elle cherche **deux** formes d'absence : le champ manquant, et le champ
  /// vide. Une chaîne vide n'est pas `null` pour Firestore : les recettes
  /// écrites avec `book_id: ''` échappaient à la requête et restaient
  /// orphelines pour toujours, alors qu'elles s'affichaient exactement comme
  /// les autres. C'est le genre d'écart qu'aucun écran ne montre.
  Future<int> migrateLibresRecipes(
    String uid,
    String libresBookId,
    String libresTitre,
  ) async {
    try {
      final results = await Future.wait([
        _firestore
            .collection('recipes')
            .where('created_by', isEqualTo: uid)
            .where('book_id', isNull: true)
            .get(),
        _firestore
            .collection('recipes')
            .where('created_by', isEqualTo: uid)
            .where('book_id', isEqualTo: '')
            .get(),
      ]);

      // Une recette libre privée — page détachée d'un livre privé — n'est pas
      // rangée dans « Mes recettes libres » : elle y deviendrait partagée si
      // ce livre l'est. Elle reste libre, et privée.
      final docs = {
        for (final snap in results)
          for (final doc in snap.docs)
            if (doc.data()['is_private'] != true) doc.id: doc.reference,
      };
      if (docs.isEmpty) return 0;

      // « Mes recettes libres » peut avoir été rendu privé : la recette prend
      // la confidentialité du livre, comme l'exigent les règles Firestore.
      final libresSnap = await _col.doc(libresBookId).get();
      final isPrivate = libresSnap.data()?['is_private'] == true;
      final batch = _firestore.batch();
      final now = Timestamp.now();
      for (final ref in docs.values) {
        batch.update(ref, {
          'book_id': libresBookId,
          'book_titre': libresTitre,
          'is_private': isPrivate,
          'updated_at': now,
        });
      }
      await batch.commit();
      return docs.length;
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'book_migrate_libres_recipes',
          error: e,
          stackTrace: st,
          context: {'uid': uid, 'libres_book_id': libresBookId},
        ),
      );
      rethrow;
    }
  }

  /// Initialise les livres système pour [uid] et migre les recettes libres.
  /// À appeler au démarrage / ouverture de la bibliothèque, pour un éditeur ou
  /// un administrateur seulement : un lecteur ne crée pas de recette, il n'a
  /// pas besoin de livre pour en recevoir (et les règles lui refusent la
  /// création d'un livre).
  ///
  /// [ensureWebBook] crée « Mes recettes du web » côté serveur
  /// (`ensureWebBookFn`) — le client n'a pas le droit de le faire — et rend
  /// son identifiant ; la couverture est ensuite posée ici, comme pour les
  /// trois autres.
  Future<void> ensureSystemBooks(
    String uid,
    String displayName, {
    Future<String> Function()? ensureWebBook,
  }) async {
    if (ensureWebBook != null) {
      unawaited(_ensureWebBookCover(uid, ensureWebBook));
    }
    try {
      // 1. Livre Kass'Dalle (créé si absent, couverture asset si manquante)
      unawaited(findOrCreateKassDalleBook(uid));
      // 2. Livre "Mes recettes libres"
      final libres = await findOrCreateLibresBook(uid, displayName);
      // 3. Migration des recettes sans livre
      // La migration lève désormais en cas d'échec, pour que l'opération
      // manuelle puisse le dire. Ici, elle reste best-effort : ouvrir la
      // bibliothèque ne doit pas échouer parce qu'une recette n'a pas pu être
      // rattachée. L'erreur est déjà rapportée par la méthode elle-même.
      unawaited(
        migrateLibresRecipes(
          uid,
          libres.id,
          libres.titre,
        ).catchError((Object _) => 0),
      );
      // 4. Livre "Mes Recettes Secrètes"
      unawaited(findOrCreateSecretesBook(uid, displayName));
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'book_ensure_system_books',
          error: e,
          stackTrace: st,
          context: {'uid': uid, 'display_name': displayName},
        ),
      );
    }
  }
}
