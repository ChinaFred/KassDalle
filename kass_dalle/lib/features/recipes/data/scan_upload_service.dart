import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/services/usage_tracker.dart';
import '../../../features/admin/data/token_usage_repository.dart';
import '../../books/data/book_repository.dart';
import '../../books/domain/book.dart';
import '../../processing/data/processing_job_repository.dart';
import '../../processing/domain/processing_job.dart';
import '../data/recipe_repository.dart';
import '../domain/recipe.dart';
import '../../../core/app_version.dart';
import '../../../core/services/error_report_service.dart';
import 'scan_state.dart';
export 'scan_state.dart';

// ── Notifier ───────────────────────────────────────────────────────────────────────

class ScanUploadNotifier extends Notifier<ScanState> {
  late final RecipeRepository _recipeRepo;
  late final BookRepository _bookRepo;
  late final ProcessingJobRepository _jobsRepo;
  late final FirebaseStorage _storage;
  late final FirebaseAuth _auth;
  late final UsageTracker _usage;
  final ImagePicker _imagePicker = ImagePicker();

  /// Pages accumulées en mode multi-page (non persistées dans state pour éviter
  /// de mettre de gros Uint8List dans le state Riverpod).
  final List<_PendingPage> _pendingPages = [];

  /// File d'attente séquentielle pour les appels à l'API Gemini.
  /// Garantit qu'un seul job est traité à la fois pour éviter les erreurs
  /// de connexion lors d'imports en chaîne rapide.
  Future<void> _jobQueue = Future.value();

  /// IDs des jobs manuellement annulés — utilisés pour court-circuiter
  /// _processJob si le Future tourne encore en arrière-plan après un cancelJob.
  final Set<String> _cancelledJobIds = {};

  @override
  ScanState build() {
    _recipeRepo = RecipeRepository();
    _bookRepo = BookRepository();
    _jobsRepo = ProcessingJobRepository();
    _storage = FirebaseStorage.instance;
    _auth = FirebaseAuth.instance;
    _usage = UsageTracker();
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
    } catch (_) {}
  }

  /// Ajoute une page supplémentaire depuis la caméra.
  Future<void> addPageFromCamera() async {
    try {
      final photo = await _imagePicker.pickImage(
        source: ImageSource.camera,
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
    } catch (_) {}
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
    } catch (e) {
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
          final ts = DateTime.now().millisecondsSinceEpoch;
          final ref = _storage.ref('scans/$uid/${ts}_p${i + 2}_$safeFilename');
          final snap = await ref.putData(
            p.bytes,
            SettableMetadata(contentType: p.mimeType),
          );
          pageUrl = await snap.ref.getDownloadURL();
        } catch (_) {
          // Deuxième tentative ou abandon
        }
      }
      if (pageUrl != null) {
        additionalStorageUrls.add(pageUrl);
      }
    }

    // 3. Crée le job puis lance son traitement en arrière-plan.
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
      additionalFileUrls: additionalStorageUrls,
    );

    final jobId = await _jobsRepo.createJob(job);
    _pendingPages.clear();
    state = state.copyWith(
      status: ScanStatus.done,
      uploadProgress: 1,
      queuedJobId: jobId,
      createdRecipeIds: const [],
      createdBookId: null,
      successMessage: _queuedMessage(intent),
      pendingPageNames: const [],
    );

    // Le traitement du job est désormais effectué côté backend (Cloud Tasks +
    // recipeProcessor). Le trigger Firestore onCreate sur processing_jobs
    // déclenche le pipeline asynchrone. Le client se contente d'écouter le
    // document pour les mises à jour de statut.
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
    List<({Uint8List bytes, String mimeType})> additionalPageBytes = const [],
    List<String> additionalPageUrls = const [],
  }) async {
    // Si le job a été annulé manuellement avant même de démarrer, on sort proprement.
    if (_cancelledJobIds.contains(jobId)) {
      _cancelledJobIds.remove(jobId);
      return;
    }
    try {
      await _jobsRepo.updateJob(jobId, {
        'status': ProcessingJobStatus.processing.name,
        'error_message': null,
      });

      final tokenRepo = TokenUsageRepository();
      final gemini = GeminiService(
        '',
        onTokenUsage: TokenUsageRepository.makeCallback(uid, tokenRepo),
      );

      switch (intent) {
        case ScanIntent.recipe:
          await _jobsRepo.updateJob(jobId, {
            'current_step': 'Extraction du texte…',
          });
          final recipeIds = await _processRecipeExtraction(
            gemini: gemini,
            bytes: bytes,
            mimeType: mimeType,
            uid: uid,
            fileName: fileName,
            fileUrl: fileUrl,
            bookId: bookId,
            bookTitre: bookTitre,
            additionalPages: additionalPageBytes,
            additionalPageUrls: additionalPageUrls,
            jobId: jobId,
          );
          await _jobsRepo.updateJob(jobId, {
            'status': ProcessingJobStatus.done.name,
            'created_recipe_ids': recipeIds,
            'current_step': null,
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
          await _jobsRepo.updateJob(jobId, {
            'current_step': 'Extraction du texte…',
          });
          final recipeIds2 = await _processRecipeExtraction(
            gemini: gemini,
            bytes: bytes,
            mimeType: mimeType,
            uid: uid,
            fileName: fileName,
            fileUrl: fileUrl,
            bookId: bookId,
            bookTitre: bookTitre,
            jobId: jobId,
          );
          await _jobsRepo.updateJob(jobId, {
            'status': ProcessingJobStatus.done.name,
            'created_recipe_ids': recipeIds2,
            'current_step': null,
          });
          break;
      }

      await _usage.recordScan(fileBytes: bytes.length);
    } catch (e, st) {
      final errorReportSvc = ErrorReportService();
      final errorId = await errorReportSvc.save(
        userId: uid,
        jobId: jobId,
        feature: 'processJob:${intent.name}',
        error: e,
        stackTrace: st,
        context: {
          'filename': fileName,
          'mime_type': mimeType,
          'file_size_bytes': bytes.length,
          'additional_pages': additionalPageBytes.length,
          'intent': intent.name,
          if (bookId != null) 'book_id': bookId,
          if (bookTitre != null) 'book_titre': bookTitre,
          'app_version': kAppVersion,
        },
      );
      await _jobsRepo.updateJob(jobId, {
        'status': ProcessingJobStatus.error.name,
        'error_message': '$e\n\nCode erreur : $errorId',
        'error_id': errorId,
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
    List<({Uint8List bytes, String mimeType})> additionalPages = const [],
    List<String> additionalPageUrls = const [],
    String? jobId,
  }) async {
    final recipes = await gemini.extractRecipes(
      bytes,
      mimeType,
      additionalPages: additionalPages,
    );
    // Gemini a retourné NO_RECIPE (liste vide) : aucun contenu utile détecté
    if (recipes.isEmpty) return [];

    final now = DateTime.now();
    final ids = <String>[];
    for (final cooklang in recipes) {
      final pageType = extractPageType(cooklang);
      final pageNumber = extractPageNumber(cooklang);

      if (pageType != PageType.recipe) {
        // Page non-recette : on stocke le texte extrait (sans métadonnées)
        final titre = extractTitle(cooklang);
        final textContent = stripCooklangMeta(cooklang);
        final recipe = Recipe(
          id: '',
          titre: titre.isEmpty || titre == 'Recette sans titre'
              ? 'Page sans titre'
              : titre,
          bookId: bookId,
          bookTitre: bookTitre,
          pageNumber: pageNumber,
          langue: 'fr',
          rawCooklang: '',
          draftCooklang: textContent,
          imageUrls: [],
          reviewStatus: ReviewStatus.draft,
          tags: const RecipeTags(),
          ingredientsIndex: const [],
          ingredients: const [],
          portions: null,
          createdBy: uid,
          createdAt: now,
          updatedAt: now,
          sourceFileUrl: fileUrl,
          sourceFileName: fileName,
          additionalSourceFileUrls: additionalPageUrls,
          aiProcessedAt: now,
          pageType: pageType,
          importVersion: kAppVersion,
        );
        ids.add(await _recipeRepo.createRecipe(recipe));
        continue;
      }

      // Page recette : logique existante
      final titre = extractTitle(cooklang);
      final ingredients = extractIngredients(cooklang);
      final ingredientsStructured = extractIngredientsStructured(cooklang);
      final portions = extractPortions(cooklang);
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
        additionalSourceFileUrls: additionalPageUrls,
        aiProcessedAt: now,
        importVersion: kAppVersion,
      );

      ids.add(await _recipeRepo.createRecipe(recipe));
    }

    // Extraction des illustrations (page primaire + pages supplémentaires)
    final allIllustrationUrls = <String>[];

    if (mimeType == 'image/jpeg' || mimeType == 'image/png') {
      if (jobId != null) {
        await _jobsRepo.updateJob(jobId, {
          'current_step': 'Extraction des illustrations…',
        });
      }
      try {
        var regions = await gemini.detectIllustrationRegions(bytes, mimeType);
        // Repli : si aucune région détectée, tentative avec un prompt plus direct
        if (regions.isEmpty) {
          final singleBox = await gemini.detectMainCulinaryPhoto(
            bytes,
            mimeType,
          );
          if (singleBox != null) regions = [singleBox];
        }
        if (regions.isNotEmpty) {
          final srcImage = img.decodeImage(bytes);
          if (srcImage != null) {
            for (var i = 0; i < regions.length; i++) {
              final box = regions[i]; // [yMin, xMin, yMax, xMax]
              final x = (box[1] * srcImage.width / 1000).round();
              final y = (box[0] * srcImage.height / 1000).round();
              final w = ((box[3] - box[1]) * srcImage.width / 1000).round();
              final h = ((box[2] - box[0]) * srcImage.height / 1000).round();
              if (w <= 50 || h <= 50) continue;
              final cropped = img.copyCrop(
                srcImage,
                x: x,
                y: y,
                width: w,
                height: h,
              );
              final croppedBytes = Uint8List.fromList(
                img.encodeJpg(cropped, quality: 85),
              );
              try {
                final ts = DateTime.now().millisecondsSinceEpoch;
                final ref = _storage.ref('illustrations/$uid/${ts}_ill_$i.jpg');
                final snap = await ref.putData(
                  croppedBytes,
                  SettableMetadata(contentType: 'image/jpeg'),
                );
                allIllustrationUrls.add(await snap.ref.getDownloadURL());
              } catch (_) {}
            }
          }
        }
      } catch (_) {} // illustrations non bloquantes
    }

    // Pages supplémentaires : extraction des illustrations (ou pleine page si photo entière)
    for (int pageIdx = 0; pageIdx < additionalPages.length; pageIdx++) {
      final page = additionalPages[pageIdx];
      if (page.mimeType != 'image/jpeg' && page.mimeType != 'image/png') {
        continue;
      }
      try {
        final pageImage = img.decodeImage(page.bytes);
        if (pageImage == null) continue;
        final pageRegions = await gemini.detectIllustrationRegions(
          page.bytes,
          page.mimeType,
        );
        if (pageRegions.isNotEmpty) {
          for (var i = 0; i < pageRegions.length; i++) {
            final box = pageRegions[i];
            final x = (box[1] * pageImage.width / 1000).round();
            final y = (box[0] * pageImage.height / 1000).round();
            final w = ((box[3] - box[1]) * pageImage.width / 1000).round();
            final h = ((box[2] - box[0]) * pageImage.height / 1000).round();
            if (w <= 50 || h <= 50) continue;
            final cropped = img.copyCrop(
              pageImage,
              x: x,
              y: y,
              width: w,
              height: h,
            );
            final croppedBytes = Uint8List.fromList(
              img.encodeJpg(cropped, quality: 85),
            );
            try {
              final ts = DateTime.now().millisecondsSinceEpoch;
              final ref = _storage.ref(
                'illustrations/$uid/${ts}_p${pageIdx + 2}_ill_$i.jpg',
              );
              final snap = await ref.putData(
                croppedBytes,
                SettableMetadata(contentType: 'image/jpeg'),
              );
              allIllustrationUrls.add(await snap.ref.getDownloadURL());
            } catch (_) {}
          }
        } else {
          // Aucune région détectée : la page entière est probablement une photo
          // culinaire ajoutée intentionnellement — on l'utilise directement.
          try {
            final ts = DateTime.now().millisecondsSinceEpoch;
            final ref = _storage.ref(
              'illustrations/$uid/${ts}_p${pageIdx + 2}_full.jpg',
            );
            final snap = await ref.putData(
              page.bytes,
              SettableMetadata(contentType: page.mimeType),
            );
            allIllustrationUrls.add(await snap.ref.getDownloadURL());
          } catch (_) {}
        }
      } catch (_) {} // non bloquant
    }

    if (allIllustrationUrls.isNotEmpty) {
      for (final id in ids) {
        await _recipeRepo.updateRecipeIllustrations(id, allIllustrationUrls);
      }
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

    // Télécharge les pages supplémentaires si disponibles
    final additionalPageBytes = <({Uint8List bytes, String mimeType})>[];
    for (final url in job.additionalFileUrls) {
      try {
        final ref = _storage.refFromURL(url);
        final b = await ref.getData(50 * 1024 * 1024);
        if (b != null && b.isNotEmpty) {
          additionalPageBytes.add((
            bytes: b,
            mimeType: job.mimeType ?? 'image/jpeg',
          ));
        }
      } catch (_) {}
    }

    _jobQueue = _jobQueue.then(
      (_) =>
          _processJob(
            jobId: job.id,
            intent: _jobTypeToIntent(job.type),
            bytes: bytes!,
            mimeType: job.mimeType ?? 'image/jpeg',
            fileName: job.fileName,
            fileUrl: job.fileUrl,
            uid: uid,
            bookId: job.bookId,
            bookTitre: job.bookTitre,
            additionalPageBytes: additionalPageBytes,
            additionalPageUrls: job.additionalFileUrls,
          ).timeout(
            const Duration(minutes: 8),
            onTimeout: () async {
              await _jobsRepo.updateJob(job.id, {
                'status': ProcessingJobStatus.error.name,
                'error_message':
                    'Traitement interrompu : délai dépassé (8 min). '
                    'Réessayez ou vérifiez le document.',
              });
            },
          ),
    );
  }

  ScanIntent _jobTypeToIntent(ProcessingJobType type) => switch (type) {
    ProcessingJobType.recipeScan => ScanIntent.recipe,
    ProcessingJobType.bookCoverScan => ScanIntent.bookCover,
    ProcessingJobType.bookDocumentScan => ScanIntent.bookDocument,
  };

  /// Force l'arrêt d'un job bloqué en le marquant comme erreur dans Firestore.
  /// Réinitialise aussi la file d'attente pour que les prochains jobs puissent
  /// démarrer immédiatement sans attendre que le Future bloqué se termine.
  Future<void> cancelJob(String jobId) async {
    _cancelledJobIds.add(jobId);
    // Réinitialiser la queue : les nouveaux jobs ne seront plus bloqués derrière
    // le Future en cours (qui continuera en arrière-plan jusqu'à son timeout).
    _jobQueue = Future.value();
    await _jobsRepo.updateJob(jobId, {
      'status': ProcessingJobStatus.error.name,
      'error_message': 'Job annulé manuellement.',
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
      'Scan de couverture ajoute. Le livre sera cree puis disponible dans Livres a valider.',
    ScanIntent.bookDocument =>
      'Document livre ajoute. Les recettes extraites seront rattachees au livre cible.',
  };
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
