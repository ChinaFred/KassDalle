class Book {
  final String id;
  final String titre;
  final String auteur;
  final int? annee;
  final String langue;
  final String? urlCouverture;
  final List<String> tags;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// UIDs des utilisateurs avec qui cette bibliothèque est partagée (lecture + annotation).
  final List<String> sharedWith;

  const Book({
    required this.id,
    required this.titre,
    required this.auteur,
    this.annee,
    required this.langue,
    this.urlCouverture,
    required this.tags,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.sharedWith = const [],
  });

  factory Book.fromFirestore(String id, Map<String, dynamic> data) {
    return Book(
      id: id,
      titre: data['titre'] as String,
      auteur: data['auteur'] as String,
      annee: data['annee'] as int?,
      langue: data['langue'] as String? ?? 'fr',
      urlCouverture: data['url_couverture'] as String?,
      tags: List<String>.from(data['tags'] as List? ?? []),
      createdBy: data['created_by'] as String,
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      updatedAt: (data['updated_at'] as dynamic).toDate() as DateTime,
      sharedWith: List<String>.from(data['shared_with'] as List? ?? []),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'titre': titre,
      'auteur': auteur,
      'annee': annee,
      'langue': langue,
      'url_couverture': urlCouverture,
      'tags': tags,
      'created_by': createdBy,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'shared_with': sharedWith,
    };
  }

  Book copyWith({
    String? titre,
    String? auteur,
    int? annee,
    String? langue,
    String? urlCouverture,
    List<String>? tags,
    List<String>? sharedWith,
    DateTime? updatedAt,
  }) {
    return Book(
      id: id,
      titre: titre ?? this.titre,
      auteur: auteur ?? this.auteur,
      annee: annee ?? this.annee,
      langue: langue ?? this.langue,
      urlCouverture: urlCouverture ?? this.urlCouverture,
      tags: tags ?? this.tags,
      sharedWith: sharedWith ?? this.sharedWith,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// Vrai si [uid] est propriétaire OU si le livre est partagé avec lui.
  bool isAccessibleBy(String uid) =>
      createdBy == uid || sharedWith.contains(uid);
}
