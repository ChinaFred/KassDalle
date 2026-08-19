import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/services/usage_tracker.dart';
import '../../processing/data/processing_job_repository.dart';
import '../../../core/services/error_report_service.dart';
import '../../books/data/book_repository.dart';
import '../../processing/domain/processing_job.dart';
import 'scan_state.dart';
export 'scan_state.dart';

// ── Notifier ───────────────────────────────────────────────────────────────────────

class ScanUploadNotifier extends Notifier<ScanState> {
  late final ProcessingJobRepository _jobsRepo;
  late final FirebaseStorage _storage;
  late final FirebaseAuth _auth;
  late final UsageTracker _usage;
  late final GeminiService _gemini;
  late final ErrorReportService _errorReportService;
  final ImagePicker _imagePicker = ImagePicker();

  /// Pages accumulées en mode multi-page (non persistées dans state pour éviter
  /// de mettre de gros Uint8List dans le state Riverpod).
  final List<_PendingPage> _pendingPages = [];

  @override
  ScanState build() {
    _jobsRepo = ProcessingJobRepository();
    _storage = FirebaseStorage.instance;
    _auth = FirebaseAuth.instance;
    _usage = UsageTracker();
    _gemini = GeminiService();
    _errorReportService = ErrorReportService();
    return const ScanState();
  }

  Future<void> pickAndQueueRecipe({String? bookId, String? bookTitre}) {
    return _pickAndQueue(
      intent: ScanIntent.recipe,
      allowedExtensions: const ['pdf', 'docx', 'jpg', 'jpeg', 'png'],
      bookId: bookId,
      bookTitre: bookTitre,
    );
  }

  /// Ajoute une page supplémentaire depuis le sélecteur de fichiers
  /// (actif uniquement quand status == pendingFiles).
  Future<void> addPage() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
      );
      if (result == null) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) return;
      _pendingPages.add(
        _PendingPage(
          bytes: bytes,
          filename: file.name,
          extension: file.extension ?? '',
          mimeType: _mimeTypeFor(file.extension ?? ''),
        ),
      );
      state = state.copyWith(
        pendingPageNames: _pendingPages.map((p) => p.filename).toList(),
      );
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.addPageFromFile',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Ajoute une page supplémentaire depuis la caméra.
  Future<void> addPageFromCamera() async {
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 92,
      );
      if (photo == null) return;
      final bytes = await photo.readAsBytes();
      final filename = photo.name.isNotEmpty
          ? photo.name
          : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      _pendingPages.add(
        _PendingPage(
          bytes: bytes,
          filename: filename,
          extension: 'jpg',
          mimeType: 'image/jpeg',
        ),
      );
      state = state.copyWith(
        pendingPageNames: _pendingPages.map((p) => p.filename).toList(),
      );
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.addPageFromCamera',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Supprime une page de la file multi-page.
  void removePendingPageAt(int index) {
    if (index < 0 || index >= _pendingPages.length) return;
    _pendingPages.removeAt(index);
    if (_pendingPages.isEmpty) {
      cancelPendingPages();
      return;
    }
    state = state.copyWith(
      pendingPageNames: _pendingPages.map((p) => p.filename).toList(),
    );
  }

  /// Lance le traitement de toutes les pages accumulées.
  Future<void> processPages({String? bookId, String? bookTitre}) async {
    if (_pendingPages.isEmpty) return;
    final first = _pendingPages.first;
    final additional = _pendingPages.skip(1).toList();
    await _processSelectedBytes(
      bytes: first.bytes,
      filename: first.filename,
      extension: first.extension,
      intent: ScanIntent.recipe,
      bookId: bookId,
      bookTitre: bookTitre,
      additionalPages: additional,
    );
  }

  /// Annule l'accumulation de pages et remet à zéro.
  void cancelPendingPages() {
    _pendingPages.clear();
    state = const ScanState();
  }

  Future<void> pickAndQueueBookCover() {
    return _pickAndQueueBookCoverFromGallery();
  }

  Future<void> _pickAndQueueBookCoverFromGallery() async {
    state = state.copyWith(
      status: ScanStatus.picking,
      intent: ScanIntent.bookCover,
    );
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (photo == null) {
        state = const ScanState();
        return;
      }

      final bytes = await photo.readAsBytes();
      final filename = photo.name.isNotEmpty
          ? photo.name
          : 'cover_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Montre l'écran d'amélioration avant l'upload
      state = ScanState(
        status: ScanStatus.pendingEnhancement,
        intent: ScanIntent.bookCover,
        pendingImageBytes: bytes,
        pendingImageFilename: filename,
      );
    } catch (e, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.pickBookCover',
        error: e,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Impossible d\'importer la couverture : $e',
      );
    }
  }

  Future<void> pickAndQueueBookDocument({
    required String? bookId,
    required String? bookTitre,
  }) {
    return _pickAndQueue(
      intent: ScanIntent.bookDocument,
      allowedExtensions: const ['pdf', 'docx', 'jpg', 'jpeg', 'png'],
      bookId: bookId,
      bookTitre: bookTitre,
    );
  }

  Future<void> _pickAndQueue({
    required ScanIntent intent,
    required List<String> allowedExtensions,
    String? bookId,
    String? bookTitre,
  }) async {
    state = state.copyWith(status: ScanStatus.picking, intent: intent);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: allowedExtensions,
        withData: true,
      );
      if (result == null) {
        state = const ScanState();
        return;
      }
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        state = state.copyWith(
          status: ScanStatus.error,
          errorMessage: 'Fichier vide ou inaccessible.',
        );
        return;
      }

      // Pour les recettes : accumulation multi-page avant traitement
      if (intent == ScanIntent.recipe) {
        _pendingPages.add(
          _PendingPage(
            bytes: bytes,
            filename: file.name,
            extension: file.extension ?? '',
            mimeType: _mimeTypeFor(file.extension ?? ''),
          ),
        );
        state = ScanState(
          status: ScanStatus.pendingFiles,
          intent: intent,
          pendingPageNames: _pendingPages.map((p) => p.filename).toList(),
        );
        return;
      }

      // Autres intentions : traitement direct
      await _processSelectedBytes(
        bytes: bytes,
        filename: file.name,
        extension: file.extension ?? '',
        intent: intent,
        bookId: bookId,
        bookTitre: bookTitre,
      );
    } catch (e, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.pickFile',
        error: e,
        stackTrace: stackTrace,
        context: {'intent': intent.name},
      );
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Impossible d\'ouvrir le fichier : $e',
      );
    }
  }

  Future<void> pickFromCameraAndQueueRecipe({
    String? bookId,
    String? bookTitre,
  }) async {
    await _pickFromCameraAndQueue(
      intent: ScanIntent.recipe,
      bookId: bookId,
      bookTitre: bookTitre,
    );
  }

  Future<void> pickFromCameraAndQueueBookCover() async {
    await _pickFromCameraAndQueue(intent: ScanIntent.bookCover);
  }

  Future<void> _pickFromCameraAndQueue({
    required ScanIntent intent,
    String? bookId,
    String? bookTitre,
  }) async {
    state = state.copyWith(status: ScanStatus.picking);
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: CameraDevice.rear,
        imageQuality: 92,
      );
      if (photo == null) {
        state = const ScanState();
        return;
      }

      _PreparedImage? prepared;
      // Skip ImageCropper for camera captures (web + mobile) — raw photo quality is sufficient
      // and avoids native activity crashes on Android.
      final bytes = await photo.readAsBytes();
      final filename = photo.name.isNotEmpty
          ? photo.name
          : 'photo_${DateTime.now().millisecondsSinceEpoch}.jpg';
      prepared = _PreparedImage(
        bytes: bytes,
        filename: filename,
        extension: 'jpg',
      );

      if (intent == ScanIntent.bookCover) {
        // Montre l'écran d'amélioration avant l'upload
        state = ScanState(
          status: ScanStatus.pendingEnhancement,
          intent: intent,
          pendingImageBytes: prepared.bytes,
          pendingImageFilename: prepared.filename,
        );
        return;
      }

      // Pour les recettes : accumulation multi-page
      if (intent == ScanIntent.recipe) {
        _pendingPages.add(
          _PendingPage(
            bytes: prepared.bytes,
            filename: prepared.filename,
            extension: prepared.extension,
            mimeType: _mimeTypeFor(prepared.extension),
          ),
        );
        state = ScanState(
          status: ScanStatus.pendingFiles,
          intent: intent,
          pendingPageNames: _pendingPages.map((p) => p.filename).toList(),
        );
        return;
      }

      await _processSelectedBytes(
        bytes: prepared.bytes,
        filename: prepared.filename,
        extension: prepared.extension,
        intent: intent,
        bookId: bookId,
        bookTitre: bookTitre,
      );
    } catch (e, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.pickFromCamera',
        error: e,
        stackTrace: stackTrace,
        context: {'intent': intent.name},
      );
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Impossible de prendre la photo : $e',
      );
    }
  }

  Future<void> _processSelectedBytes({
    required Uint8List bytes,
    required String filename,
    required String extension,
    required ScanIntent intent,
    String? bookId,
    String? bookTitre,
    List<_PendingPage> additionalPages = const [],
  }) async {
    final mimeType = _mimeTypeFor(extension);

    state = state.copyWith(
      status: ScanStatus.uploading,
      filename: filename,
      uploadProgress: 0,
    );

    // 1. Upload vers Firebase Storage
    String? storageUrl;
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Utilisateur non connecté.',
      );
      return;
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeFilename = _sanitizeFilename(filename);
      final storageRef = _storage.ref(
        'quarantine/$uid/${timestamp}_$safeFilename',
      );
      final uploadTask = storageRef.putData(
        bytes,
        SettableMetadata(contentType: mimeType),
      );
      // `onError` n'est pas une politesse : quand l'envoi échoue, ce flux émet
      // l'erreur AUSSI. Sans gestionnaire, elle s'échappe vers la zone et
      // ressort en `zone_error` anonyme — un rapport sans le poste, sans le
      // fichier, sans rien pour la relier à cet envoi. L'erreur utile est celle
      // que `await uploadTask` lève juste en dessous, avec tout son contexte ;
      // celle-ci est un doublon qu'on absorbe volontairement.
      uploadTask.snapshotEvents.listen(
        (snap) {
          final progress =
              snap.bytesTransferred /
              (snap.totalBytes > 0 ? snap.totalBytes : 1);
          state = state.copyWith(uploadProgress: progress);
        },
        onError: (Object _) {},
        cancelOnError: true,
      );
      final snapshot = await uploadTask;
      state = state.copyWith(status: ScanStatus.scanning, uploadProgress: 1);
      final promoted = await _gemini.scanAndPromoteUpload(
        storagePath: snapshot.ref.fullPath,
      );
      storageUrl = promoted.downloadUrl;
    } catch (e, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.uploadAndPromote',
        error: e,
        stackTrace: stackTrace,
        userId: uid,
        context: {
          'filename': filename,
          'mimeType': mimeType,
          'intent': intent.name,
          'securityRejection': _isSecurityRejection(e),
          // Un refus Storage se diagnostique avec la taille et le chemin : la
          // règle `quarantine/{uid}` ne pose que deux conditions, la propriété
          // du chemin et un plafond de 50 Mo. Sans ces deux valeurs, un
          // « unauthorized » ne se distingue pas d'un fichier trop gros.
          'sizeBytes': bytes.length,
          'storagePath': 'quarantine/$uid/',
          'pages': 1 + additionalPages.length,
        },
      );
      if (_isSecurityRejection(e)) {
        await _recordRejectedJob(
          uid: uid,
          filename: filename,
          mimeType: mimeType,
          intent: intent,
          reason: _rejectionReason(e),
          bookId: bookId,
          bookTitre: bookTitre,
        );
      }
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: _scanErrorMessage(
          e,
          'Echec du scan de securite du fichier.',
        ),
      );
      return;
    }

    // 2. Upload les pages supplémentaires (si multi-page)
    final additionalStorageUrls = <String>[];
    for (var i = 0; i < additionalPages.length; i++) {
      final p = additionalPages[i];
      // Sanitise le nom de fichier : supprime les caractères problématiques pour Storage
      final safeFilename = p.filename
          .replaceAll(RegExp(r'[^a-zA-Z0-9._\-]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
      // Tente l'upload jusqu'à 2 fois en cas d'erreur transitoire
      String? pageUrl;
      for (var attempt = 0; attempt < 2 && pageUrl == null; attempt++) {
        try {
          if (attempt > 0) {
            await Future.delayed(const Duration(seconds: 2));
          }
          state = state.copyWith(
            status: ScanStatus.uploading,
            filename: p.filename,
          );
          final ts = DateTime.now().millisecondsSinceEpoch;
          final ref = _storage.ref(
            'quarantine/$uid/${ts}_p${i + 2}_$safeFilename',
          );
          final snap = await ref.putData(
            p.bytes,
            SettableMetadata(contentType: p.mimeType),
          );
          state = state.copyWith(
            status: ScanStatus.scanning,
            uploadProgress: 1,
          );
          final promoted = await _gemini.scanAndPromoteUpload(
            storagePath: snap.ref.fullPath,
          );
          pageUrl = promoted.downloadUrl;
        } catch (e, stackTrace) {
          _errorReportService.reportError(
            feature: 'scanUpload.uploadPage',
            error: e,
            stackTrace: stackTrace,
            userId: uid,
            context: {
              'filename': p.filename,
              'mimeType': p.mimeType,
              'intent': intent.name,
              'attempt': attempt,
              'securityRejection': _isSecurityRejection(e),
            },
          );
          if (attempt == 1) {
            if (_isSecurityRejection(e)) {
              await _recordRejectedJob(
                uid: uid,
                filename: p.filename,
                mimeType: p.mimeType,
                intent: intent,
                reason: _rejectionReason(e),
                bookId: bookId,
                bookTitre: bookTitre,
              );
            }
            state = state.copyWith(
              status: ScanStatus.error,
              errorMessage: _scanErrorMessage(
                e,
                'Echec du scan de securite sur la page ${i + 2}.',
              ),
            );
            return;
          }
          // Deuxième tentative ou abandon
        }
      }
      additionalStorageUrls.add(pageUrl!);
    }

    // 3. Crée le job puis lance son traitement en arrière-plan.
    //
    // Un import sans livre choisi va dans « Mes recettes libres ». Le livre est
    // résolu ICI, côté client, et voyage avec le job : le serveur reçoit un
    // livre et n'a pas à savoir qu'il existe des livres système. C'est ce qui
    // évite d'écrire une seconde fois, en TypeScript, la logique qui trouve ou
    // crée ce livre — une duplication qui ne rendrait rien.
    final resolvedBook = await _resolveDefaultBook(
      uid: uid,
      intent: intent,
      bookId: bookId,
      bookTitre: bookTitre,
    );

    final now = DateTime.now();
    final job = ProcessingJob(
      id: '',
      type: _mapIntentToJobType(intent),
      status: ProcessingJobStatus.queued,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      fileName: filename,
      fileUrl: storageUrl,
      mimeType: mimeType,
      bookId: resolvedBook.id,
      bookTitre: resolvedBook.titre,
      additionalFileUrls: additionalStorageUrls,
    );

    final jobId = await _jobsRepo.createJob(job);
    _pendingPages.clear();

    // Comptabilise le scan et les octets envoyés. Ce décompte vivait dans le
    // pipeline d'import client ; il appartient à l'envoi, pas au traitement —
    // un fichier envoyé occupe le stockage même si son traitement échoue.
    // Best-effort : un compteur perdu ne doit pas faire échouer un import.
    final uploadedBytes =
        bytes.length +
        additionalPages.fold<int>(0, (s, p) => s + p.bytes.length);
    try {
      await _usage.recordScan(fileBytes: uploadedBytes);
    } catch (error, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.recordScan',
        error: error,
        stackTrace: stackTrace,
        jobId: jobId,
        context: {'uploadedBytes': uploadedBytes},
      );
    }

    state = state.copyWith(
      status: ScanStatus.done,
      uploadProgress: 1,
      queuedJobId: jobId,
      createdRecipeIds: const [],
      createdBookId: null,
      successMessage: _queuedMessage(intent),
      pendingPageNames: const [],
    );

    // Le traitement du job est effectué côté backend (Cloud Tasks +
    // recipeProcessor). Le trigger Firestore `jobDispatcher` réagit à l'entrée
    // en `queued` — création comme relance. Le client se contente d'écouter le
    // document pour les mises à jour de statut.
  }

  void reset() {
    _pendingPages.clear();
    state = const ScanState();
  }

  /// Appelé depuis l'UI après que l'utilisateur a confirmé l'amélioration
  /// de la couverture dans [ImageEnhancerScreen].
  Future<void> confirmEnhancedCover(
    Uint8List enhancedBytes,
    String filename,
  ) async {
    await _processSelectedBytes(
      bytes: enhancedBytes,
      filename: filename,
      extension: 'jpg',
      intent: ScanIntent.bookCover,
    );
  }

  /// Appelé si l'utilisateur annule l'étape d'amélioration.
  void cancelEnhancement() => state = const ScanState();

  /// Relance un job existant : le remet en file, le backend reprend la main.
  ///
  /// Le fichier source est déjà dans Storage et `recipeProcessor` sait aller
  /// l'y chercher — le client n'a rien à retélécharger ni à retraiter. Une
  /// version précédente rejouait ici un pipeline d'import complet côté client,
  /// distinct de celui du backend : deux implémentations pour un même fichier,
  /// donc deux résultats possibles selon qu'on importait ou qu'on relançait.
  ///
  /// `jobDispatcher` écoute l'entrée en `queued`, création comme relance.
  Future<void> retryJob(ProcessingJob job) async {
    if (job.isActive) return; // déjà en cours

    await _jobsRepo.updateJob(job.id, {
      'status': ProcessingJobStatus.queued.name,
      'error_message': null,
      'current_step': null,
      'cancel_requested': false,
      'created_recipe_ids': [],
      'created_book_id': null,
    });
  }

  /// Demande l'arrêt d'un job.
  ///
  /// Le drapeau `cancel_requested` est lu par `recipeProcessor` avant chaque
  /// tentative : c'est lui qui rend l'annulation effective. Le statut seul ne
  /// suffisait pas — le traitement backend l'écrasait en fin de course, et
  /// l'utilisateur voyait réapparaître un job qu'il croyait arrêté.
  Future<void> cancelJob(String jobId) async {
    await _jobsRepo.updateJob(jobId, {
      'status': ProcessingJobStatus.error.name,
      'error_message': 'Job annulé manuellement.',
      'cancel_requested': true,
    });
  }

  ProcessingJobType _mapIntentToJobType(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe => ProcessingJobType.recipeScan,
    ScanIntent.bookCover => ProcessingJobType.bookCoverScan,
    ScanIntent.bookDocument => ProcessingJobType.bookDocumentScan,
  };

  String _queuedMessage(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe =>
      'Scan recette ajoute a la file de traitement. Continuez a importer sans attendre.',
    ScanIntent.bookCover =>
      'Scan de couverture ajoute. Le livre sera cree et ajoute directement a votre bibliotheque.',
    ScanIntent.bookDocument =>
      'Document livre ajoute. Les recettes extraites seront rattachees au livre cible.',
  };

  /// Le livre d'un import : celui qu'on a choisi, ou « Mes recettes libres ».
  ///
  /// Ne vaut que pour l'import d'une recette. Une couverture de livre et un
  /// livre entier créent leur propre livre côté serveur — leur donner une
  /// destination par défaut n'aurait aucun sens.
  ///
  /// Best-effort : si le livre par défaut est introuvable, l'import continue
  /// sans lui plutôt que d'échouer. Une recette orpheline se rattache ; un
  /// import perdu se refait entièrement.
  Future<({String? id, String? titre})> _resolveDefaultBook({
    required String uid,
    required ScanIntent intent,
    required String? bookId,
    required String? bookTitre,
  }) async {
    if (intent != ScanIntent.recipe) return (id: bookId, titre: bookTitre);
    if ((bookId ?? '').isNotEmpty) return (id: bookId, titre: bookTitre);
    try {
      final book = await BookRepository().findOrCreateLibresBook(uid, '');
      return (id: book.id, titre: book.titre);
    } catch (e, stackTrace) {
      _errorReportService.reportError(
        feature: 'scanUpload.resolveDefaultBook',
        error: e,
        stackTrace: stackTrace,
        userId: uid,
      );
      return (id: bookId, titre: bookTitre);
    }
  }

  String _sanitizeFilename(String input) {
    return input
        .replaceAll(RegExp(r'[^a-zA-Z0-9._\-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
  }

  String _scanErrorMessage(Object error, String fallback) {
    if (error is GeminiCallableException) {
      if (error.code == 'failed-precondition') {
        return 'Fichier bloque par le scan de securite: ${error.message}';
      }
      if (error.message.isNotEmpty) return error.message;
    }
    return '$fallback Details: $error';
  }

  /// Vrai si l'erreur correspond à un rejet par le scan de sécurité
  /// (et non à une erreur technique transitoire).
  bool _isSecurityRejection(Object error) =>
      error is GeminiCallableException && error.code == 'failed-precondition';

  /// Raison lisible du rejet, extraite de l'exception du backend.
  String _rejectionReason(Object error) {
    if (error is GeminiCallableException && error.message.isNotEmpty) {
      return error.message;
    }
    return 'Fichier bloqué par le scan de sécurité.';
  }

  /// Persiste un job au statut `rejected` afin que le fichier bloqué reste
  /// visible (avec sa raison) dans l'écran « Brouillons & Traitements ».
  /// Le fichier source reste en quarantaine et n'est pas exposé (fileUrl vide).
  Future<void> _recordRejectedJob({
    required String uid,
    required String filename,
    required String mimeType,
    required ScanIntent intent,
    required String reason,
    String? bookId,
    String? bookTitre,
  }) async {
    final now = DateTime.now();
    final job = ProcessingJob(
      id: '',
      type: _mapIntentToJobType(intent),
      status: ProcessingJobStatus.rejected,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      fileName: filename,
      fileUrl: '',
      mimeType: mimeType,
      bookId: bookId,
      bookTitre: bookTitre,
      errorMessage: reason,
    );
    await _jobsRepo.createJob(job);
  }
}

// ── MIME types ────────────────────────────────────────────────────────────────

String _mimeTypeFor(String ext) => switch (ext.toLowerCase()) {
  'pdf' => 'application/pdf',
  'docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'jpg' || 'jpeg' => 'image/jpeg',
  'png' => 'image/png',
  _ => 'application/octet-stream',
};

class _PreparedImage {
  final Uint8List bytes;
  final String filename;
  final String extension;

  const _PreparedImage({
    required this.bytes,
    required this.filename,
    required this.extension,
  });
}

class _PendingPage {
  final Uint8List bytes;
  final String filename;
  final String extension;
  final String mimeType;

  const _PendingPage({
    required this.bytes,
    required this.filename,
    required this.extension,
    required this.mimeType,
  });
}
