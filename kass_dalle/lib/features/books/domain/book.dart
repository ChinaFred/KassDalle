enum BookReviewStatus { draft, validated }

// Sentinel pour copyWith nullable
const _sentinel = Object();

class Book {
  // ── Tags internes identifiant les livres système ───────────────────────────
  static const tagKassdalle = '__kassdale_ia';
  static const tagLibres = '__libres';
  static const tagSecretes = '__secretes';

  /// « Mes recettes du web » : créé par le serveur au premier import par lien.
  static const tagWeb = '__web';

  /// Préfixe des tags internes : il est réservé aux livres système.
  static const reservedTagPrefix = '__';

  /// Le message d'erreur du champ « Tags » d'un formulaire de livre, ou null.
  ///
  /// Un tag interne tapé à la main ferait d'un livre ordinaire un livre
  /// système, que plus personne ne peut supprimer : le formulaire le refuse
  /// plutôt que de le retirer sans le dire.
  static String? reservedTagError(String? text) {
    final tags = (text ?? '').split(',').map((e) => e.trim());
    return tags.any((t) => t.startsWith(reservedTagPrefix))
        ? 'Les tags qui commencent par « __ » sont réservés'
        : null;
  }

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

  /// URL Firebase Storage du fichier source utilisé pour créer le brouillon.
  final String? sourceFileUrl;

  /// Nom du fichier source utilisé pour créer le brouillon.
  final String? sourceFileName;

  /// Date de traitement IA.
  final DateTime? aiProcessedAt;

  /// Livre privé — le créateur en est le seul lecteur.
  ///
  /// Le basculement se fait depuis le formulaire de livre. Il ne reste pas sur
  /// la couverture : `onBookWritten` recopie la valeur sur chaque recette du
  /// livre, faute de quoi la recherche et le planning des autres membres
  /// continueraient d'y puiser.
  ///
  /// Un livre privé ne se partage avec personne. Le champ `shared_with`, qui
  /// promettait un partage nominatif, n'a jamais eu d'écran pour l'écrire : il
  /// a été retiré plutôt que laissé en contradiction avec cette règle.
  final bool isPrivate;

  // ── Getters système ────────────────────────────────────────────────────────
  bool get isKassDalleBook => tags.contains(tagKassdalle);
  bool get isLibresBook => tags.contains(tagLibres);
  bool get isSecretesBook => tags.contains(tagSecretes);
  bool get isWebBook => tags.contains(tagWeb);
  bool get isSystemBook =>
      isKassDalleBook || isLibresBook || isSecretesBook || isWebBook;

  /// Asset image par défaut pour ce livre système (null si livre normal).
  String? get defaultCoverAsset {
    if (isKassDalleBook) return 'assets/mycreations.png';
    if (isLibresBook) return 'assets/opensource.png';
    if (isSecretesBook) return 'assets/Secret.png';
    return null;
  }

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
    this.sourceFileUrl,
    this.sourceFileName,
    this.aiProcessedAt,
    this.isPrivate = false,
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
      sourceFileUrl: data['source_file_url'] as String?,
      sourceFileName: data['source_file_name'] as String?,
      aiProcessedAt: data['ai_processed_at'] != null
          ? (data['ai_processed_at'] as dynamic).toDate() as DateTime
          : null,
      isPrivate: data['is_private'] as bool? ?? false,
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
      'source_file_url': sourceFileUrl,
      'source_file_name': sourceFileName,
      'ai_processed_at': aiProcessedAt,
      'is_private': isPrivate,
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
    Object? urlCouverture = _sentinel,
    List<String>? tags,
    BookReviewStatus? reviewStatus,
    DateTime? updatedAt,
    String? sourceFileUrl,
    String? sourceFileName,
    DateTime? aiProcessedAt,
    bool? isPrivate,
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
      urlCouverture: urlCouverture == _sentinel
          ? this.urlCouverture
          : urlCouverture as String?,
      tags: tags ?? this.tags,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceFileUrl: sourceFileUrl ?? this.sourceFileUrl,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      aiProcessedAt: aiProcessedAt ?? this.aiProcessedAt,
      isPrivate: isPrivate ?? this.isPrivate,
    );
  }
}
