enum ProcessingJobType { recipeScan, bookCoverScan, bookDocumentScan }

enum ProcessingJobStatus { queued, processing, done, error, rejected }

class ProcessingJob {
  final String id;
  final ProcessingJobType type;
  final ProcessingJobStatus status;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  final String fileName;
  final String fileUrl;
  final String? mimeType;

  final String? bookId;
  final String? bookTitre;

  final List<String> createdRecipeIds;
  final String? createdBookId;
  final String? errorMessage;

  /// URLs des pages supplémentaires (multi-page scan).
  final List<String> additionalFileUrls;

  /// Étape courante du traitement (ex: 'Extraction du texte…').
  final String? currentStep;

  /// ID du rapport d'erreur dans la collection error_reports (si status == error).
  final String? errorId;

  /// Extraire les illustrations de la page importée.
  ///
  /// Le choix voyage avec le job, pas avec le compte : le serveur traite ce job
  /// après coup, et la préférence a pu changer entre-temps. Ce qui a été demandé
  /// au moment de l'import est ce qui doit être fait.
  final bool importIllustrations;

  const ProcessingJob({
    required this.id,
    required this.type,
    required this.status,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    required this.fileName,
    required this.fileUrl,
    this.mimeType,
    this.bookId,
    this.bookTitre,
    this.createdRecipeIds = const [],
    this.createdBookId,
    this.errorMessage,
    this.additionalFileUrls = const [],
    this.currentStep,
    this.errorId,
    this.importIllustrations = false,
  });

  factory ProcessingJob.fromFirestore(String id, Map<String, dynamic> data) {
    return ProcessingJob(
      id: id,
      type: ProcessingJobType.values.firstWhere(
        (e) => e.name == (data['type'] as String? ?? 'recipeScan'),
        orElse: () => ProcessingJobType.recipeScan,
      ),
      status: ProcessingJobStatus.values.firstWhere(
        (e) => e.name == (data['status'] as String? ?? 'queued'),
        orElse: () => ProcessingJobStatus.queued,
      ),
      createdBy: data['created_by'] as String,
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      updatedAt: (data['updated_at'] as dynamic).toDate() as DateTime,
      fileName: data['file_name'] as String? ?? 'fichier',
      fileUrl: data['file_url'] as String? ?? '',
      mimeType: data['mime_type'] as String?,
      bookId: data['book_id'] as String?,
      bookTitre: data['book_titre'] as String?,
      createdRecipeIds: List<String>.from(
        data['created_recipe_ids'] as List? ?? [],
      ),
      createdBookId: data['created_book_id'] as String?,
      errorMessage: data['error_message'] as String?,
      additionalFileUrls: List<String>.from(
        data['additional_file_urls'] as List? ?? [],
      ),
      currentStep: data['current_step'] as String?,
      errorId: data['error_id'] as String?,
      importIllustrations: data['import_illustrations'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'type': type.name,
      'status': status.name,
      'created_by': createdBy,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'file_name': fileName,
      'file_url': fileUrl,
      'mime_type': mimeType,
      'book_id': bookId,
      'book_titre': bookTitre,
      'created_recipe_ids': createdRecipeIds,
      'created_book_id': createdBookId,
      'error_message': errorMessage,
      'additional_file_urls': additionalFileUrls,
      if (currentStep != null) 'current_step': currentStep,
      if (errorId != null) 'error_id': errorId,
      'import_illustrations': importIllustrations,
    };
  }

  ProcessingJob copyWith({
    ProcessingJobStatus? status,
    DateTime? updatedAt,
    List<String>? createdRecipeIds,
    String? createdBookId,
    String? errorMessage,
    List<String>? additionalFileUrls,
    String? currentStep,
    String? errorId,
  }) {
    return ProcessingJob(
      id: id,
      type: type,
      status: status ?? this.status,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      fileName: fileName,
      fileUrl: fileUrl,
      mimeType: mimeType,
      bookId: bookId,
      bookTitre: bookTitre,
      createdRecipeIds: createdRecipeIds ?? this.createdRecipeIds,
      createdBookId: createdBookId ?? this.createdBookId,
      errorMessage: errorMessage,
      additionalFileUrls: additionalFileUrls ?? this.additionalFileUrls,
      currentStep: currentStep,
      errorId: errorId ?? this.errorId,
      importIllustrations: importIllustrations,
    );
  }

  bool get isActive =>
      status == ProcessingJobStatus.queued ||
      status == ProcessingJobStatus.processing;
}
