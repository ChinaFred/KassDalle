import '../../../core/services/cooklang_parser.dart' show ingredientKey;

enum ReviewStatus { draft, inReview, validated }

/// Type de page d'un livre de cuisine.
/// [recipe] : recette classique
/// [technique] : astuce ou technique culinaire
/// [equipment] : description de matériel
/// [ingredientNote] : explication sur un ingrédient
/// [other] : autre contenu non-recette
enum PageType { recipe, technique, equipment, ingredientNote, other }

/// Ingrédient structuré extrait du Cooklang : nom + quantité + unité + catégorie optionnelle.
class RecipeIngredient {
  final String name;
  final String qty;
  final String unit;

  /// Catégorie (section) de l'ingrédient. null = sans catégorie.
  final String? category;

  const RecipeIngredient({
    required this.name,
    required this.qty,
    required this.unit,
    this.category,
  });

  factory RecipeIngredient.fromMap(Map<String, dynamic> data) {
    return RecipeIngredient(
      name: data['name'] as String? ?? '',
      qty: data['qty'] as String? ?? '',
      unit: data['unit'] as String? ?? '',
      category: data['category'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'qty': qty,
    'unit': unit,
    if (category != null) 'category': category,
  };
}

/// Types de plat normalisés — valeurs attendues :
/// viande, volaille, poisson, fruits de mer, végétarien, vegan,
/// dessert, pâtisserie, soupe, entrée, plat complet, snack
const kDishTypes = [
  'viande',
  'volaille',
  'poisson',
  'fruits de mer',
  'végétarien',
  'vegan',
  'dessert',
  'pâtisserie',
  'soupe',
  'entrée',
  'plat complet',
  'snack',
];

class RecipeTags {
  final List<String> themes;
  final List<String> cuisines;
  final List<String> occasions;

  /// Types de plat (viande, volaille, poisson, etc.)
  final List<String> dishTypes;

  final String? difficulty;
  final int? prepTime;
  final int? cookTime;

  const RecipeTags({
    this.themes = const [],
    this.cuisines = const [],
    this.occasions = const [],
    this.dishTypes = const [],
    this.difficulty,
    this.prepTime,
    this.cookTime,
  });

  factory RecipeTags.fromMap(Map<String, dynamic> data) {
    return RecipeTags(
      themes: List<String>.from(data['themes'] as List? ?? []),
      cuisines: List<String>.from(data['cuisines'] as List? ?? []),
      occasions: List<String>.from(data['occasions'] as List? ?? []),
      dishTypes: List<String>.from(data['dish_types'] as List? ?? []),
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
      'dish_types': dishTypes,
      'difficulty': difficulty,
      'prep_time': prepTime,
      'cook_time': cookTime,
    };
  }

  RecipeTags copyWith({
    List<String>? themes,
    List<String>? cuisines,
    List<String>? occasions,
    List<String>? dishTypes,
    String? difficulty,
    int? prepTime,
    int? cookTime,
  }) {
    return RecipeTags(
      themes: themes ?? this.themes,
      cuisines: cuisines ?? this.cuisines,
      occasions: occasions ?? this.occasions,
      dishTypes: dishTypes ?? this.dishTypes,
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

  /// URLs des pages supplémentaires (scan multi-pages).
  final List<String> additionalSourceFileUrls;

  /// Date à laquelle Gemini a traité le fichier.
  final DateTime? aiProcessedAt;

  /// Nombre de portions (extrait du métadonnée CookLang >> portions).
  final int? portions;

  /// Liste structurée des ingrédients avec quantités et unités.
  final List<RecipeIngredient> ingredients;

  /// Type de page (recette, technique, matériel, etc.).
  final PageType pageType;

  /// Version de l'application utilisée pour importer ce brouillon.
  final String? importVersion;

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
    this.additionalSourceFileUrls = const [],
    this.aiProcessedAt,
    this.portions,
    this.ingredients = const [],
    this.pageType = PageType.recipe,
    this.importVersion,
  });

  factory Recipe.fromFirestore(String id, Map<String, dynamic> data) {
    final ingredientsIndexRaw = List<String>.from(
      data['ingredients_index'] as List? ?? [],
    );
    final ingredientsRaw = (data['ingredients'] as List? ?? [])
        .map(
          (e) => RecipeIngredient.fromMap(Map<String, dynamic>.from(e as Map)),
        )
        .toList();

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
      ingredientsIndex: _dedupeIngredientIndex(ingredientsIndexRaw),
      createdBy: data['created_by'] as String,
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      updatedAt: (data['updated_at'] as dynamic).toDate() as DateTime,
      sourceFileUrl: data['source_file_url'] as String?,
      sourceFileName: data['source_file_name'] as String?,
      additionalSourceFileUrls: List<String>.from(
        data['additional_source_file_urls'] as List? ?? [],
      ),
      aiProcessedAt: data['ai_processed_at'] != null
          ? (data['ai_processed_at'] as dynamic).toDate() as DateTime
          : null,
      portions: data['portions'] as int?,
      ingredients: _dedupeStructuredIngredients(ingredientsRaw),
      pageType: _parsePageType(
        data['page_type'] as String?,
        data['raw_cooklang'] as String? ?? '',
      ),
      importVersion: data['import_version'] as String?,
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
      'additional_source_file_urls': additionalSourceFileUrls,
      'ai_processed_at': aiProcessedAt,
      'portions': portions,
      'ingredients': ingredients.map((i) => i.toMap()).toList(),
      if (pageType != PageType.recipe) 'page_type': pageType.name,
      'import_version': ?importVersion,
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
    List<String>? additionalSourceFileUrls,
    DateTime? aiProcessedAt,
    int? portions,
    List<RecipeIngredient>? ingredients,
    PageType? pageType,
    String? importVersion,
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
      additionalSourceFileUrls:
          additionalSourceFileUrls ?? this.additionalSourceFileUrls,
      aiProcessedAt: aiProcessedAt ?? this.aiProcessedAt,
      portions: portions ?? this.portions,
      ingredients: ingredients ?? this.ingredients,
      pageType: pageType ?? this.pageType,
      importVersion: importVersion ?? this.importVersion,
    );
  }
}

List<String> _dedupeIngredientIndex(List<String> raw) {
  final seen = <String>{};
  final result = <String>[];
  for (final item in raw) {
    final normalized = item.trim().toLowerCase();
    if (normalized.isEmpty || seen.contains(normalized)) continue;
    seen.add(normalized);
    result.add(normalized);
  }
  return result;
}

List<RecipeIngredient> _dedupeStructuredIngredients(
  List<RecipeIngredient> raw,
) {
  // Déduplique par nom tout en préservant la catégorie et l'ordre d'apparition.
  // La clé est normalisée pour fusionner les formes singulier/pluriel.
  // En cas de doublon, on garde le premier.
  final seen = <String>{};
  final result = <RecipeIngredient>[];
  for (final ing in raw) {
    final name = ing.name.trim();
    if (name.isEmpty) continue;
    final key = ingredientKey(name);
    if (seen.contains(key)) continue;
    seen.add(key);
    result.add(
      RecipeIngredient(
        name: name,
        qty: ing.qty.trim(),
        unit: ing.unit.trim(),
        category: ing.category,
      ),
    );
  }
  return result;
}

/// Mappe la valeur Firestore `page_type` (underscore) vers [PageType].
/// `PageType.ingredientNote.name` vaut `"ingredientNote"` (camelCase) mais
/// Firestore stocke `"ingredient_note"` → on traite les deux formes.
/// Si le champ Firestore est absent, on cherche `>> page_type:` dans rawCooklang (fallback).
PageType _parsePageType(String? raw, [String rawCooklang = '']) {
  final fromField = _parsePageTypeString(raw ?? '');
  if (fromField != PageType.recipe) return fromField;

  // Fallback : lire >> page_type: depuis raw_cooklang si le champ Firestore est absent/recipe
  final match = RegExp(
    r'^>>\s*page_type\s*:\s*(.+)$',
    multiLine: true,
    caseSensitive: false,
  ).firstMatch(rawCooklang);
  if (match != null) {
    return _parsePageTypeString(match.group(1)!.trim());
  }
  return PageType.recipe;
}

PageType _parsePageTypeString(String raw) {
  switch (raw.toLowerCase().trim()) {
    case 'ingredient_note':
    case 'ingredientnote': return PageType.ingredientNote;
    case 'technique': return PageType.technique;
    case 'equipment': return PageType.equipment;
    case 'other': return PageType.other;
    default: return PageType.recipe;
  }
}
