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
  'enhance_illustration': FeatureInfo(
    label: 'Amélioration photo',
    description:
        'Améliore visuellement une photo de plat via génération '
        "d'image Gemini (modèle gemini-2.5-flash-image, 0,04 \$ / image).",
  ),
};
