import 'dart:typed_data';

// ── État du scan ──────────────────────────────────────────────────────────────

enum ScanStatus {
  idle,
  picking,
  pendingEnhancement,
  pendingFiles, // pages accumulées en attente de traitement
  uploading,
  scanning,
  processing,
  done,
  error,
}

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

  /// Bytes de l'image en attente d'amélioration (état pendingEnhancement).
  final Uint8List? pendingImageBytes;
  final String? pendingImageFilename;

  /// Noms des fichiers accumulés en mode multi-page (état pendingFiles).
  final List<String> pendingPageNames;

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
    this.pendingImageBytes,
    this.pendingImageFilename,
    this.pendingPageNames = const [],
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
    Uint8List? pendingImageBytes,
    String? pendingImageFilename,
    List<String>? pendingPageNames,
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
      pendingImageBytes: pendingImageBytes ?? this.pendingImageBytes,
      pendingImageFilename: pendingImageFilename ?? this.pendingImageFilename,
      pendingPageNames: pendingPageNames ?? this.pendingPageNames,
    );
  }

  bool get isRunning =>
      status == ScanStatus.picking ||
      status == ScanStatus.pendingEnhancement ||
      status == ScanStatus.uploading ||
      status == ScanStatus.scanning ||
      status == ScanStatus.processing;

  String get statusLabel => switch (status) {
    ScanStatus.idle => 'Prêt',
    ScanStatus.picking => 'Sélection du fichier…',
    ScanStatus.pendingEnhancement => 'Améliorez l\'image…',
    ScanStatus.pendingFiles => 'Pages en attente',
    ScanStatus.uploading => 'Envoi en cours…',
    ScanStatus.scanning => 'Scanner les fichiers…',
    ScanStatus.processing => 'Analyse IA en cours…',
    ScanStatus.done => 'Terminé',
    ScanStatus.error => 'Erreur',
  };
}
