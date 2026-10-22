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
  'transcription_page': 'Numérisation d\'un livre',
  'recipe_tagging': 'Numérisation d\'un livre',
  'recipe_translation': 'Numérisation d\'un livre',
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
  // Import d'une recette depuis un lien : balisage, et lecture d'une page sans
  // données structurées. Rangés avec la saisie de texte : c'est le même
  // processus — une recette qui n'existe sur aucune page de livre.
  'url_import': 'Rédaction d\'une recette',
  'url_import_fallback': 'Rédaction d\'une recette',
  'generate': 'Rédaction d\'une recette',
  'refine': 'Rédaction d\'une recette',
  'polish_cooklang': 'Rédaction d\'une recette',
  'prose_polish': 'Rédaction d\'une recette',
  'add_sections': 'Rédaction d\'une recette',
  'classify_dish_types': 'Rédaction d\'une recette',
  'suggest_tags': 'Rédaction d\'une recette',
  // Durées absentes d'une recette, estimées pour le filtre « Temps total »
  // et le tri « Plus rapides » d'Explorer. Des métadonnées de la recette :
  // rangées avec la rédaction.
  'time_estimate': 'Rédaction d\'une recette',
  'backfill_time_estimate_batch': 'Rédaction d\'une recette',
  'web_search_query': 'Rédaction d\'une recette',
  'enhance_illustration': 'Images',
  'plating_coach': 'Dressage',
  'plating_image': 'Dressage',
  'planning': 'Planning et courses',
  'planning_concept': 'Planning et courses',
  'planning_meal_ideas': 'Planning et courses',
  'planning_constraints': 'Planning et courses',
  'storage_advice': 'Planning et courses',
  'shopping_list': 'Planning et courses',
  'shopping_products_refresh': 'Planning et courses',
  'shopping_products_backfill': 'Planning et courses',
  'backfill_shopping_aliases': 'Planning et courses',
  'shopping_product_alias_auto': 'Planning et courses',
  // Le rôle d'une recette dans un repas sert le planning : c'est lui qui
  // compose un plat et son accompagnement. La reprise se lit donc à côté
  // des autres postes du planning, pas dans la rédaction.
  'backfill_recipe_roles': 'Planning et courses',
  'backfill_recipe_styles': 'Planning et courses',
  'backfill_recipe_protein': 'Planning et courses',
  'inline_meal_role_classification': 'Planning et courses',
  'search': 'Recherche',
  // « Chercher sur le web » (Explorer) : recherche Google ancrée, facturée
  // à l'appel en plus des jetons.
  'web_recipe_search': 'Recherche',
  'upload_security_scan': 'Sécurité',
  'image_moderation': 'Sécurité',
  'image_moderation_batch': 'Sécurité',
  'generate_recipe_illustration': 'Images',
  'polish_markdown': 'Rédaction d\'une recette',
  // Valeurs nutritionnelles — la chaîne la plus bavarde de l'application :
  // une seule écriture de recette peut interroger le moteur une dizaine de
  // fois. Faute d'être listés ici, ces postes tombaient dans « Autres » sous
  // leur clé technique : le poste de coût le plus dynamique était aussi le
  // seul illisible.
  'singularize_units': 'Valeurs nutritionnelles',
  'complete_ingredient_quantities': 'Valeurs nutritionnelles',
  'enrich_unit_weights': 'Valeurs nutritionnelles',
  'estimate_piece_weights': 'Valeurs nutritionnelles',
  'estimate_usual_portions': 'Valeurs nutritionnelles',
  'estimate_unit_couple_weights': 'Valeurs nutritionnelles',
  'detect_not_consumed': 'Valeurs nutritionnelles',
  'detect_duplicate_ingredients': 'Valeurs nutritionnelles',
  'estimate_fry_absorption': 'Valeurs nutritionnelles',
  'nutrition_ingredients_enrichment': 'Valeurs nutritionnelles',
  'nutrition_ingredients_enrichment_batch': 'Valeurs nutritionnelles',
  'nutrition_ingredients_enrichment_auto_batch': 'Valeurs nutritionnelles',
  'inline_ingredient_per100g_enrichment': 'Valeurs nutritionnelles',
  'inline_ingredient_per100g_enrichment_batch': 'Valeurs nutritionnelles',
  'backfill_enrich_referentials_per100g': 'Valeurs nutritionnelles',
  'backfill_enrich_referentials_per100g_batch': 'Valeurs nutritionnelles',
  'backfill_refresh_sodium_per100g': 'Valeurs nutritionnelles',
  'backfill_refresh_sodium_per100g_batch': 'Valeurs nutritionnelles',
  // Allergènes : un jugement par ingrédient du référentiel, comme les
  // valeurs pour 100 g. Rangés avec elles.
  'allergens_auto': 'Valeurs nutritionnelles',
  'backfill_allergens': 'Valeurs nutritionnelles',
  'sandbox_detect_page': 'Bac à sable',
  'sandbox_detect_orientation': 'Bac à sable',
  'sandbox_detect_regions': 'Bac à sable',
  // Les quatre étapes de l'extraction des illustrations d'une page importée.
  // Séparées et non regroupées : le pré-contrôle arrête la chaîne sur les pages
  // sans image, et c'est en le comptant à part qu'on sait ce qu'il fait gagner.
  'page_illustrations_precheck': 'Illustrations d\'une page',
  'page_illustrations_frame': 'Illustrations d\'une page',
  'page_illustrations_orientation': 'Illustrations d\'une page',
  'page_illustrations_regions': 'Illustrations d\'une page',
};

const kFeatureCatalog = <String, FeatureInfo>{
  // Les deux passes de la chaîne d'extraction. Elles ont remplacé
  // `classify_page` + `scan_extraction` + `document_extraction`, qui restent
  // ici : un poste retiré du code doit rester au catalogue, sinon les mois déjà
  // comptabilisés cessent de le nommer.
  'transcription_page': FeatureInfo(
    label: 'Transcription d\'une page',
    description:
        'Lit une page de livre et la recopie telle quelle : liste '
        'd\'ingrédients, étapes, notes, et le type de la page. Aucun balisage, '
        'aucune réécriture.',
  ),
  'recipe_tagging': FeatureInfo(
    label: 'Balisage et normalisation',
    description:
        'Balise les étapes transcrites en CookLang et sépare chaque ligne '
        'd\'ingrédient en quantité, aliment et note explicative.',
  ),
  'recipe_translation': FeatureInfo(
    label: 'Traduction d\'une recette étrangère',
    description:
        'Traduit en français une recette transcrite dans une autre langue et '
        'convertit ses mesures en unités métriques. Appelé seulement quand la '
        'langue détectée n\'est pas le français.',
  ),
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
  'url_import': FeatureInfo(
    label: 'Import par lien : balisage',
    description:
        'Balise en CookLang une recette lue sur une page web (données '
        'structurées de la page, ou texte transcrit) et sépare chaque ligne '
        'd\'ingrédient en quantité, aliment et note.',
  ),
  'url_import_fallback': FeatureInfo(
    label: 'Import par lien : lecture d\'une page sans données structurées',
    description:
        'Recopie la recette du texte principal d\'une page web qui ne publie '
        'pas de données schema.org/Recipe. Appelé seulement dans ce cas.',
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
        "d'une illustration pour affiner les bounding boxes. "
        'Retiré en août 2026 : il aboutissait une fois sur huit.',
  ),
  'detect_illustrations_grid': FeatureInfo(
    label: 'Détection illustrations (fallback grille)',
    description:
        "Approche de repli : re-détecte les illustrations sur l'image "
        'entière quand les approches précédentes échouent. '
        'Retiré en août 2026 : son résultat était presque toujours jeté.',
  ),
  'detect_main_photo': FeatureInfo(
    label: 'Photo principale',
    description:
        'Sélectionne la meilleure photo parmi les illustrations '
        "d'une recette pour en faire l'image de couverture. "
        'Retiré en août 2026 : plus aucun appel depuis juillet.',
  ),
  'detect_grid_dims': FeatureInfo(
    label: 'Détection grille',
    description:
        "Détermine la grille de mise en page d'une page scannée "
        '(1×1, 2×1, 1×2, etc.) pour associer les zones image aux recettes. '
        'Retiré en août 2026 : il aboutissait trois fois sur cent neuf.',
  ),
  'search': FeatureInfo(
    label: 'Recherche IA',
    description:
        'Recherche sémantique dans le livre de recettes par ingrédients, '
        'envies, contexte ou contraintes alimentaires.',
  ),
  'web_recipe_search': FeatureInfo(
    label: 'Recherche de pages de recettes sur le web',
    description:
        '« Chercher sur le web » dans Explorer : Gemini cherche dans Google '
        "jusqu'à huit pages de recettes. Facturé en jetons, plus un prix par "
        'appel ancré dans la recherche Google. Une recherche servie par le '
        "cache partagé n'appelle pas le modèle.",
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
  // Poste retiré du code : la correction rendue n'était pas au niveau. Il
  // reste au catalogue, et c'est la règle du projet — des appels ont été
  // comptabilisés sous cette clé, et un mois déjà chiffré ne doit pas perdre
  // le nom de ce qu'il a payé. Le retirer le ferait réapparaître sous sa clé
  // technique, rangé dans « Autres ».
  'prose_polish': FeatureInfo(
    label: 'Orthographe de la prose (retiré)',
    description:
        "Corrigeait l'orthographe du seul texte des étapes, balises "
        'préservées. Retiré : la correction rendue par le moteur ne tenait pas '
        'ses promesses. Les badges du PDF ont réglé le défaut de lecture qui '
        "l'avait motivée.",
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
  'time_estimate': FeatureInfo(
    label: 'Durées estimées d\'une recette (à l\'écriture)',
    description:
        'Estime la préparation et la cuisson d\'une recette qui n\'en donne '
        'pas, depuis le déclencheur Firestore `onRecipeWritten`. Un appel par '
        'contenu de recette ; une durée lue dans la recette garde la priorité.',
  ),
  'backfill_time_estimate_batch': FeatureInfo(
    label: 'Durées estimées des recettes (backfill)',
    description:
        'Estime la préparation et la cuisson des recettes existantes qui '
        'n\'en donnent pas, huit recettes par appel, lancé depuis Admin › '
        'Backfills. Retiré du code en v0.23.52, son travail fait ; gardé ici '
        'pour nommer les mois déjà comptés.',
  ),
  'backfill_recipe_roles': FeatureInfo(
    label: 'Rôle des recettes (backfill)',
    description:
        'Classe chaque recette existante par son rôle dans un repas — plat, '
        'accompagnement, entrée, dessert, snack —, ce qu\'elle apporte déjà '
        'et ses accompagnements classiques. Un appel par recette, lancé '
        'depuis Admin › Backfills.',
  ),
  'backfill_recipe_styles': FeatureInfo(
    label: 'Style des recettes (backfill)',
    description:
        'Donne à chaque recette existante zéro à trois styles — street food, '
        'réconfortant, healthy… —, que le planning lit quand une consigne en '
        'demande un. Un appel par recette, quarante par passage, lancé depuis '
        'Admin › Backfills.',
  ),
  'backfill_recipe_protein': FeatureInfo(
    label: 'Protéine et féculent des plats (backfill)',
    description:
        'Pose la protéine principale et le féculent principal sur chaque '
        'plat ou accompagnement existant qui n\'en a pas, pour que le '
        'planning varie les protéines et alterne les féculents. Un appel par '
        'recette, lancé depuis Admin › Backfills. Retiré du code en v0.23.52, '
        'son travail fait ; gardé ici pour nommer les mois déjà comptés.',
  ),
  'inline_meal_role_classification': FeatureInfo(
    label: 'Rôle des recettes (à l\'écriture)',
    description:
        'Pose le rôle dans un repas sur toute recette écrite sans ce champ — '
        'création manuelle sans clic « Suggérer », recette de l\'Explorer IA, '
        'copie d\'une recette non classée. Un appel par recette concernée, '
        'depuis le déclencheur Firestore `onRecipeWritten`.',
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
        'Recalcule shopping_products sur toutes les recettes depuis '
        'Admin › Backfills — après un changement de règle de regroupement ou '
        'un produit acheté posé. Aucun appel de modèle.',
  ),
  'backfill_shopping_aliases': FeatureInfo(
    label: 'Produit acheté des ingrédients (backfill)',
    description:
        'Demande au modèle, par lots de quarante, le produit qu\'on achète '
        'pour chaque ingrédient du référentiel qui n\'en a pas — beurre fondu '
        's\'achète en beurre, jaune d\'œuf en œufs. Rattrape le passé ; lancé '
        'depuis Admin › Backfills.',
  ),
  'shopping_product_alias_auto': FeatureInfo(
    label: 'Produit acheté d\'un ingrédient neuf (import)',
    description:
        'À l\'écriture d\'une recette, demande au modèle le produit acheté '
        'des seuls ingrédients que cette écriture vient de créer dans le '
        'référentiel. Reprend l\'orthographe d\'un ingrédient déjà connu '
        'quand le produit proposé en correspond un.',
  ),
  'enhance_illustration': FeatureInfo(
    label: 'Amélioration photo',
    description:
        'Améliore visuellement une photo de plat via génération '
        "d'image Gemini (modèle gemini-3.1-flash-lite-image, "
        '0,0336 \$ / image).',
  ),
  'planning_concept': FeatureInfo(
    label: 'Concept de recette (planning)',
    description:
        "Génère un concept de recette personnalisé pour combler un slot "
        'du planning quand aucune recette existante ne correspond.',
  ),
  'planning_constraints': FeatureInfo(
    label: 'Traduction des préférences du planning',
    description:
        'Lit le texte libre des préférences générales et des notes du jour '
        '(« pas de porc », « 30 min max ») et le traduit en critères que le '
        'programme vérifie. Un appel par « Planifier avec l\'IA », pour les '
        'seuls textes modifiés depuis la dernière traduction ; un texte '
        'inchangé est relu dans le cache, sans appel.',
  ),
  'planning_meal_ideas': FeatureInfo(
    label: 'Idées de repas (planning)',
    description:
        'Trois idées de repas sur une consigne libre, depuis « Générer avec '
        'l\'IA » du sélecteur de recette. Un appel par consigne ou relance ; '
        'l\'idée retenue devient un repas libre, sans recette créée.',
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
  'image_moderation': FeatureInfo(
    label: "Modération d'une image",
    description:
        "Analyse du CONTENU d'une image avant publication : contenu adulte, "
        'violence, et labels qui disent si la scène est culinaire. Facturée à '
        "l'unité par Cloud Vision, deux unités par image.",
  ),
  'image_moderation_batch': FeatureInfo(
    label: "Modération d'un lot d'images",
    description:
        'Même analyse, en un seul appel pour plusieurs images — les douze '
        "illustrations d'un scan, par exemple. Distinguer ce poste de sa "
        'version unitaire est le seul moyen de vérifier que le groupage fait '
        'son office.',
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
        '(modèle gemini-3.1-flash-lite-image, 0,0336 \$ / image).',
  ),
  'storage_advice': FeatureInfo(
    label: 'Conservation et réchauffage',
    description:
        "Dit comment garder et réchauffer un plat préparé à l'avance : "
        'contenant, durée propre à ce plat, méthode de remise en '
        "température, et signes qu'il ne faut plus le manger.",
  ),
  'suggest_tags': FeatureInfo(
    label: 'Suggestion de tags',
    description:
        'Propose automatiquement des tags (type de plat, cuisine, '
        "occasions, ingrédients principaux) pour une recette.",
  ),
  'polish_markdown': FeatureInfo(
    label: 'Relecture d\'un document Markdown',
    description:
        'Corrige un document non-recette (technique, note sur un '
        'ingrédient) sans en modifier la substance.',
  ),
  'generate_recipe_illustration': FeatureInfo(
    label: 'Illustration de recette',
    description:
        'Produit une image de plat pour une recette qui n\'en a pas '
        '(modèle gemini-3.1-flash-lite-image, 0,0336 \$ / image).',
  ),

  // ── Valeurs nutritionnelles ────────────────────────────────────────────────
  // Les postes en `_batch` regroupent tout un lot dans un seul appel : à
  // travail égal ils coûtent bien moins que leur variante unitaire, qui ne
  // sert qu'au rattrapage d'un ingrédient isolé. Les distinguer dans le
  // tableau est le seul moyen de voir si le groupage fait son office.
  'singularize_units': FeatureInfo(
    label: 'Singularisation des unités',
    description:
        'Met au singulier les unités culinaires écrites au pluriel '
        '(« brins » → « brin »), en un appel par recette.',
  ),
  'complete_ingredient_quantities': FeatureInfo(
    label: 'Complétion des quantités manquantes',
    description:
        'Propose une quantité pour les ingrédients qui n\'en portent pas, '
        'sans quoi ils sortiraient du calcul nutritionnel.',
  ),
  'enrich_unit_weights': FeatureInfo(
    label: 'Poids d\'une unité inconnue',
    description:
        'Estime le poids en grammes d\'une unité absente du référentiel '
        '(« une fine tranche »), qui ne correspond à aucune mesure standard.',
  ),
  'estimate_piece_weights': FeatureInfo(
    label: 'Poids d\'un ingrédient à la pièce',
    description:
        'Estime le poids d\'une pièce d\'un ingrédient donné : une échalote '
        'et un concombre ne pèsent pas la même chose.',
  ),
  'estimate_usual_portions': FeatureInfo(
    label: 'Portion usuelle d\'un ingrédient sans quantité',
    description:
        'Estime la quantité qu\'une recette emploie d\'ordinaire d\'un '
        'ingrédient qu\'elle écrit sans quantité — une garniture, un fromage '
        'à râper dessus. Écrite sur la fiche de l\'ingrédient : demandée une '
        'seule fois dans sa vie.',
  ),
  'estimate_unit_couple_weights': FeatureInfo(
    label: 'Poids d\'une unité pour un ingrédient donné',
    description:
        'Estime le poids du couple ingrédient + unité — une branche de thym '
        'face à une branche de céleri.',
  ),
  'detect_not_consumed': FeatureInfo(
    label: 'Ingrédients non consommés',
    description:
        'Distingue ce qui finit dans l\'assiette de ce qui sert seulement à '
        'cuire : bain de friture, foin de fumage, marinade jetée. Le verdict '
        'est écrit sur l\'ingrédient, donc demandé une seule fois dans sa vie.',
  ),
  'detect_duplicate_ingredients': FeatureInfo(
    label: 'Lignes reprenant un ingrédient déjà listé',
    description:
        'Repère les lignes qui décrivent un aliment déjà compté plus haut '
        '(1,5 kg de côte, puis « 4 tranches de viande »), dont l\'addition '
        'doublerait les apports du plat.',
  ),
  'estimate_fry_absorption': FeatureInfo(
    label: 'Huile absorbée à la friture',
    description:
        'Désigne les ingrédients plongés dans le bain, panure comprise, et la '
        'part de leur poids absorbée en huile. N\'est appelé que si la recette '
        'montre un signe de friture.',
  ),
  'nutrition_ingredients_enrichment': FeatureInfo(
    label: 'Estimation d\'un ingrédient',
    description:
        'Estime les valeurs pour 100 g d\'un ingrédient absent du '
        'référentiel nutritionnel.',
  ),
  'nutrition_ingredients_enrichment_batch': FeatureInfo(
    label: 'Estimation par lots',
    description:
        'Estime en un seul appel les valeurs pour 100 g de plusieurs '
        'ingrédients absents du référentiel.',
  ),
  'nutrition_ingredients_enrichment_auto_batch': FeatureInfo(
    label: 'Lot au déclencheur de recette',
    description:
        'Même estimation par lots, déclenchée automatiquement à l\'écriture '
        'd\'une recette plutôt que depuis l\'administration.',
  ),
  'inline_ingredient_per100g_enrichment': FeatureInfo(
    label: 'Rattrapage pendant la normalisation',
    description:
        'Estime les valeurs d\'un ingrédient au fil de la normalisation, pour '
        'qu\'il n\'attende pas un backfill pour compter.',
  ),
  'inline_ingredient_per100g_enrichment_batch': FeatureInfo(
    label: 'Lot pendant la normalisation',
    description:
        'Même rattrapage, groupé en un appel pour tous les ingrédients '
        'inconnus d\'une même recette.',
  ),
  'backfill_enrich_referentials_per100g': FeatureInfo(
    label: 'Backfill administrateur',
    description:
        'Rattrapage d\'un ingrédient du référentiel lancé depuis '
        'Admin → Backfills.',
  ),
  'backfill_enrich_referentials_per100g_batch': FeatureInfo(
    label: 'Lot du backfill administrateur',
    description:
        'Même rattrapage, groupé : le mode normal du backfill, qui traite le '
        'référentiel par paquets.',
  ),

  // Réparation ponctuelle du sel doublé. Poste séparé du rattrapage courant :
  // c'est une dépense décidée un jour précis, pour une cause précise, et la
  // noyer dans le poste habituel aurait rendu son montant introuvable.
  'backfill_refresh_sodium_per100g': FeatureInfo(
    label: 'Reprise du sel — un ingrédient',
    description:
        'Nouvelle estimation d\'un profil dont le sel avait été compté deux '
        'fois. Rattrapage individuel, quand le lot n\'a pas couvert '
        'l\'ingrédient.',
  ),
  'backfill_refresh_sodium_per100g_batch': FeatureInfo(
    label: 'Reprise du sel — par lots',
    description:
        'Le mode normal de la réparation : les profils porteurs de sodium '
        'sont réestimés par paquets de vingt.',
  ),
  'allergens_auto': FeatureInfo(
    label: 'Allergènes d\'un ingrédient (à l\'écriture d\'une recette)',
    description:
        'À l\'écriture d\'une recette, demande au modèle les allergènes '
        'majeurs (14 de l\'annexe II INCO) des ingrédients du référentiel '
        'pas encore examinés, par lots de quarante. Un ingrédient examiné '
        'ne l\'est plus jamais ; la recette en déduit les siens sans appel.',
  ),
  'backfill_allergens': FeatureInfo(
    label: 'Allergènes des ingrédients (backfill)',
    description:
        'Demande au modèle, par lots de quarante, les allergènes majeurs de '
        'chaque ingrédient du référentiel qui n\'en a pas, puis recalcule '
        'ceux des recettes sans appel. Lancé depuis Admin › Backfills.',
  ),

  // Le bac à sable dépense de l'argent réel. Son poste est catalogué comme les
  // autres : une expérience qui coûte sans qu'on sache combien est une
  // expérience qu'on ne peut pas arbitrer.
  'sandbox_detect_page': FeatureInfo(
    label: 'Cadrage de la page',
    description:
        'Expérimental : donne les quatre coins de la page photographiée, en '
        'écartant ce qui est posé dessous — serviette, sous-main, bureau.',
  ),
  'sandbox_detect_orientation': FeatureInfo(
    label: 'Sens de lecture d\'une page',
    description:
        'Expérimental : dit de combien tourner une page mise à plat pour '
        'qu\'elle soit à l\'endroit, en lisant le sens du texte.',
  ),
  'sandbox_detect_regions': FeatureInfo(
    label: 'Détection des zones d\'une page',
    description:
        'Expérimental : repère les photos, dessins, schémas et blocs '
        'manuscrits d\'une page redressée, et rend leurs quatre coins.',
  ),

  // L'extraction des illustrations d'une page importée, sortie du bac à sable.
  // Quatre postes pour une chaîne, parce que le premier décide si les trois
  // autres ont lieu.
  'page_illustrations_precheck': FeatureInfo(
    label: 'Pré-contrôle des images d\'une page',
    description:
        'Dit si la page porte au moins une photographie, un dessin ou un '
        'schéma. Quand elle n\'en porte aucun, la chaîne s\'arrête là et les '
        'trois postes suivants ne sont pas payés.',
  ),
  'page_illustrations_frame': FeatureInfo(
    label: 'Cadrage de la page importée',
    description:
        'Trouve la page dans la photo — en écartant ce qui est posé dessous — '
        'puis place ses quatre coins sur un gros plan, pour la mettre à plat.',
  ),
  'page_illustrations_orientation': FeatureInfo(
    label: 'Sens de lecture de la page importée',
    description:
        'Dit laquelle des quatre orientations de la page se lit. Le quart de '
        'tour, lui, est appliqué par le programme.',
  ),
  'page_illustrations_regions': FeatureInfo(
    label: 'Zones imagées de la page importée',
    description:
        'Repère les photographies et les dessins de la page mise à plat, une '
        'zone par photographie, et rend les rectangles à découper.',
  ),
};
