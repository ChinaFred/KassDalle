import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:image/image.dart' as img;

import '../../../core/app_version.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/services/usage_tracker.dart';
import '../../../features/admin/data/token_usage_repository.dart';
import '../../books/data/book_repository.dart';
import '../../books/domain/book.dart';
import '../../processing/data/processing_job_repository.dart';
import '../../processing/domain/processing_job.dart';
import '../data/recipe_repository.dart';
import '../domain/recipe.dart';
import 'scan_state.dart';

/// Traite un [ProcessingJob] : appelle Gemini via Cloud Functions et persiste
/// les [Recipe] / [Book] résultants dans Firestore.
///
/// Extrait de [ScanUploadNotifier] pour isoler la logique IA de la gestion
/// d'état et d'upload.
class ScanJobProcessor {
  final RecipeRepository _recipeRepo;
  final BookRepository _bookRepo;
  final ProcessingJobRepository _jobsRepo;
  final FirebaseStorage _storage;
  final UsageTracker _usage;

  ScanJobProcessor({
    required RecipeRepository recipeRepo,
    required BookRepository bookRepo,
    required ProcessingJobRepository jobsRepo,
    required FirebaseStorage storage,
    required UsageTracker usage,
  })  : _recipeRepo = recipeRepo,
        _bookRepo = bookRepo,
        _jobsRepo = jobsRepo,
        _storage = storage,
        _usage = usage;

  /// Traite un job et met à jour son statut Firestore.
  ///
  /// [cancelledJobIds] — set partagé avec [ScanUploadNotifier] ; si le job
  /// est présent dans ce set avant de démarrer, on sort proprement et on retire
  /// son ID.
  Future<void> processJob({
    required String jobId,
    required ScanIntent intent,
    required Uint8List bytes,
    required String mimeType,
    required String fileName,
    required String fileUrl,
    required String uid,
    required Set<String> cancelledJobIds,
    String? bookId,
    String? bookTitre,
    List<({Uint8List bytes, String mimeType})> additionalPageBytes = const [],
    List<String> additionalPageUrls = const [],
  }) async {
    if (cancelledJobIds.contains(jobId)) {
      cancelledJobIds.remove(jobId);
      return;
    }
    try {
      await _jobsRepo.updateJob(jobId, {
        'status': ProcessingJobStatus.processing.name,
        'error_message': null,
      });

      final tokenRepo = TokenUsageRepository();
      final gemini = GeminiService(
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
          'book_id': ?bookId,
          'book_titre': ?bookTitre,
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
    if (recipes.isEmpty) return [];

    final now = DateTime.now();
    final ids = <String>[];
    for (final cooklang in recipes) {
      final pageType = extractPageType(cooklang);
      final pageNumber = extractPageNumber(cooklang);

      if (pageType != PageType.recipe) {
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
                final ref =
                    _storage.ref('illustrations/$uid/${ts}_ill_$i.jpg');
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

    // Pages supplémentaires : extraction des illustrations
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
          // culinaire ajoutée intentionnellement.
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
}
