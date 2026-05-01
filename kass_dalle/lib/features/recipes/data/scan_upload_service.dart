import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/services/usage_tracker.dart';
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

class ScanState {
  final ScanStatus status;
  final String? filename;
  final double uploadProgress;
  final String? errorMessage;
  final List<String> createdRecipeIds;

  const ScanState({
    this.status = ScanStatus.idle,
    this.filename,
    this.uploadProgress = 0,
    this.errorMessage,
    this.createdRecipeIds = const [],
  });

  ScanState copyWith({
    ScanStatus? status,
    String? filename,
    double? uploadProgress,
    String? errorMessage,
    List<String>? createdRecipeIds,
  }) {
    return ScanState(
      status: status ?? this.status,
      filename: filename ?? this.filename,
      uploadProgress: uploadProgress ?? this.uploadProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      createdRecipeIds: createdRecipeIds ?? this.createdRecipeIds,
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
  final FirebaseStorage _storage;
  final FirebaseAuth _auth;
  final UsageTracker _usage;
  final ImagePicker _imagePicker = ImagePicker();

  ScanUploadNotifier(this._recipeRepo, this._storage, this._auth, this._usage)
    : super(const ScanState());

  /// Ouvre le file picker, upload, appelle Gemini, crée les brouillons.
  Future<void> pickAndProcess({String? bookId, String? bookTitre}) async {
    if (_geminiApiKey.isEmpty) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage:
            'Clé API Gemini non configurée.\nLancez l\'app avec : flutter run --dart-define=GEMINI_API_KEY=votre_clé',
      );
      return;
    }

    // 1. Sélection du fichier
    state = state.copyWith(status: ScanStatus.picking);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'docx', 'jpg', 'jpeg', 'png'],
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

  /// Ouvre l'appareil photo, puis applique le même pipeline d'upload + IA.
  Future<void> pickFromCameraAndProcess({
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

      final bytes = await photo.readAsBytes();
      await _processSelectedBytes(
        bytes: bytes,
        filename: _fileNameFromPath(photo.path),
        extension: _extensionFromPath(photo.path),
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
    String? bookId,
    String? bookTitre,
  }) async {
    final mimeType = _mimeTypeFor(extension);

    state = state.copyWith(
      status: ScanStatus.uploading,
      filename: filename,
      uploadProgress: 0,
    );

    // 2. Upload vers Firebase Storage
    String? storageUrl;
    try {
      final uid = _auth.currentUser!.uid;
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

    // 3. Analyse Gemini
    state = state.copyWith(status: ScanStatus.processing, uploadProgress: 1);
    List<String> recipes;
    try {
      final gemini = GeminiService(_geminiApiKey);
      recipes = await gemini.extractRecipes(bytes, mimeType);
    } catch (e) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Erreur lors de l\'analyse IA : $e',
      );
      return;
    }

    if (recipes.isEmpty) {
      state = state.copyWith(
        status: ScanStatus.error,
        errorMessage: 'Aucune recette détectée dans ce fichier.',
      );
      return;
    }

    // 4. Création des brouillons dans Firestore
    final uid = _auth.currentUser!.uid;
    final now = DateTime.now();
    final ids = <String>[];

    for (final cooklang in recipes) {
      final titre = extractTitle(cooklang);
      final ingredients = extractIngredients(cooklang);
      final ingredientsStructured = extractIngredientsStructured(cooklang);
      final portions = extractPortions(cooklang);

      final recipe = Recipe(
        id: '',
        titre: titre,
        bookId: bookId,
        bookTitre: bookTitre,
        langue: 'fr',
        rawCooklang: '',
        draftCooklang: cooklang,
        imageUrls: [],
        reviewStatus: ReviewStatus.draft,
        tags: const RecipeTags(),
        ingredientsIndex: ingredients,
        ingredients: ingredientsStructured,
        portions: portions,
        createdBy: uid,
        createdAt: now,
        updatedAt: now,
        sourceFileUrl: storageUrl,
        sourceFileName: filename,
        aiProcessedAt: now,
      );

      final id = await _recipeRepo.createRecipe(recipe);
      ids.add(id);
    }

    state = state.copyWith(status: ScanStatus.done, createdRecipeIds: ids);

    // Enregistre l'usage (compteur mensuel scans + octets stockés)
    await _usage.recordScan(fileBytes: bytes.length);
  }

  void reset() => state = const ScanState();
}

String _fileNameFromPath(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf('\\');
  final idx = slash > backslash ? slash : backslash;
  return idx >= 0 ? path.substring(idx + 1) : path;
}

String _extensionFromPath(String path) {
  final name = _fileNameFromPath(path);
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return 'jpg';
  return name.substring(dot + 1);
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
