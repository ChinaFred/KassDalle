enum ReviewStatus { draft, inReview, validated }

class RecipeTags {
  final List<String> themes;
  final List<String> cuisines;
  final List<String> occasions;
  final String? difficulty;
  final int? prepTime;
  final int? cookTime;

  const RecipeTags({
    this.themes = const [],
    this.cuisines = const [],
    this.occasions = const [],
    this.difficulty,
    this.prepTime,
    this.cookTime,
  });

  factory RecipeTags.fromMap(Map<String, dynamic> data) {
    return RecipeTags(
      themes: List<String>.from(data['themes'] as List? ?? []),
      cuisines: List<String>.from(data['cuisines'] as List? ?? []),
      occasions: List<String>.from(data['occasions'] as List? ?? []),
      difficulty: data['difficulty'] as String?,
      prepTime: data['prep_time'] as int?,
      cookTime: data['cook_time'] as int?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'themes': themes,
      'cuisines': cuisines,
      'occasions': occasions,
      'difficulty': difficulty,
      'prep_time': prepTime,
      'cook_time': cookTime,
    };
  }

  RecipeTags copyWith({
    List<String>? themes,
    List<String>? cuisines,
    List<String>? occasions,
    String? difficulty,
    int? prepTime,
    int? cookTime,
  }) {
    return RecipeTags(
      themes: themes ?? this.themes,
      cuisines: cuisines ?? this.cuisines,
      occasions: occasions ?? this.occasions,
      difficulty: difficulty ?? this.difficulty,
      prepTime: prepTime ?? this.prepTime,
      cookTime: cookTime ?? this.cookTime,
    );
  }
}

class Recipe {
  final String id;
  final String titre;
  final String? bookId;
  final String? bookTitre;
  final int? pageNumber;
  final String langue;
  final String rawCooklang;
  final String? draftCooklang;
  final List<String> imageUrls;
  final ReviewStatus reviewStatus;
  final RecipeTags tags;
  final List<String> ingredientsIndex;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// URL Firebase Storage du fichier source (PDF/DOCX/image).
  final String? sourceFileUrl;

  /// Nom original du fichier uploadé.
  final String? sourceFileName;

  /// Date à laquelle Gemini a traité le fichier.
  final DateTime? aiProcessedAt;

  const Recipe({
    required this.id,
    required this.titre,
    this.bookId,
    this.bookTitre,
    this.pageNumber,
    required this.langue,
    required this.rawCooklang,
    this.draftCooklang,
    required this.imageUrls,
    required this.reviewStatus,
    required this.tags,
    required this.ingredientsIndex,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
    this.sourceFileUrl,
    this.sourceFileName,
    this.aiProcessedAt,
  });

  factory Recipe.fromFirestore(String id, Map<String, dynamic> data) {
    return Recipe(
      id: id,
      titre: data['titre'] as String,
      bookId: data['book_id'] as String?,
      bookTitre: data['book_titre'] as String?,
      pageNumber: data['page_number'] as int?,
      langue: data['langue'] as String? ?? 'fr',
      rawCooklang: data['raw_cooklang'] as String? ?? '',
      draftCooklang: data['draft_cooklang'] as String?,
      imageUrls: List<String>.from(data['image_urls'] as List? ?? []),
      reviewStatus: ReviewStatus.values.firstWhere(
        (s) => s.name == (data['review_status'] as String? ?? 'draft'),
        orElse: () => ReviewStatus.draft,
      ),
      tags: RecipeTags.fromMap(
        Map<String, dynamic>.from(data['tags'] as Map? ?? {}),
      ),
      ingredientsIndex: List<String>.from(
        data['ingredients_index'] as List? ?? [],
      ),
      createdBy: data['created_by'] as String,
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      updatedAt: (data['updated_at'] as dynamic).toDate() as DateTime,
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
      'book_id': bookId,
      'book_titre': bookTitre,
      'page_number': pageNumber,
      'langue': langue,
      'raw_cooklang': rawCooklang,
      'draft_cooklang': draftCooklang,
      'image_urls': imageUrls,
      'review_status': reviewStatus.name,
      'tags': tags.toMap(),
      'ingredients_index': ingredientsIndex,
      'created_by': createdBy,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'source_file_url': sourceFileUrl,
      'source_file_name': sourceFileName,
      'ai_processed_at': aiProcessedAt,
    };
  }

  Recipe copyWith({
    String? titre,
    String? bookId,
    String? bookTitre,
    int? pageNumber,
    String? langue,
    String? rawCooklang,
    String? draftCooklang,
    List<String>? imageUrls,
    ReviewStatus? reviewStatus,
    RecipeTags? tags,
    List<String>? ingredientsIndex,
    DateTime? updatedAt,
    String? sourceFileUrl,
    String? sourceFileName,
    DateTime? aiProcessedAt,
  }) {
    return Recipe(
      id: id,
      titre: titre ?? this.titre,
      bookId: bookId ?? this.bookId,
      bookTitre: bookTitre ?? this.bookTitre,
      pageNumber: pageNumber ?? this.pageNumber,
      langue: langue ?? this.langue,
      rawCooklang: rawCooklang ?? this.rawCooklang,
      draftCooklang: draftCooklang ?? this.draftCooklang,
      imageUrls: imageUrls ?? this.imageUrls,
      reviewStatus: reviewStatus ?? this.reviewStatus,
      tags: tags ?? this.tags,
      ingredientsIndex: ingredientsIndex ?? this.ingredientsIndex,
      createdBy: createdBy,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      sourceFileUrl: sourceFileUrl ?? this.sourceFileUrl,
      sourceFileName: sourceFileName ?? this.sourceFileName,
      aiProcessedAt: aiProcessedAt ?? this.aiProcessedAt,
    );
  }
}
