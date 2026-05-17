enum BookReviewStatus { draft, validated }

class Book {
  final String id;
  final String titre;
  final String? sousTitre;
  final String? editeur;
  final String? serie;
  final String auteur;
  final int? annee;
  final String langue;
  final String? isbn;
  final String? description;
  final String? urlCouverture;
  final List<String> tags;
  final BookReviewStatus reviewStatus;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// UIDs des utilisateurs avec qui cette bibliothèque est partagée (lecture + annotation).
  final List<String> sharedWith;

  /// URL Firebase Storage du fichier source utilisé pour créer le brouillon.
  final String? sourceFileUrl;

  /// Nom du fichier source utilisé pour créer le brouillon.
  final String? sourceFileName;

  /// Date de traitement IA.
  final DateTime? aiProcessedAt;

  const Book({
    required this.id,
    required this.titre,
    this.sousTitre,
    this.editeur,
    this.serie,
    required this.auteur,
    this.annee,
    required this.langue,
    this.isbn,
    this.description,
    this.urlCouverture,
    required this.tags,
    this.reviewStatus = BookReviewStatus.validated,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.sharedWith = const [],
    this.sourceFileUrl,
    this.sourceFileName,
    this.aiProcessedAt,
  });

  factory Book.fromFirestore(String id, Map<String, dynamic> data) {
    return Book(
      id: id,
      titre: data['titre'] as String,
      sousTitre: data['sous_titre'] as String?,
      editeur: data['editeur'] as String?,
      serie: data['serie'] as String?,
      auteur: data['auteur'] as String,
      annee: data['annee'] as int?,
      langue: data['langue'] as String? ?? 'fr',
      isbn: data['isbn'] as String?,
      description: data['description'] as String?,
      urlCouverture: data['url_couverture'] as String?,
      tags: List<String>.from(data['tags'] as List? ?? []),
      reviewStatus: BookReviewStatus.values.firstWhere(
        (s) => s.name == (data['review_status'] as String? ?? 'validated'),
        orElse: () => BookReviewStatus.validated,
      ),
      createdBy: data['created_by'] as String,
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      updatedAt: (data['updated_at'] as dynamic).toDate() as DateTime,
      sharedWith: List<String>.from(data['shared_with'] as List? ?? []),
      sourceFileUrl: data['source_file_url'] as String?,
      sourceFileName: data['source_file_name'] as String?,
      aiProcessedAt: data['ai_processed_at'] != null
          ? (data['ai_processed_at'] as dynamic).toDate() as DateTime
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'titre': titre,
      'sous_titre': sousTitre,
      'editeur': editeur,
      'serie': serie,
      'auteur': auteur,
      'annee': annee,
      'langue': langue,
      'isbn': isbn,
      'description': description,
      'url_couverture': urlCouverture,
      'tags': tags,
      'review_status': reviewStatus.name,
      'created_by': createdBy,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'shared_with': sharedWith,
      'source_file_url': sourceFileUrl,
      'source_file_name': sourceFileName,
      'ai_processed_at': aiProcessedAt,
    };
  }

  Book copyWith({
    String? titre,
    String? sousTitre,
    String? editeur,
    String? serie,
    String? auteur,
    int? annee,
    String? langue,
    String? isbn,
    String? description,
    String? urlCouverture,
    List<String>? tags,
    BookReviewStatus? reviewStatus,
    List<String>? sharedWith,
    DateTime? updatedAt,
    String? sourceFileUrl,
    String? sourceFileName,
    DateTime? aiProcessedAt,
  }) {
    return Book(
      id: id,
      titre: titre ?? this.titre,
      sousTitre: sousTitre ?? this.sousTitre,
      editeur: editeur ?? this.editeur,
      serie: serie ?? this.serie,
      auteur: auteur ?? this.auteur,
      annee: annee ?? this.annee,
      langue: langue ?? this.langue,
      isbn: isbn ?? this.isbn,
      description: description ?? this.description,
      urlCouverture: urlCouverture ?? this.urlCouverture,
      tags: tags ?? this.tags,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      sharedWith: sharedWith ?? this.sharedWith,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceFileUrl: sourceFileUrl ?? this.sourceFileUrl,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      aiProcessedAt: aiProcessedAt ?? this.aiProcessedAt,
    );
  }

  /// Vrai si [uid] est propriétaire OU si le livre est partagé avec lui.
  bool isAccessibleBy(String uid) =>
      createdBy == uid || sharedWith.contains(uid);
}
