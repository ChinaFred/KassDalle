/// Pages supplémentaires admises par job d'import (`additional_file_urls`) :
/// 20, soit 21 pages avec la première (ticket #156).
///
/// La règle `processing_jobs` de `firestore.rules` refuse un job au-delà, et
/// `MAX_ADDITIONAL_FILE_URLS` (`functions/src/pipeline/jobPages.ts`) le refuse
/// au traitement. Le client contrôle avant l'envoi pour ne pas monter des
/// pages qu'un refus rendrait inutiles. `processing_job_pages_test.dart`
/// vérifie la concordance avec la règle.
const int kMaxAdditionalFileUrls = 20;

/// Pages d'un import, la première comprise : 21 au plus.
const int kMaxImportPages = kMaxAdditionalFileUrls + 1;

/// Nombre de pages à retirer pour lancer l'analyse, 0 si la file passe.
int pagesOverLimit(int totalPages) =>
    totalPages > kMaxImportPages ? totalPages - kMaxImportPages : 0;

/// « Retirez N pages pour lancer l'analyse. », au singulier pour une page.
String removePagesInstruction(int excess) => excess == 1
    ? "Retirez 1 page pour lancer l'analyse."
    : "Retirez $excess pages pour lancer l'analyse.";

/// Message d'un import qui compte trop de pages, `null` sinon.
///
/// Une recette part en un seul import : le message ne propose pas de la
/// découper.
String? tooManyPagesMessage(int totalPages) {
  final excess = pagesOverLimit(totalPages);
  if (excess == 0) return null;
  return 'Un import compte $kMaxImportPages pages au plus. '
      '${removePagesInstruction(excess)}';
}

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

/// Code `error_code` écrit par le pipeline quand le compte qui a lancé le job
/// n'est plus éditeur : révoqué, rétrogradé ou supprimé depuis la mise en
/// file. Le job part en dead letter sans nouvel essai, et aucun appel d'IA n'a
/// lieu. Vaut pour tous les types de job, import par lien compris.
const kJobOwnerNotEditorCode = 'owner_not_editor';

/// `duplicate` : le serveur a arrêté le traitement après la transcription,
/// parce que la ou les recettes lues existent déjà dans le livre (ou sont
/// attendues d'un import plus ancien). Le job attend une décision de
/// l'utilisateur : « Ce n'est pas un doublon » ou « Supprimer ».
enum ProcessingJobStatus {
  queued,
  processing,
  done,
  error,
  rejected,
  duplicate,
}

/// Une recette lue sur la page et retenue comme doublon possible.
///
/// Écrite par le serveur dans `processing_jobs.duplicates`. La référence est
/// soit une recette existante du même livre ([recipeId]), soit un import plus
/// ancien encore en cours ([jobId]), dont la recette n'existe pas encore.
class JobDuplicate {
  const JobDuplicate({
    required this.titre,
    required this.existingTitre,
    this.existingPage,
    this.recipeId,
    this.jobId,
  });

  /// Le titre lu sur la page scannée.
  final String titre;

  /// Le titre de la recette existante, ou de l'import plus ancien.
  final String existingTitre;

  /// La page de la recette existante, quand elle est connue.
  final int? existingPage;

  final String? recipeId;
  final String? jobId;

  /// Lecture tolérante : une entrée illisible est écartée par [listFrom],
  /// un champ absent prend une valeur vide.
  static JobDuplicate? fromMap(Object? raw) {
    if (raw is! Map) return null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
    final page = raw['existing_page'];
    return JobDuplicate(
      titre: text(raw['titre']) ?? '',
      existingTitre: text(raw['existing_titre']) ?? '',
      existingPage: page is num ? page.toInt() : null,
      recipeId: text(raw['recipe_id']),
      jobId: text(raw['job_id']),
    );
  }

  static List<JobDuplicate> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw.map(fromMap).whereType<JobDuplicate>().toList(growable: false);
  }

  /// « Déjà dans le livre : Tarte aux pommes, p. 42 » (sans « p. » quand la
  /// page est inconnue), ou « Import plus ancien en cours : Tarte aux
  /// pommes » quand la référence est un job.
  String get referenceLabel {
    if (recipeId == null && jobId != null) {
      return 'Import plus ancien en cours : $existingTitre';
    }
    final page = existingPage;
    return page == null
        ? 'Déjà dans le livre : $existingTitre'
        : 'Déjà dans le livre : $existingTitre, p. $page';
  }
}

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

  /// Vrai quand le serveur a arrêté le job parce que son propriétaire n'est
  /// plus éditeur ([kJobOwnerNotEditorCode]). « Relancer » n'a pas de sens :
  /// le même refus reviendrait.
  final bool ownerNotEditor;

  /// Combien de recettes la page contenait ; une seule est reprise.
  final int? recettesTrouvees;

  /// Vrai dès que le serveur a commencé à traduire la recette. Posé avec
  /// `current_step: "translate"` et jamais retiré : le fil d'icônes garde le
  /// jalon « Traduction » après l'étape. Le client ne l'écrit jamais.
  final bool translated;

  /// Relances d'un import par lien déjà faites. Les règles Firestore en
  /// admettent [maxUrlRetries] au plus, chacune incrémentant ce compteur de un.
  final int urlRetryCount;

  /// Relances admises pour un import par lien (règle `urlRelaunchAllowed`).
  static const maxUrlRetries = 2;

  /// Les recettes retenues comme doublons possibles, sur un job au statut
  /// [ProcessingJobStatus.duplicate]. Écrites par le serveur.
  final List<JobDuplicate> duplicates;

  /// Vrai quand l'utilisateur a répondu « Ce n'est pas un doublon » : le
  /// serveur reprend sans nouvelle détection. Seule écriture du client sur
  /// ce sujet.
  final bool duplicateOverride;

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
    this.ownerNotEditor = false,
    this.recettesTrouvees,
    this.urlRetryCount = 0,
    this.translated = false,
    this.duplicates = const [],
    this.duplicateOverride = false,
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
      ownerNotEditor: data['error_code'] == kJobOwnerNotEditorCode,
      recettesTrouvees: (data['recettes_trouvees'] as num?)?.toInt(),
      urlRetryCount: (data['url_retry_count'] as num?)?.toInt() ?? 0,
      translated: data['translated'] == true,
      duplicates: JobDuplicate.listFrom(data['duplicates']),
      duplicateOverride: data['duplicate_override'] == true,
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
      // `null` plutôt qu'une chaîne vide : le serveur refuse tout `book_id`
      // présent qui n'est pas un identifiant (`assertJobTargetBook`, ticket
      // #163, point 11), et `/scan?bookId=` en laissait passer un vide.
      'book_id': (bookId ?? '').isEmpty ? null : bookId,
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
      ownerNotEditor: ownerNotEditor,
      recettesTrouvees: recettesTrouvees,
      urlRetryCount: urlRetryCount,
      translated: translated,
      duplicates: duplicates,
      duplicateOverride: duplicateOverride,
    );
  }

  bool get isDuplicate => status == ProcessingJobStatus.duplicate;

  bool get isActive =>
      status == ProcessingJobStatus.queued ||
      status == ProcessingJobStatus.processing;
}
