enum ProcessingJobType {
  recipeScan,
  bookCoverScan,
  bookDocumentScan,

  /// Import d'une recette depuis un lien. Créé par le serveur seulement
  /// (`importRecipeFromUrlFn`), jamais par le client.
  recipeUrlImport,
}

/// Code d'échec d'un import par lien (`error_code`), écrit par le serveur.
enum UrlImportErrorCode {
  /// Le site refuse la lecture (403, page payante…).
  pageBlocked,

  /// 404 ou 410.
  pageNotFound,

  /// La page ne contient aucune recette.
  noRecipe,

  /// Délai dépassé, réseau, erreur du site.
  timeout,

  /// Adresse refusée par le serveur.
  urlRefused,
}

UrlImportErrorCode? urlImportErrorCodeFrom(Object? raw) => switch (raw) {
  'page_blocked' => UrlImportErrorCode.pageBlocked,
  'page_not_found' => UrlImportErrorCode.pageNotFound,
  'no_recipe' => UrlImportErrorCode.noRecipe,
  'timeout' => UrlImportErrorCode.timeout,
  'url_refused' => UrlImportErrorCode.urlRefused,
  _ => null,
};

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

  /// Le titre lu par l'IA, posé par le serveur après la transcription.
  ///
  /// La ligne de suivi l'affiche à la place du nom de fichier, le temps que
  /// le brouillon existe : entre la lecture de la page et l'enregistrement,
  /// le balisage et la normalisation durent jusqu'à sept minutes. Un job en
  /// erreur après la lecture garde ainsi le nom de sa recette. Le client ne
  /// l'écrit jamais.
  final String? titre;

  /// Le scan de l'utilisateur d'où vient ce job.
  ///
  /// Photographier une page déclenche quatre traitements côté serveur — le
  /// contrôle du fichier, l'import, la détection d'illustrations, puis les
  /// calculs d'après écriture. Chacun a son propre fil de journaux, et rien
  /// ne les reliait : le coût d'un scan était réparti sur quatre groupes.
  ///
  /// Le client est le seul à savoir que ces envois forment un seul acte : le
  /// contrôle du fichier a lieu avant que ce job existe. Il pose donc
  /// l'identifiant, et le serveur le transmet jusqu'au bout.
  final String? scanId;

  /// Extraire les illustrations de la page importée.
  ///
  /// Le choix voyage avec le job, pas avec le compte : le serveur traite ce job
  /// après coup, et la préférence a pu changer entre-temps. Ce qui a été demandé
  /// au moment de l'import est ce qui doit être fait.
  final bool importIllustrations;

  /// Plafond de dépense d'un import de livre, en dollars.
  ///
  /// Fixé par l'utilisateur sur l'écran de confirmation et écrit sur le job
  /// parent : le serveur le pose sur le scan avant de créer la première tranche,
  /// et chaque tranche le relit avant son premier appel d'IA. Absent pour tout
  /// ce qui n'est pas un livre entier. Le client ne s'en sert jamais pour
  /// décider : c'est le serveur qui arrête.
  final double? budgetLimitUsd;

  /// Adresse de la page, pour un import par lien. Écrite par le serveur.
  final String? sourceUrl;

  /// Code d'échec d'un import par lien, quand il a échoué.
  final UrlImportErrorCode? errorCode;

  /// Combien de recettes la page contenait ; une seule est reprise.
  final int? recettesTrouvees;

  /// Relances d'un import par lien déjà faites. Les règles Firestore en
  /// admettent [maxUrlRetries] au plus, chacune incrémentant ce compteur de un.
  final int urlRetryCount;

  /// Relances admises pour un import par lien (règle `urlRelaunchAllowed`).
  static const maxUrlRetries = 2;

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
    this.scanId,
    this.titre,
    this.budgetLimitUsd,
    this.sourceUrl,
    this.errorCode,
    this.recettesTrouvees,
    this.urlRetryCount = 0,
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
      scanId: data['scan_id'] as String?,
      titre: data['titre'] as String?,
      budgetLimitUsd: (data['budget_limit_usd'] as num?)?.toDouble(),
      sourceUrl: data['source_url'] as String?,
      errorCode: urlImportErrorCodeFrom(data['error_code']),
      recettesTrouvees: (data['recettes_trouvees'] as num?)?.toInt(),
      urlRetryCount: (data['url_retry_count'] as num?)?.toInt() ?? 0,
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
      if (scanId != null) 'scan_id': scanId,
      if (titre != null) 'titre': titre,
      if (budgetLimitUsd != null) 'budget_limit_usd': budgetLimitUsd,
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
      scanId: scanId,
      titre: titre,
      budgetLimitUsd: budgetLimitUsd,
      sourceUrl: sourceUrl,
      errorCode: errorCode,
      recettesTrouvees: recettesTrouvees,
      urlRetryCount: urlRetryCount,
    );
  }

  bool get isActive =>
      status == ProcessingJobStatus.queued ||
      status == ProcessingJobStatus.processing;
}
