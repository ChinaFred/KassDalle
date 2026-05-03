import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/services/usage_tracker.dart';
import '../../books/data/book_repository.dart';
import '../../books/domain/book.dart';
import '../../processing/data/processing_job_repository.dart';
import '../../processing/domain/processing_job.dart';
import '../data/recipe_repository.dart';
import '../domain/recipe.dart';

// ── Clé API Gemini ────────────────────────────────────────────────────────────
// Passée au build via : flutter run --dart-define=GEMINI_API_KEY=AIza...
// En production, utiliser Firebase Remote Config ou un Cloud Function proxy.
const _geminiApiKey = String.fromEnvironment(
  'GEMINI_API_KEY',
  defaultValue: '',
);

// ── État du scan ──────────────────────────────────────────────────────────────

enum ScanStatus { idle, picking, uploading, processing, done, error }

enum ScanIntent { recipe, bookCover, bookDocument }

class ScanState {
  final ScanStatus status;
  final String? filename;
  final double uploadProgress;
  final String? errorMessage;
  final List<String> createdRecipeIds;
  final String? createdBookId;
  final String? queuedJobId;
  final ScanIntent intent;
  final String? successMessage;

  const ScanState({
    this.status = ScanStatus.idle,
    this.filename,
    this.uploadProgress = 0,
    this.errorMessage,
    this.createdRecipeIds = const [],
    this.createdBookId,
    this.queuedJobId,
    this.intent = ScanIntent.recipe,
    this.successMessage,
  });

  ScanState copyWith({
    ScanStatus? status,
    String? filename,
    double? uploadProgress,
    String? errorMessage,
    List<String>? createdRecipeIds,
    String? createdBookId,
    String? queuedJobId,
    ScanIntent? intent,
    String? successMessage,
  }) {
    return ScanState(
      status: status ?? this.status,
      filename: filename ?? this.filename,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      createdRecipeIds: createdRecipeIds ?? this.createdRecipeIds,
      createdBookId: createdBookId ?? this.createdBookId,
      queuedJobId: queuedJobId ?? this.queuedJobId,
      intent: intent ?? this.intent,
      successMessage: successMessage ?? this.successMessage,
    );
  }

  bool get isRunning =>
      status == ScanStatus.picking ||
      status == ScanStatus.uploading ||
      status == ScanStatus.processing;

  String get statusLabel => switch (status) {
    ScanStatus.idle => 'Prêt',
    ScanStatus.picking => 'Sélection du fichier…',
    ScanStatus.uploading => 'Envoi en cours…',
    ScanStatus.processing => 'Analyse IA en cours…',
    ScanStatus.done => 'Terminé',
    ScanStatus.error => 'Erreur',
  };
}

// ── Notifier ──────────────────────────────────────────────────────────────────

class ScanUploadNotifier extends StateNotifier<ScanState> {
  final RecipeRepository _recipeRepo;
  final BookRepository _bookRepo;
  final ProcessingJobRepository _jobsRepo;
  final FirebaseStorage _storage;
  final FirebaseAuth _auth;
  final UsageTracker _usage;
  final ImagePicker _imagePicker = ImagePicker();

  ScanUploadNotifier(
    this._recipeRepo,
    this._bookRepo,
    this._jobsRepo,
    this._storage,
    this._auth,
    this._usage,
  ) : super(const ScanState());

  Future<void> pickAndQueueRecipe({String? bookId, String? bookTitre}) {
    return _pickAndQueue(
      intent: ScanIntent.recipe,
      allowedExtensions: const ['pdf', 'docx', 'jpg', 'jpeg', 'png'],
      bookId: bookId,
      bookTitre: bookTitre,
    );
  }

  Future<void> pickAndQueueBookCover() {
    return _pickAndQueueBookCoverFromGallery();
  }

  Future<void> _pickAndQueueBookCoverFromGallery() async {
    if (_geminiApiKey.isEmpty) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage:
            'Clé API Gemini non configurée.\nLancez l\'app avec : flutter run --dart-define=GEMINI_API_KEY=votre_clé',
      );
      return;
    }

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

      final prepared = await _prepareCoverImage(photo.path);
      if (prepared == null) {
        state = const ScanState();
        return;
      }

      await _processSelectedBytes(
        bytes: prepared.bytes,
        filename: prepared.filename,
        extension: prepared.extension,
        intent: ScanIntent.bookCover,
      );
    } catch (e) {
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
    if (_geminiApiKey.isEmpty) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage:
            'Clé API Gemini non configurée.\nLancez l\'app avec : flutter run --dart-define=GEMINI_API_KEY=votre_clé',
      );
      return;
    }

    state = state.copyWith(status: ScanStatus.picking, intent: intent);
    try {
      final result = await FilePicker.platform.pickFiles(
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

      await _processSelectedBytes(
        bytes: bytes,
        filename: file.name,
        extension: file.extension ?? '',
        intent: intent,
        bookId: bookId,
        bookTitre: bookTitre,
      );
    } catch (e) {
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
    if (_geminiApiKey.isEmpty) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage:
            'Clé API Gemini non configurée.\nLancez l\'app avec : flutter run --dart-define=GEMINI_API_KEY=votre_clé',
      );
      return;
    }

    state = state.copyWith(status: ScanStatus.picking);
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
        imageQuality: 92,
      );
      if (photo == null) {
        state = const ScanState();
        return;
      }

      _PreparedImage? prepared;
      if (kIsWeb) {
        // Sur web, le recadrage natif n'est pas disponible — on lit les bytes directement.
        final bytes = await photo.readAsBytes();
        final filename = photo.name.isNotEmpty ? photo.name : 'photo.jpg';
        prepared = _PreparedImage(bytes: bytes, filename: filename, extension: 'jpg');
      } else {
        prepared = await _cropCapturedImage(
          path: photo.path,
          title: intent == ScanIntent.bookCover
              ? 'Ajuster la couverture'
              : 'Ajuster la photo',
        );
      }

      if (prepared == null) {
        state = const ScanState();
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
    } catch (e) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Impossible de prendre la photo : $e',
      );
    }
  }

  Future<_PreparedImage?> _cropCapturedImage({
    required String path,
    required String title,
  }) async {
    final cropped = await ImageCropper().cropImage(
      sourcePath: path,
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 96,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: title,
          lockAspectRatio: false,
          hideBottomControls: false,
          cropGridStrokeWidth: 2,
        ),
        IOSUiSettings(title: title),
      ],
    );
    if (cropped == null) return null;

    final bytes = await XFile(cropped.path).readAsBytes();
    final fileName = _fileNameFromPath(cropped.path);
    return _PreparedImage(bytes: bytes, filename: fileName, extension: 'jpg');
  }

  Future<_PreparedImage?> _prepareCoverImage(String inputPath) async {
    return _cropCapturedImage(path: inputPath, title: 'Ajuster la couverture');
  }

  Future<void> _processSelectedBytes({
    required Uint8List bytes,
    required String filename,
    required String extension,
    required ScanIntent intent,
    String? bookId,
    String? bookTitre,
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
      final storageRef = _storage.ref('scans/$uid/${timestamp}_$filename');
      final uploadTask = storageRef.putData(
        bytes,
        SettableMetadata(contentType: mimeType),
      );
      uploadTask.snapshotEvents.listen((snap) {
        final progress =
            snap.bytesTransferred / (snap.totalBytes > 0 ? snap.totalBytes : 1);
        state = state.copyWith(uploadProgress: progress);
      });
      final snapshot = await uploadTask;
      storageUrl = await snapshot.ref.getDownloadURL();
    } catch (e) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Échec de l\'envoi du fichier : $e',
      );
      return;
    }

    // 2. Cree le job puis lance son traitement en arriere-plan.
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
      bookId: bookId,
      bookTitre: bookTitre,
    );

    final jobId = await _jobsRepo.createJob(job);
    state = state.copyWith(
      status: ScanStatus.done,
      uploadProgress: 1,
      queuedJobId: jobId,
      createdRecipeIds: const [],
      createdBookId: null,
      successMessage: _queuedMessage(intent),
    );

    unawaited(
      _processJob(
        jobId: jobId,
        intent: intent,
        bytes: bytes,
        mimeType: mimeType,
        fileName: filename,
        fileUrl: storageUrl,
        uid: uid,
        bookId: bookId,
        bookTitre: bookTitre,
      ),
    );
  }

  Future<void> _processJob({
    required String jobId,
    required ScanIntent intent,
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
    required String fileUrl,
    required String uid,
    String? bookId,
    String? bookTitre,
  }) async {
    try {
      await _jobsRepo.updateJob(jobId, {
        'status': ProcessingJobStatus.processing.name,
        'error_message': null,
      });

      final gemini = GeminiService(_geminiApiKey);

      switch (intent) {
        case ScanIntent.recipe:
          final recipeIds = await _processRecipeExtraction(
            gemini: gemini,
            bytes: bytes,
            mimeType: mimeType,
            uid: uid,
            fileName: fileName,
            fileUrl: fileUrl,
            bookId: bookId,
            bookTitre: bookTitre,
          );
          await _jobsRepo.updateJob(jobId, {
            'status': ProcessingJobStatus.done.name,
            'created_recipe_ids': recipeIds,
          });
          break;
        case ScanIntent.bookCover:
          final createdBookId = await _processBookCoverExtraction(
            gemini: gemini,
            bytes: bytes,
            mimeType: mimeType,
            uid: uid,
            fileName: fileName,
            fileUrl: fileUrl,
          );
          await _jobsRepo.updateJob(jobId, {
            'status': ProcessingJobStatus.done.name,
            'created_book_id': createdBookId,
          });
          break;
        case ScanIntent.bookDocument:
          final recipeIds = await _processRecipeExtraction(
            gemini: gemini,
            bytes: bytes,
            mimeType: mimeType,
            uid: uid,
            fileName: fileName,
            fileUrl: fileUrl,
            bookId: bookId,
            bookTitre: bookTitre,
          );
          await _jobsRepo.updateJob(jobId, {
            'status': ProcessingJobStatus.done.name,
            'created_recipe_ids': recipeIds,
          });
          break;
      }

      await _usage.recordScan(fileBytes: bytes.length);
    } catch (e) {
      await _jobsRepo.updateJob(jobId, {
        'status': ProcessingJobStatus.error.name,
        'error_message': '$e',
      });
    }
  }

  Future<List<String>> _processRecipeExtraction({
    required GeminiService gemini,
    required Uint8List bytes,
    required String mimeType,
    required String uid,
    required String fileName,
    required String fileUrl,
    String? bookId,
    String? bookTitre,
  }) async {
    final recipes = await gemini.extractRecipes(bytes, mimeType);
    if (recipes.isEmpty) {
      throw StateError('Aucune recette détectée dans ce fichier.');
    }

    final now = DateTime.now();
    final ids = <String>[];
    for (final cooklang in recipes) {
      final titre = extractTitle(cooklang);
      final ingredients = extractIngredients(cooklang);
      final ingredientsStructured = extractIngredientsStructured(cooklang);
      final portions = extractPortions(cooklang);
      final pageNumber = extractPageNumber(cooklang);
      final tags = extractRecipeTags(cooklang);

      final recipe = Recipe(
        id: '',
        titre: titre,
        bookId: bookId,
        bookTitre: bookTitre,
        pageNumber: pageNumber,
        langue: 'fr',
        rawCooklang: '',
        draftCooklang: cooklang,
        imageUrls: [],
        reviewStatus: ReviewStatus.draft,
        tags: tags,
        ingredientsIndex: ingredients,
        ingredients: ingredientsStructured,
        portions: portions,
        createdBy: uid,
        createdAt: now,
        updatedAt: now,
        sourceFileUrl: fileUrl,
        sourceFileName: fileName,
        aiProcessedAt: now,
      );

      ids.add(await _recipeRepo.createRecipe(recipe));
    }
    return ids;
  }

  Future<String> _processBookCoverExtraction({
    required GeminiService gemini,
    required Uint8List bytes,
    required String mimeType,
    required String uid,
    required String fileName,
    required String fileUrl,
  }) async {
    final extracted = await gemini.extractBookCover(bytes, mimeType);
    final now = DateTime.now();

    final book = Book(
      id: '',
      titre: extracted.titre,
      sousTitre: extracted.sousTitre,
      editeur: extracted.editeur,
      serie: extracted.serie,
      auteur: extracted.auteur,
      annee: extracted.annee,
      langue: extracted.langue,
      isbn: extracted.isbn,
      description: extracted.description,
      urlCouverture: fileUrl,
      tags: extracted.tags,
      reviewStatus: BookReviewStatus.draft,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      sourceFileUrl: fileUrl,
      sourceFileName: fileName,
      aiProcessedAt: now,
    );

    return _bookRepo.createBook(book);
  }

  void reset() => state = const ScanState();

  /// Relance un job existant depuis son fichier déjà stocké dans Firebase Storage.
  Future<void> retryJob(ProcessingJob job) async {
    if (job.isActive) return; // déjà en cours

    // Réinitialise le job dans Firestore
    await _jobsRepo.updateJob(job.id, {
      'status': ProcessingJobStatus.queued.name,
      'error_message': null,
      'created_recipe_ids': [],
      'created_book_id': null,
    });

    // Re-télécharge les octets depuis Firebase Storage
    Uint8List? bytes;
    try {
      final ref = _storage.refFromURL(job.fileUrl);
      bytes = await ref.getData(50 * 1024 * 1024); // 50 Mo max
    } catch (e) {
      await _jobsRepo.updateJob(job.id, {
        'status': ProcessingJobStatus.error.name,
        'error_message': 'Impossible de télécharger le fichier source : $e',
      });
      return;
    }

    if (bytes == null || bytes.isEmpty) {
      await _jobsRepo.updateJob(job.id, {
        'status': ProcessingJobStatus.error.name,
        'error_message': 'Le fichier source est vide ou introuvable.',
      });
      return;
    }

    final uid = _auth.currentUser?.uid ?? job.createdBy;
    unawaited(
      _processJob(
        jobId: job.id,
        intent: _jobTypeToIntent(job.type),
        bytes: bytes,
        mimeType: job.mimeType ?? 'image/jpeg',
        fileName: job.fileName,
        fileUrl: job.fileUrl,
        uid: uid,
        bookId: job.bookId,
        bookTitre: job.bookTitre,
      ),
    );
  }

  ScanIntent _jobTypeToIntent(ProcessingJobType type) => switch (type) {
    ProcessingJobType.recipeScan => ScanIntent.recipe,
    ProcessingJobType.bookCoverScan => ScanIntent.bookCover,
    ProcessingJobType.bookDocumentScan => ScanIntent.bookDocument,
  };

  ProcessingJobType _mapIntentToJobType(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe => ProcessingJobType.recipeScan,
    ScanIntent.bookCover => ProcessingJobType.bookCoverScan,
    ScanIntent.bookDocument => ProcessingJobType.bookDocumentScan,
  };

  String _queuedMessage(ScanIntent intent) => switch (intent) {
    ScanIntent.recipe =>
      'Scan recette ajoute a la file de traitement. Continuez a importer sans attendre.',
    ScanIntent.bookCover =>
      'Scan de couverture ajoute. Le livre sera cree puis disponible dans Livres a valider.',
    ScanIntent.bookDocument =>
      'Document livre ajoute. Les recettes extraites seront rattachees au livre cible.',
  };
}

String _fileNameFromPath(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final idx = slash > backslash ? slash : backslash;
  return idx >= 0 ? path.substring(idx + 1) : path;
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
