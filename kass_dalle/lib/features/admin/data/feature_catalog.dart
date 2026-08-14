/// Catalogue statique des features Gemini.
///
/// Source unique de vérité pour les libellés et descriptions affichés
/// dans les écrans de comptabilité et d'usage des tokens.
/// Aucun chargement réseau ou asynchrone n'est nécessaire.
library;

class FeatureInfo {
  final String label;
  final String description;
  const FeatureInfo({required this.label, required this.description});
}

/// Retourne le label lisible ou la clé brute si non référencée.
String featureLabel(String key) => kFeatureCatalog[key]?.label ?? key;

/// Retourne la description ou une chaîne vide si non référencée.
String featureDescription(String key) =>
    kFeatureCatalog[key]?.description ?? '';

/// Processus auquel un poste appartient.
///
/// Une trentaine de postes listés à plat se lit mal : la question posée devant
/// une facture est rarement « combien coûte `detect_grid_dims` » mais « combien
/// coûte de numériser un livre ». Le regroupement répond à la seconde sans
/// interdire la première.
String featureProcess(String key) => kFeatureProcess[key] ?? 'Autres';

const kFeatureProcess = <String, String>{
  'scan_extraction': 'Numérisation d\'un livre',
  'document_extraction': 'Numérisation d\'un livre',
  'classify_page': 'Numérisation d\'un livre',
  'detect_grid_dims': 'Numérisation d\'un livre',
  'detect_illustrations': 'Numérisation d\'un livre',
  'detect_illustrations_crop': 'Numérisation d\'un livre',
  'detect_illustrations_grid': 'Numérisation d\'un livre',
  'detect_main_photo': 'Numérisation d\'un livre',
  'book_cover': 'Numérisation d\'un livre',
  'text_extraction': 'Rédaction d\'une recette',
  'generate': 'Rédaction d\'une recette',
  'refine': 'Rédaction d\'une recette',
  'polish_cooklang': 'Rédaction d\'une recette',
  'add_sections': 'Rédaction d\'une recette',
  'classify_dish_types': 'Rédaction d\'une recette',
  'suggest_tags': 'Rédaction d\'une recette',
  'web_search_query': 'Rédaction d\'une recette',
  'enhance_illustration': 'Images',
  'plating_coach': 'Dressage',
  'plating_image': 'Dressage',
  'planning': 'Planning et courses',
  'planning_concept': 'Planning et courses',
  'shopping_list': 'Planning et courses',
  'shopping_products_refresh': 'Planning et courses',
  'shopping_products_backfill': 'Planning et courses',
  'search': 'Recherche',
  'upload_security_scan': 'Sécurité',
};

const kFeatureCatalog = <String, FeatureInfo>{
  'scan_extraction': FeatureInfo(
    label: 'Extraction de recettes',
    description:
        'Analyse une image ou un PDF de livre et extrait les recettes '
        'au format CookLang (ingrédients, étapes, métadonnées).',
  ),
  'text_extraction': FeatureInfo(
    label: 'Saisie texte libre',
    description:
        'Convertit un texte brut collé ou dicté en recette CookLang '
        'structurée avec balisage des ingrédients et des étapes.',
  ),
  'detect_illustrations': FeatureInfo(
    label: 'Détection illustrations',
    description:
        'Identifie les photos et illustrations de recettes dans les '
        'pages scannées et associe chaque image à sa recette.',
  ),
  'detect_illustrations_crop': FeatureInfo(
    label: 'Détection illustrations (recadrage)',
    description:
        'Approche secondaire de détection : analyse la zone recadrée '
        "d'une illustration pour affiner les bounding boxes.",
  ),
  'detect_illustrations_grid': FeatureInfo(
    label: 'Détection illustrations (fallback grille)',
    description:
        "Approche de repli : re-détecte les illustrations sur l'image "
        'entière quand les approches précédentes échouent.',
  ),
  'detect_main_photo': FeatureInfo(
    label: 'Photo principale',
    description:
        'Sélectionne la meilleure photo parmi les illustrations '
        "d'une recette pour en faire l'image de couverture.",
  ),
  'detect_grid_dims': FeatureInfo(
    label: 'Détection grille',
    description:
        "Détermine la grille de mise en page d'une page scannée "
        '(1×1, 2×1, 1×2, etc.) pour associer les zones image aux recettes.',
  ),
  'search': FeatureInfo(
    label: 'Recherche IA',
    description:
        'Recherche sémantique dans le livre de recettes par ingrédients, '
        'envies, contexte ou contraintes alimentaires.',
  ),
  'book_cover': FeatureInfo(
    label: 'Couverture de livre',
    description:
        'Extrait les métadonnées du livre (titre, auteur, cuisine, année) '
        "depuis une photo de la couverture ou de la 4e de couverture.",
  ),
  'generate': FeatureInfo(
    label: 'Génération de recette',
    description:
        'Génère une recette complète au format CookLang à partir '
        "d'une description, d'ingrédients ou d'un nom de plat.",
  ),
  'refine': FeatureInfo(
    label: 'Amélioration IA',
    description:
        'Modifie une recette existante selon une instruction en langage '
        "naturel (ex : « sans gluten », « doubler les portions »).",
  ),
  'polish_cooklang': FeatureInfo(
    label: 'Mise en forme CookLang',
    description:
        "Corrige l'orthographe, la grammaire, les accents et le balisage "
        'CookLang sans modifier la substance de la recette.',
  ),
  'web_search_query': FeatureInfo(
    label: 'Requête web',
    description:
        'Génère une requête de recherche optimisée pour retrouver '
        'une recette sur le web à partir de son contenu CookLang.',
  ),
  'classify_dish_types': FeatureInfo(
    label: 'Classification plats',
    description:
        'Détecte le type de plat (entrée, plat principal, dessert, etc.) '
        "et la cuisine d'origine d'une recette.",
  ),
  'add_sections': FeatureInfo(
    label: 'Ajout de sections',
    description:
        'Ajoute automatiquement des titres de sections pour structurer '
        'les étapes des recettes longues ou complexes.',
  ),
  'planning': FeatureInfo(
    label: 'Planification repas',
    description:
        'Suggère un plan de repas hebdomadaire équilibré à partir '
        'des recettes disponibles dans le livre.',
  ),
  'shopping_list': FeatureInfo(
    label: 'Consolidation liste de courses',
    description:
        'Transforme des ingrédients de recettes en produits à acheter, '
        'normalisés et consolidés avec quantités totales.',
  ),
  'shopping_products_refresh': FeatureInfo(
    label: 'Maj produits de courses (save recette)',
    description:
        'Recalcule automatiquement shopping_products lors de la sauvegarde '
        'd\'une recette (trigger Firestore).',
  ),
  'shopping_products_backfill': FeatureInfo(
    label: 'Backfill produits de courses',
    description:
        'Migration historique des recettes pour calculer le champ '
        'shopping_products sur les anciennes données.',
  ),
  'enhance_illustration': FeatureInfo(
    label: 'Amélioration photo',
    description:
        'Améliore visuellement une photo de plat via génération '
        "d'image Gemini (modèle gemini-2.5-flash-image, 0,04 \$ / image).",
  ),
  'planning_concept': FeatureInfo(
    label: 'Concept de recette (planning)',
    description:
        "Génère un concept de recette personnalisé pour combler un slot "
        'du planning quand aucune recette existante ne correspond.',
  ),
  'classify_page': FeatureInfo(
    label: 'Classification de page',
    description:
        "Identifie le type de page d'un scan (recette, sommaire, "
        'introduction, etc.) pour orienter le pipeline d\'extraction.',
  ),
  'document_extraction': FeatureInfo(
    label: 'Extraction document',
    description:
        "Extraction longue d'un document complet (PDF multi-pages, "
        'livre entier) en une seule passe Gemini.',
  ),
  'upload_security_scan': FeatureInfo(
    label: 'Scan sécurité upload',
    description:
        'Contrôle antivirus/sécurité des fichiers en quarantaine avant '
        'promotion vers la zone de traitement.',
  ),
  'plating_coach': FeatureInfo(
    label: 'Conseil de dressage',
    description:
        "Produit la gestuelle d'envoi d'une recette précise : contenant, "
        'ordre de pose des éléments, pièges et finitions de dernière minute.',
  ),
  'plating_image': FeatureInfo(
    label: 'Visuel de montage',
    description:
        "Génère l'image d'une étape de dressage en cours de montage "
        '(modèle gemini-2.5-flash-image, 0,04 \$ / image).',
  ),
  'suggest_tags': FeatureInfo(
    label: 'Suggestion de tags',
    description:
        'Propose automatiquement des tags (type de plat, cuisine, '
        "occasions, ingrédients principaux) pour une recette.",
  ),
};
