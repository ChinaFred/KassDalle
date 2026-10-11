import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import '../../../core/services/cooklang_parser.dart'
    show extractPageType, ingredientKey, parsePageTypeLabel;
import 'allergens.dart';
import 'meal_role.dart';
import 'recipe_origin.dart';

export 'recipe_origin.dart';

enum ReviewStatus { draft, inReview, validated }

/// Ce que la recherche d'illustrations a donné, étape par étape.
///
/// « Aucune photo » posait trois questions sans réponse : la page n'en
/// portait-elle pas ? les filtres ont-ils tout écarté ? la détection a-t-elle
/// échoué ? Trois causes, et trois réactions différentes — rescanner, ajouter
/// la photo à la main, ou signaler une panne. Sans ces chiffres, il n'y avait
/// aucun moyen de choisir.
class IllustrationReport {
  const IllustrationReport({
    required this.detectees,
    required this.retenues,
    required this.publiees,
    required this.pagesEnEchec,
  });

  final int detectees;
  final int retenues;
  final int publiees;
  final int pagesEnEchec;

  static IllustrationReport? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    return IllustrationReport(
      detectees: (m['detectees'] as num?)?.toInt() ?? 0,
      retenues: (m['retenues'] as num?)?.toInt() ?? 0,
      publiees: (m['publiees'] as num?)?.toInt() ?? 0,
      pagesEnEchec: (m['pagesEnEchec'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
    'detectees': detectees,
    'retenues': retenues,
    'publiees': publiees,
    'pagesEnEchec': pagesEnEchec,
  };

  /// Vrai quand la recherche s'est déroulée et n'a rien trouvé du tout.
  bool get riendetecte => pagesEnEchec == 0 && detectees == 0;

  /// Vrai quand des photos ont été vues puis toutes écartées en chemin.
  bool get toutesEcartees => detectees > 0 && publiees == 0;
}

/// Un constat du contrôle de fidélité : une phrase, et ce qu'elle énumère.
///
/// Les éléments vivent à part du message parce qu'ils s'affichent en LISTE.
/// Concaténés dans la phrase, sept mots mal lus formaient un pavé qu'on ne
/// relisait pas — et une alerte qu'on ne relit pas ne sert à rien.
class FidelityFinding {
  const FidelityFinding({required this.message, this.items = const []});

  final String message;
  final List<String> items;

  /// Lit le format actuel comme l'ancien.
  ///
  /// Les recettes importées avant ce changement portent une simple liste de
  /// chaînes. Les relire comme des messages sans éléments coûte trois lignes et
  /// évite qu'un brouillon d'hier affiche une réserve vide.
  static List<FidelityFinding> listFrom(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) {
          if (e is String) return FidelityFinding(message: e);
          if (e is Map) {
            final m = Map<String, dynamic>.from(e);
            return FidelityFinding(
              message: m['message'] as String? ?? '',
              items: List<String>.from(m['items'] as List? ?? const []),
            );
          }
          return const FidelityFinding(message: '');
        })
        .where((f) => f.message.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> toMap() => {
    'message': message,
    if (items.isNotEmpty) 'items': items,
  };
}

/// Type de page d'un livre de cuisine.
/// [recipe] : recette classique
/// [technique] : astuce ou technique culinaire
/// [equipment] : description de matériel
/// [ingredientNote] : explication sur un ingrédient
/// [other] : autre contenu non-recette
enum PageType { recipe, technique, equipment, ingredientNote, other }

/// Produit d'achat consolidé (issu de la normalisation IA des ingrédients).
/// Calculé automatiquement lors de la sauvegarde de la recette et stocké
/// dans Firestore sous le champ `shopping_products`.
class RecipeShoppingProduct {
  final String name;
  final String qty;
  final String unit;

  const RecipeShoppingProduct({
    required this.name,
    required this.qty,
    required this.unit,
  });

  factory RecipeShoppingProduct.fromMap(Map<String, dynamic> data) {
    return RecipeShoppingProduct(
      name: data['name'] as String? ?? '',
      qty: data['qty'] as String? ?? '',
      unit: data['unit'] as String? ?? '',
    );
  }

  Map<String, dynamic> toMap() => {'name': name, 'qty': qty, 'unit': unit};

  /// Convertit en RecipeIngredient pour réutiliser les widgets existants.
  RecipeIngredient toIngredient() =>
      RecipeIngredient(name: name, qty: qty, unit: unit);
}

/// Ingrédient structuré extrait du Cooklang : nom + quantité + unité + catégorie optionnelle.
///
/// Ce que la recette dit, et rien d'autre. Les formes résolues — unité
/// canonique, identité dans le référentiel — ne sont pas stockées : elles se
/// recalculent depuis le nom et l'unité partout où elles servent, et les
/// persister revenait à faire disputer un même champ par deux écrivains, dont
/// aucun n'en lisait jamais le contenu.
class RecipeIngredient {
  final String name;
  final String qty;
  final String unit;

  /// Catégorie (section) de l'ingrédient. null = sans catégorie.
  final String? category;

  /// Les libellés qu'une catégorie ne doit jamais porter.
  ///
  /// « (sans titre) » venait de nous : le serveur écrivait ce marqueur dans la
  /// transcription envoyée au modèle pour signaler une section anonyme, et le
  /// prompt lui demandait de recopier les titres de section caractère pour
  /// caractère. Il a obéi. Des recettes portent donc une section réellement
  /// nommée « (sans titre) », affichée telle quelle dans le livre et dans
  /// l'éditeur.
  ///
  /// Le marqueur a été retiré côté serveur (`gemini/tagging.ts`), mais les
  /// recettes déjà importées gardent le leur. Ce filtre les répare à la
  /// LECTURE, sans réécrire la base : rien à migrer, et rien à perdre si la
  /// migration se passait mal.
  static const _categoriesVides = {
    '(sans titre)',
    'sans titre',
    '(aucun)',
    'aucun',
    '-',
    '—',
  };

  /// Une catégorie qui ne nomme rien devient `null`.
  static String? normalizeIngredientCategory(String? raw) {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) return null;
    return _categoriesVides.contains(trimmed.toLowerCase()) ? null : trimmed;
  }

  /// Ce que la ligne du livre dit en plus de la quantité.
  ///
  /// « 1 filet de saumon de 1,8 kg **avec la peau mais écaillée** » : la
  /// quantité se compte, la précision se lit. L'une nourrit la nutrition et les
  /// courses, l'autre n'a de valeur que sous les yeux de qui cuisine.
  ///
  /// Elle vivait jusqu'ici nulle part : le balisage inline ne pouvait pas la
  /// porter — aucune accolade ne l'accepte — et le modèle réécrivait la phrase
  /// du livre pour la caser. La transcription la sépare à la source.
  final String? note;

  /// La ligne du livre, telle qu'elle est écrite.
  ///
  /// Ni affichée telle quelle par défaut, ni calculée : c'est la PIÈCE À
  /// CONVICTION. [note] s'en déduit côté serveur ; quand la note manque, c'est
  /// elle qui dit si le livre avait quelque chose de plus. Sans elle, une note
  /// vide était indistinguable d'une ligne qui ne disait rien.
  final String? source;

  const RecipeIngredient({
    required this.name,
    required this.qty,
    required this.unit,
    this.category,
    this.note,
    this.source,
  });

  factory RecipeIngredient.fromMap(Map<String, dynamic> data) {
    final note = (data['note'] as String?)?.trim();
    return RecipeIngredient(
      name: data['name'] as String? ?? '',
      qty: data['qty'] as String? ?? '',
      unit: data['unit'] as String? ?? '',
      category: normalizeIngredientCategory(data['category'] as String?),
      note: (note ?? '').isEmpty ? null : note,
      source: (data['source'] as String?)?.trim().isEmpty ?? true
          ? null
          : (data['source'] as String).trim(),
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'qty': qty,
    'unit': unit,
    if (category != null) 'category': category,
    if (note != null) 'note': note,
    if (source != null) 'source': source,
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

  /// Temps de repos, en minutes : marinade, réfrigération, levée, repos de pâte.
  ///
  /// **Un seul champ pour toutes ces attentes**, et non un par sorte. Un livre
  /// écrit « laisser mariner une nuit au frais » sans dire si c'est du repos ou
  /// de la réfrigération, et deux champs qui se confondent se remplissent mal
  /// tous les deux.
  ///
  /// Séparé de [prepTime] parce qu'on ne le passe pas à cuisiner : douze heures
  /// de marinade additionnées à la préparation donnent une recette qui a l'air
  /// impraticable. C'est aussi ce que le planning a besoin de savoir pour dire
  /// « celle-là se commence la veille ».
  final int? restTime;

  /// Rôle dans un repas : `plat`, `accompagnement`, `entree`, `dessert`,
  /// `snack`. Absent tant que la recette n'a pas été classée.
  ///
  /// Reconnu une fois par le modèle — à l'import, à la suggestion de tags, ou
  /// par le backfill « Rôle des recettes » —, corrigé par l'utilisateur dans
  /// la liste « Rôle dans un repas » du formulaire, et lu ensuite par le
  /// programme pour composer un repas. Les valeurs sont décidées par
  /// `functions/src/gemini/mealRole.ts` et reprises dans `meal_role.dart`
  /// pour la liste et l'affichage ; `test-fixtures/meal_roles.json` les
  /// verrouille.
  final String? mealRole;

  /// Ce que la recette apporte déjà : `proteine`, `feculent`, `legume`.
  final List<String> contains;

  /// Accompagnements classiques d'un plat qui manque de féculent ou de
  /// légume, nommés simplement. Vide pour tout autre rôle.
  final List<String> suggestedSides;

  /// Protéine principale d'un plat ou d'un accompagnement (`boeuf`,
  /// `volaille`, `vegetarien`…), posée par le modèle avec le rôle ou par le
  /// backfill « Protéine et féculent des plats », ou choisie par l'utilisateur
  /// dans le formulaire. Lue par la présélection du
  /// planning. Valeurs décidées par `functions/src/gemini/mealRole.ts`,
  /// reprises dans `meal_role.dart` pour l'affichage.
  final String? mainProtein;

  /// Féculent principal (`pates`, `riz`, `pommes_de_terre`, `aucun`…).
  final String? mainStarch;

  /// Quand le modèle a examiné la protéine et le féculent
  /// (`main_ingredients_checked_at`), même pour une réponse hors liste. Le
  /// backfill « Protéine et féculent des plats » saute une recette qui le
  /// porte. Gardé ici pour qu'une carte `tags` réécrite en bloc ne l'efface
  /// pas : la recette serait sinon requestionnée et refacturée.
  final DateTime? mainIngredientsCheckedAt;

  const RecipeTags({
    this.themes = const [],
    this.cuisines = const [],
    this.occasions = const [],
    this.dishTypes = const [],
    this.difficulty,
    this.prepTime,
    this.cookTime,
    this.restTime,
    this.mealRole,
    this.contains = const [],
    this.suggestedSides = const [],
    this.mainProtein,
    this.mainStarch,
    this.mainIngredientsCheckedAt,
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
      restTime: data['rest_time'] as int?,
      mealRole: data['meal_role'] as String?,
      contains: List<String>.from(data['contains'] as List? ?? []),
      suggestedSides: List<String>.from(data['suggested_sides'] as List? ?? []),
      // Lecture tolérante : un type inattendu vaut « non renseigné ».
      mainProtein: _stringOrNull(data['main_protein']),
      mainStarch: _stringOrNull(data['main_starch']),
      mainIngredientsCheckedAt: _dateOrNull(
        data['main_ingredients_checked_at'],
      ),
    );
  }

  static String? _stringOrNull(Object? v) => v is String ? v : null;

  static DateTime? _dateOrNull(Object? v) {
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    return null;
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
      'rest_time': restTime,
      // Écrits seulement quand le rôle est connu : un objet construit sans
      // rôle — un formulaire, un CookLang relu — qui écrirait `null`
      // effacerait ce que l'import ou le backfill a posé. Les écritures qui
      // remplacent la carte entière passent par un objet lu en base, donc
      // porteur du rôle ; celle qui ne le peut pas écrit champ par champ
      // (`RecipeRepository.validateDraft`).
      if (mealRole != null) ...{
        'meal_role': mealRole,
        'contains': contains,
        'suggested_sides': suggestedSides,
        // Même règle : écrits seulement quand ils sont connus. Une carte
        // réécrite en bloc depuis un objet lu en base les garde ; sans ces
        // deux lignes, toute modification d'une recette les effaçait.
        'main_protein': ?mainProtein,
        'main_starch': ?mainStarch,
        'main_ingredients_checked_at': ?mainIngredientsCheckedAt,
      },
    };
  }

  /// Vrai quand la recette a été classée : rôle connu.
  bool get hasMealRole => mealRole != null && mealRole!.isNotEmpty;

  /// Vrai quand la protéine et le féculent valent pour ce rôle : plat ou
  /// accompagnement. Une valeur restée d'un ancien rôle n'est ni affichée ni
  /// envoyée au planning.
  bool get carriesMainIngredients =>
      kRolesWithMainIngredients.contains(mealRole);

  /// Copie dont la protéine, le féculent et le marqueur d'examen valent
  /// exactement [mainProtein], [mainStarch] et [mainIngredientsCheckedAt],
  /// `null` compris. [copyWith] ne sait pas effacer ; le formulaire en a
  /// besoin quand l'utilisateur remet « Non renseigné » ou choisit un rôle
  /// qui ne porte pas ces champs. Sans argument : les trois retirés.
  RecipeTags withMainIngredients({
    String? mainProtein,
    String? mainStarch,
    DateTime? mainIngredientsCheckedAt,
  }) {
    return RecipeTags(
      themes: themes,
      cuisines: cuisines,
      occasions: occasions,
      dishTypes: dishTypes,
      difficulty: difficulty,
      prepTime: prepTime,
      cookTime: cookTime,
      restTime: restTime,
      mealRole: mealRole,
      contains: contains,
      suggestedSides: suggestedSides,
      mainProtein: mainProtein,
      mainStarch: mainStarch,
      mainIngredientsCheckedAt: mainIngredientsCheckedAt,
    );
  }

  RecipeTags copyWith({
    List<String>? themes,
    List<String>? cuisines,
    List<String>? occasions,
    List<String>? dishTypes,
    String? difficulty,
    int? prepTime,
    int? cookTime,
    int? restTime,
    String? mealRole,
    List<String>? contains,
    List<String>? suggestedSides,
    String? mainProtein,
    String? mainStarch,
    DateTime? mainIngredientsCheckedAt,
  }) {
    return RecipeTags(
      themes: themes ?? this.themes,
      cuisines: cuisines ?? this.cuisines,
      occasions: occasions ?? this.occasions,
      dishTypes: dishTypes ?? this.dishTypes,
      difficulty: difficulty ?? this.difficulty,
      prepTime: prepTime ?? this.prepTime,
      cookTime: cookTime ?? this.cookTime,
      restTime: restTime ?? this.restTime,
      mealRole: mealRole ?? this.mealRole,
      contains: contains ?? this.contains,
      suggestedSides: suggestedSides ?? this.suggestedSides,
      mainProtein: mainProtein ?? this.mainProtein,
      mainStarch: mainStarch ?? this.mainStarch,
      mainIngredientsCheckedAt:
          mainIngredientsCheckedAt ?? this.mainIngredientsCheckedAt,
    );
  }
}

class RecipeNutritionQuality {
  final int score;
  final String level;
  final List<String> warnings;

  const RecipeNutritionQuality({
    required this.score,
    required this.level,
    this.warnings = const [],
  });

  factory RecipeNutritionQuality.fromMap(Map<String, dynamic> data) {
    return RecipeNutritionQuality(
      score: (data['score'] as num?)?.round() ?? 0,
      level: data['level'] as String? ?? 'C',
      warnings: List<String>.from(data['warnings'] as List? ?? const []),
    );
  }

  Map<String, dynamic> toMap() => {
    'score': score,
    'level': level,
    'warnings': warnings,
  };
}

/// Huile absorbée pendant la friture.
///
/// Ni un ingrédient, ni une donnée manquante : de la matière grasse réellement
/// mangée, que la liste d'ingrédients ne mentionne nulle part. Le bain, lui,
/// reste écarté du total — on ne mange pas un litre d'huile, mais ce qu'on y
/// plonge en ressort plus gras.
///
/// Le calcul appartient au serveur. L'app se contente d'afficher la ligne, en
/// disant qu'elle est estimée.
class RecipeAbsorbedOil {
  /// Grammes d'huile passés du bain dans l'assiette.
  final double grams;

  /// Part du poids des ingrédients frits absorbée en huile.
  final double absorptionRatio;

  /// Poids des ingrédients qui passent au bain, panure comprise.
  final double friedWeightG;

  /// Corps gras dont le profil a servi — celui de la recette quand elle en
  /// nomme un, une huile végétale générique sinon.
  final String sourceName;

  /// L'absorption estimée dépassait le bain déclaré : on s'en est tenu à ce que
  /// la recette met dans la poêle.
  final bool capped;

  /// Apports de cette huile, par nutriment, dans les mêmes clés que les totaux.
  final Map<String, double> contribution;

  const RecipeAbsorbedOil({
    required this.grams,
    required this.absorptionRatio,
    required this.friedWeightG,
    required this.sourceName,
    required this.capped,
    required this.contribution,
  });

  factory RecipeAbsorbedOil.fromMap(Map<String, dynamic> data) {
    return RecipeAbsorbedOil(
      grams: (data['grams'] as num?)?.toDouble() ?? 0,
      absorptionRatio: (data['absorption_ratio'] as num?)?.toDouble() ?? 0,
      friedWeightG: (data['fried_weight_g'] as num?)?.toDouble() ?? 0,
      sourceName: data['source_name'] as String? ?? 'huile de friture',
      capped: data['capped'] == true,
      contribution: RecipeNutritionSnapshot._asNumMap(data['per_ingredient']),
    );
  }

  Map<String, dynamic> toMap() => {
    'grams': grams,
    'absorption_ratio': absorptionRatio,
    'fried_weight_g': friedWeightG,
    'source_name': sourceName,
    'capped': capped,
    'per_ingredient': contribution,
  };
}

class RecipeNutritionSnapshot {
  /// Portions auxquelles ce bloc a été calculé — celles de la recette.
  ///
  /// Ce n'est pas un choix de lecteur : le bloc vit sur un document partagé,
  /// et y écrire le nombre de parts d'un utilisateur faisait que chaque membre
  /// de la famille écrasait l'affichage des autres, en silence.
  final int selectedPortions;
  final double totalWeightG;
  final double coverage;
  final String coverageState;
  final Map<String, double> totals;
  final Map<String, double> perPortion;
  final Map<String, double>? per100g;
  final RecipeNutritionQuality quality;
  final List<String> missingIngredients;

  /// Lignes qui reprennent un ingrédient déjà listé — la pièce achetée puis la
  /// même pièce découpée au dressage. Le verdict vient du serveur : il demande
  /// de comprendre le texte, pas de comparer des noms.
  final List<String> duplicateIngredients;

  /// Huile passée du bain de friture dans l'assiette, quand la recette en
  /// comporte un. `null` dès que rien n'est frit — le cas de presque toutes les
  /// recettes.
  final RecipeAbsorbedOil? absorbedOil;

  /// Valeurs par portion pour [portions] parts.
  ///
  /// Seule cette division dépendait du nombre de parts : tout le reste du bloc
  /// — totaux, poids, couverture, qualité — décrit la recette et vaut pour tout
  /// le monde. La faire ici, au moment de l'affichage, évite d'écrire dans la
  /// recette partagée le choix d'un seul lecteur — et supprime au passage un
  /// appel serveur à chaque coup de curseur.
  Map<String, double> perPortionFor(int? portions) {
    final n = (portions ?? selectedPortions);
    if (n <= 0) return perPortion;
    if (n == selectedPortions) return perPortion;
    return {for (final e in totals.entries) e.key: e.value / n};
  }

  const RecipeNutritionSnapshot({
    required this.selectedPortions,
    required this.totalWeightG,
    required this.coverage,
    required this.coverageState,
    required this.totals,
    required this.perPortion,
    required this.per100g,
    required this.quality,
    this.missingIngredients = const [],
    this.duplicateIngredients = const [],
    this.absorbedOil,
  });

  static Map<String, double> _asNumMap(Object? value) {
    if (value is! Map) return const {};
    final out = <String, double>{};
    value.forEach((key, v) {
      if (key is String && v is num) out[key] = v.toDouble();
    });
    return out;
  }

  factory RecipeNutritionSnapshot.fromMap(Map<String, dynamic> data) {
    final per100gRaw = data['per_100g'];
    final absorbedOilRaw = data['absorbed_oil'];
    return RecipeNutritionSnapshot(
      selectedPortions: (data['selected_portions'] as num?)?.round() ?? 1,
      totalWeightG: (data['total_weight_g'] as num?)?.toDouble() ?? 0,
      coverage: (data['coverage'] as num?)?.toDouble() ?? 0,
      coverageState: data['coverage_state'] as String? ?? 'low',
      totals: _asNumMap(data['totals']),
      perPortion: _asNumMap(data['per_portion']),
      per100g: per100gRaw is Map ? _asNumMap(per100gRaw) : null,
      quality: RecipeNutritionQuality.fromMap(
        Map<String, dynamic>.from(data['quality'] as Map? ?? {}),
      ),
      missingIngredients: List<String>.from(
        data['missing_ingredients'] as List? ?? const [],
      ),
      duplicateIngredients: List<String>.from(
        data['duplicate_ingredients'] as List? ?? const [],
      ),
      absorbedOil: absorbedOilRaw is Map
          ? RecipeAbsorbedOil.fromMap(Map<String, dynamic>.from(absorbedOilRaw))
          : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'selected_portions': selectedPortions,
    'total_weight_g': totalWeightG,
    'coverage': coverage,
    'coverage_state': coverageState,
    'totals': totals,
    'per_portion': perPortion,
    'per_100g': per100g,
    'quality': quality.toMap(),
    'missing_ingredients': missingIngredients,
    'duplicate_ingredients': duplicateIngredients,
    'absorbed_oil': absorbedOil?.toMap(),
  };
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

  /// URLs des vignettes WebP 400px (générées côté serveur). Même ordre que [imageUrls].
  /// Si vide ou absent (anciens enregistrements), l'UI utilise [imageUrls] en fallback.
  final List<String> thumbnailUrls;

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

  /// Produits d'achat consolidés, calculés automatiquement par Gemini lors
  /// de la sauvegarde. Vide pour les anciennes recettes non encore traitées.
  final List<RecipeShoppingProduct> shoppingProducts;

  /// Snapshot nutrition calculé côté backend.
  final RecipeNutritionSnapshot? nutrition;

  /// Allergènes majeurs de la recette, déduits par le serveur des
  /// ingrédients du référentiel (`onRecipeWritten`). `null` tant qu'ils
  /// n'ont pas été calculés.
  ///
  /// Le client le lit et ne l'écrit jamais : [toFirestore] l'omet, une mise à
  /// jour le laisse en place, et une copie ne le reprend pas — le serveur le
  /// recalcule pour elle.
  final RecipeAllergens? allergens;

  /// ID de la recette source dont ce brouillon est une copie.
  /// Non nul uniquement pour les brouillons créés par copie/amélioration.
  /// Nul pour les brouillons issus d'un scan.
  final String? sourceRecipeId;

  /// Ce qui a écrit ce document la première fois — voir [RecipeOrigin].
  ///
  /// Nul sur les documents antérieurs au champ : [effectiveOrigin] déduit
  /// alors ce qu'elle peut des autres champs.
  final RecipeOrigin? origin;

  /// Verdict du contrôle de fidélité entre la page du livre et le balisage.
  ///
  /// `null` quand tout concorde — le cas normal. `avertissement` quand un
  /// détail a bougé (un titre de section raccourci, un ingrédient de trop),
  /// `rupture` quand le balisage a été ÉCARTÉ : le texte affiché est alors la
  /// transcription verbatim, sans balise.
  ///
  /// Ce champ est écrit sur la recette, et non seulement dans les journaux
  /// d'un import déjà oublié : un écart doit se voir au moment de relire.
  final String? fidelityLevel;

  /// Ce qui a été constaté, en français, prêt à afficher.
  final List<FidelityFinding> fidelityFindings;

  /// Ce que la recherche d'illustrations a donné. `null` hors import.
  final IllustrationReport? illustrationReport;

  /// Confidentialité héritée du livre porteur — visible du seul créateur.
  ///
  /// La valeur vit sur le livre, mais elle est recopiée ici par le serveur
  /// (`onBookWritten`, `onRecipeWritten`). Sans cette copie, savoir si on a le
  /// droit de montrer une recette obligeait à lire son livre : la recherche
  /// familiale et le planning familial ne le faisaient pas, et remontaient les
  /// recettes secrètes des autres membres.
  ///
  /// Le client ne décide jamais de ce champ. Il le lit, le réécrit tel quel, et
  /// le serveur le corrige s'il diverge du livre.
  final bool isPrivate;

  /// Code ISO 639-1 de la langue d'origine, sur une recette traduite à
  /// l'import. `null` pour une recette écrite en français.
  ///
  /// Posé par le serveur, avec le texte d'origine dans
  /// `recipes/{id}/origine/texte`. Le client le lit et ne l'écrit jamais :
  /// [toFirestore] l'omet, et une mise à jour le laisse en place. Une copie
  /// ne le reprend pas, puisqu'elle n'emporte pas le texte d'origine.
  final String? langueOrigine;

  /// Vrai quand la recette a été traduite à l'import.
  bool get isTranslated => (langueOrigine ?? '').isNotEmpty;

  /// Vrai quand le balisage a été refusé et le texte du livre conservé tel quel.
  bool get fidelityRejected => fidelityLevel == 'rupture';

  /// Origine lue, ou déduite pour les documents antérieurs au champ : une
  /// recette source fait une copie, un fichier source fait un scan. Sans
  /// l'un ni l'autre, on ne sait pas — et on ne l'affirme pas.
  RecipeOrigin? get effectiveOrigin {
    if (origin != null) return origin;
    if (sourceRecipeId != null) return RecipeOrigin.copy;
    if (sourceFileUrl != null || sourceFileName != null) {
      return RecipeOrigin.scan;
    }
    return null;
  }

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
    this.thumbnailUrls = const [],
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
    this.shoppingProducts = const [],
    this.nutrition,
    this.allergens,
    this.sourceRecipeId,
    this.origin,
    this.fidelityLevel,
    this.fidelityFindings = const [],
    this.illustrationReport,
    this.isPrivate = false,
    this.langueOrigine,
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
      thumbnailUrls: List<String>.from(data['thumbnail_urls'] as List? ?? []),
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
      shoppingProducts: ((data['shopping_products'] as List?) ?? const [])
          .map(
            (e) => RecipeShoppingProduct.fromMap(
              Map<String, dynamic>.from(e as Map),
            ),
          )
          .toList(growable: false),
      nutrition: data['nutrition'] is Map
          ? RecipeNutritionSnapshot.fromMap(
              Map<String, dynamic>.from(data['nutrition'] as Map),
            )
          : null,
      allergens: RecipeAllergens.fromMap(data['allergens']),
      sourceRecipeId: data['source_recipe_id'] as String?,
      origin: recipeOriginFrom(data['origin']),
      fidelityLevel: data['fidelity_level'] as String?,
      fidelityFindings: FidelityFinding.listFrom(data['fidelity_findings']),
      illustrationReport: IllustrationReport.fromMap(
        data['illustration_report'],
      ),
      isPrivate: data['is_private'] as bool? ?? false,
      langueOrigine: data['langue_origine'] as String?,
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
      'thumbnail_urls': thumbnailUrls,
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
      if (shoppingProducts.isNotEmpty)
        'shopping_products': shoppingProducts.map((p) => p.toMap()).toList(),
      if (nutrition != null) 'nutrition': nutrition!.toMap(),
      if (pageType != PageType.recipe) 'page_type': pageType.name,
      'import_version': ?importVersion,
      if (sourceRecipeId != null) 'source_recipe_id': sourceRecipeId,
      if (origin != null) 'origin': origin!.name,
      if (fidelityLevel != null) 'fidelity_level': fidelityLevel,
      if (fidelityFindings.isNotEmpty)
        'fidelity_findings': fidelityFindings.map((f) => f.toMap()).toList(),
      // Réécrit tel qu'il a été lu, jamais décidé ici. Une écriture qui le
      // contredirait serait corrigée par `onRecipeWritten`, qui relit le livre
      // dès que la valeur bouge sans que le livre ait changé.
      'is_private': isPrivate,
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
    List<String>? thumbnailUrls,
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
    List<RecipeShoppingProduct>? shoppingProducts,
    RecipeNutritionSnapshot? nutrition,
    String? sourceRecipeId,
    RecipeOrigin? origin,
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
      thumbnailUrls: thumbnailUrls ?? this.thumbnailUrls,
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
      shoppingProducts: shoppingProducts ?? this.shoppingProducts,
      nutrition: nutrition ?? this.nutrition,
      // Calculés par le serveur : suivent la recette, jamais un paramètre.
      allergens: allergens,
      sourceRecipeId: sourceRecipeId ?? this.sourceRecipeId,
      origin: origin ?? this.origin,
      // Le verdict de fidélité suit la recette : une copie, un renommage ou une
      // validation ne le rendent pas plus fidèle au livre.
      fidelityLevel: fidelityLevel,
      fidelityFindings: fidelityFindings,
      illustrationReport: illustrationReport,
      // La confidentialité suit la recette, et n'est pas un paramètre : elle
      // appartient au livre porteur, que seul le serveur consulte.
      isPrivate: isPrivate,
      // La langue d'origine suit la recette : une édition ne la retraduit pas.
      langueOrigine: langueOrigine,
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
  // Déduplique par (nom, catégorie) : deux ingrédients identiques dans des
  // sections différentes ne doivent pas être fusionnés.
  // La clé de nom est normalisée pour fusionner singulier/pluriel.
  // En cas de doublon strict (même nom + même catégorie), on garde le premier.
  //
  // Sauf si les deux portent une note, et pas la même. Le balisage a rendu
  // « 2 poivrons rouges » et « 2 poivrons verts » sous le même nom
  // « poivron », la couleur en note. Le serveur avait bien écrit deux
  // entrées ; cette fonction n'en gardait qu'une, et la recette affichait
  // deux poivrons sur quatre. Deux lignes du livre qui ne diffèrent que par
  // leur note sont deux lignes, pas un doublon. Une entrée sans note, elle,
  // reste un doublon de celle qui en porte une — c'est le cas des listes
  // dérivées des étapes, où le même aliment revenait tel quel.
  //
  // Cette fonction RECONSTRUIT chaque entrée pour n'en garder que la version
  // rognée. Elle recopiait quatre champs sur six : `note` et `source`
  // disparaissaient ici, à la lecture du document, alors qu'ils étaient bien
  // écrits en base. Trois versions ont cherché la note dans l'import, dans le
  // modèle, dans le balisage — elle était perdue au dernier mètre, entre
  // Firestore et l'écran.
  //
  // La leçon vaut au-delà de ce cas : une recopie champ par champ est une
  // liste qui vieillit mal. Tout champ ajouté au modèle et oublié ici est
  // silencieusement supprimé, sans erreur et sans trace.
  // Par clé (nom, catégorie), les notes déjà vues ; une chaîne vide y marque
  // une entrée sans note.
  final seenNotesByKey = <String, Set<String>>{};
  final result = <RecipeIngredient>[];
  for (final ing in raw) {
    final name = ing.name.trim();
    if (name.isEmpty) continue;
    final key =
        '${ingredientKey(name)}|${(ing.category ?? '').trim().toLowerCase()}';
    final note = (ing.note ?? '').trim().toLowerCase();
    final seenNotes = seenNotesByKey[key];
    final isDuplicate =
        seenNotes != null &&
        (note.isEmpty || seenNotes.contains('') || seenNotes.contains(note));
    if (isDuplicate) continue;
    (seenNotesByKey[key] ??= <String>{}).add(note);
    result.add(
      RecipeIngredient(
        name: name,
        qty: ing.qty.trim(),
        unit: ing.unit.trim(),
        category: ing.category,
        note: ing.note,
        source: ing.source,
      ),
    );
  }
  return result;
}

/// Type de page : champ Firestore `page_type` d'abord, métadonnée
/// `>> page_type:` du CookLang ensuite.
///
/// Le champ Firestore n'est écrit que lorsqu'il vaut autre chose que `recipe`,
/// d'où le repli sur le CookLang. Le mapping libellé → [PageType] appartient au
/// parseur : le dupliquer ici avait fini par produire deux listes de libellés
/// acceptés qui n'étaient pas la même.
PageType _parsePageType(String? raw, [String rawCooklang = '']) {
  final fromField = parsePageTypeLabel(raw ?? '');
  if (fromField != PageType.recipe) return fromField;
  return extractPageType(rawCooklang);
}
