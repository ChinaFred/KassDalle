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

/// Un import en cours d'envoi, vu de l'écran.
///
/// L'envoi et le contrôle de sécurité prenaient l'écran entier : les boutons
/// disparaissaient le temps de ces quelques secondes, et il fallait attendre
/// pour préparer l'import suivant. Le vrai travail — l'extraction — se fait
/// déjà en file, sans bloquer personne ; il n'y avait aucune raison que ses
/// deux premières secondes, elles, verrouillent tout.
///
/// Un import en vol vit donc **à côté** de l'état de l'écran, et non à sa
/// place. Plusieurs peuvent voler ensemble.
class ActiveImport {
  /// Identifiant local, le temps du vol. Rien à voir avec le job serveur, qui
  /// n'existe pas encore.
  final String id;
  final String filename;
  final ScanIntent intent;
  final ScanUploadPhase phase;

  /// Progression de l'envoi, 0 à 1. N'a de sens qu'en phase d'envoi.
  final double progress;

  const ActiveImport({
    required this.id,
    required this.filename,
    required this.intent,
    required this.phase,
    this.progress = 0,
  });

  ActiveImport copyWith({ScanUploadPhase? phase, double? progress}) =>
      ActiveImport(
        id: id,
        filename: filename,
        intent: intent,
        phase: phase ?? this.phase,
        progress: progress ?? this.progress,
      );

  String get label => switch (phase) {
    ScanUploadPhase.uploading => 'Envoi',
    ScanUploadPhase.scanning => 'Contrôle de sécurité',
    ScanUploadPhase.queueing => 'Mise en file',
  };
}

/// Les trois temps d'un import, avant que la file ne prenne le relais.
enum ScanUploadPhase { uploading, scanning, queueing }

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

  /// Les imports en cours d'envoi.
  ///
  /// Ils ne dictent **pas** [status] : c'est ce qui permet aux boutons de
  /// rester disponibles pendant qu'un envoi se termine.
  final List<ActiveImport> activeImports;

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
    this.activeImports = const [],
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
    List<ActiveImport>? activeImports,
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
      activeImports: activeImports ?? this.activeImports,
    );
  }

  /// Un envoi est en vol. Sert à **afficher** la progression, jamais à cacher
  /// les boutons : c'est toute la différence avec [isRunning].
  bool get hasActiveImports => activeImports.isNotEmpty;

  /// L'écran attend une réponse qu'il ne peut pas doubler : un sélecteur de
  /// fichier ouvert, ou une image en cours d'amélioration. L'envoi, lui, n'en
  /// fait plus partie — il se poursuit pendant qu'on prépare le suivant.
  bool get isRunning =>
      status == ScanStatus.picking || status == ScanStatus.pendingEnhancement;

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
