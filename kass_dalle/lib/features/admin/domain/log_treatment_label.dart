/// Nom lisible d'un traitement, à partir de la racine de son `correlationId`.
///
/// Les journaux groupaient correctement — toutes les entrées d'un même
/// traitement ensemble — mais titraient le groupe avec le nom que le code
/// s'était donné : « generate », « call », « disp », « proc ». Aucun de ces
/// mots ne dit ce qui s'est passé, et « call » ne distinguait même pas deux
/// traitements différents : c'était le nom par défaut de toutes les fonctions
/// qui n'en avaient pas choisi un.
///
/// Deux corrections, complémentaires :
///
/// 1. **À la source** : chaque fonction nomme désormais son traitement, et
///    plusieurs départs d'un même traitement se distinguent par une précision
///    après le deux-points — `generation_recette:creative`.
/// 2. **Ici** : la traduction en français de ce nom technique. Elle vit côté
///    écran, et non côté serveur, parce qu'elle ne sert qu'à l'affichage — un
///    identifiant reste stable et filtrable, un libellé peut changer.
///
/// Une racine inconnue n'est pas une erreur : on rend la racine telle quelle,
/// telle qu'elle est écrite dans le code. Mieux vaut un nom technique qu'un
/// « Traitement inconnu » qui ne permet même plus de chercher.
library;

/// Traduction des racines connues. La clé est ce que le serveur écrit.
const Map<String, String> kLogTreatmentLabels = {
  // ── Import d'une recette, de bout en bout ──────────────────────────────
  'upload_security_scan': 'Contrôle du fichier importé',
  'book_import_analysis': 'Lecture d\'un livre avant son import',
  // Un seul fil couvre la mise en file ET tout le traitement : le dispatcher
  // transmet son identifiant au processeur. « disp » et « proc » nommaient
  // chacun un morceau du couloir, jamais le voyage.
  'import_recette': 'Import d\'une recette',
  'disp': 'Import d\'une recette',
  'proc': 'Import d\'une recette',
  'ecriture_recette': 'Après écriture d\'une recette',
  'recipe-written': 'Après écriture d\'une recette',
  'ecriture_livre': 'Après écriture d\'un livre',
  'rattrapage_nutrition': 'Rattrapage quotidien de la nutrition',
  'backfill_nutrition': 'Reprise de la nutrition demandée',
  'backfill_allergens': 'Reprise des allergènes',
  'backfill_recipe_privacy': 'Reprise de la confidentialité des recettes',
  'book_privacy_backfill': 'Reprise de la confidentialité des livres',
  'user_profiles_backfill': 'Reprise des profils publics',
  'group_reach_backfill': 'Reprise de la portée des groupes',
  'portee_groupes': 'Portée des groupes après écriture d\'un groupe',
  'portee_plannings':
      'Portée des plannings partagés après un changement de groupes ou de rôle',
  'backfill_ai_pricing': 'Correction de la grille tarifaire',
  'text_extraction': 'Extraction du texte d\'une page',
  'url_import': 'Import d\'une recette depuis un lien',
  'url_import_quota': 'Compteur des imports par lien',
  'web_book_ensure': 'Création du livre « Mes recettes du web »',
  'polish_markdown': 'Mise au propre d\'un document',
  'polish_cooklang': 'Mise au propre d\'une recette',
  'refine': 'Correction d\'une recette',
  'suggest_tags': 'Cuisine et type de plat',

  // ── Génération et recherche ────────────────────────────────────────────
  'generation_recette': 'Génération d\'une recette par l\'IA',
  'generate': 'Génération d\'une recette par l\'IA',
  'search': 'Recherche dans la bibliothèque',
  'web_search_query': 'Recherche sur le web',

  // ── Images ─────────────────────────────────────────────────────────────
  'detect_illustrations': 'Détection des illustrations d\'une page',
  'detect_main_photo': 'Choix de la photo principale',
  'generate_recipe_illustration': 'Illustration générée pour une recette',
  'enhance_illustration': 'Retouche d\'une illustration',
  'book_cover': 'Couverture d\'un livre',
  'plating_image': 'Image de dressage',
  'plating_coach': 'Conseils de dressage',
  'image_moderation_review': 'Décision de modération',
  'image_moderation_retry': 'Reprise d\'une modération',

  // ── Nutrition et référentiels ──────────────────────────────────────────
  'normalisation_referentiels': 'Normalisation contre les référentiels',
  'normalisation_nutriments': 'Normalisation de nutriments',
  'calcul_nutrition': 'Calcul nutritionnel d\'une recette',
  'politique_nutrition_lecture': 'Lecture de la politique nutrition',
  'politique_nutrition_ecriture': 'Modification de la politique nutrition',
  'fry-absorption': 'Huile absorbée à la friture',
  'backfill_referentiels': 'Backfill des référentiels',
  'backfill-enrich-referentials': 'Backfill des référentiels',
  'kpis_referentiels': 'Indicateurs des référentiels',
  'data_quality_dashboard': 'Qualité des données',
  // Replis : ces traitements fabriquaient leur propre fil quand personne ne
  // leur en passait un. Ils en reçoivent un désormais, mais d'anciennes
  // entrées les portent encore.
  'enrich-units': 'Poids des unités inconnues',
  'enrich-ing': 'Valeurs pour 100 g des ingrédients',
  'singularize-units': 'Mise au singulier des unités',
  'complete-qty': 'Complétion des quantités manquantes',
  'duplicate-ingredients': 'Doublons d\'ingrédients',

  // ── Planning et courses ────────────────────────────────────────────────
  'planning': 'Planification des repas',
  'planning_concept': 'Idée de recette pour un créneau',
  'planning_meal_ideas': 'Idées de repas sur une consigne',
  'storage_advice': 'Conseils de conservation',
  'shopping_list': 'Liste de courses',

  // ── Administration ─────────────────────────────────────────────────────
  'grille_tarifaire_lecture': 'Lecture de la grille tarifaire',
  'grille_tarifaire_ecriture': 'Modification de la grille tarifaire',
  'routage_ia_lecture': 'Lecture du routage IA',
  'routage_ia_ecriture': 'Modification du routage IA',
  'configurations_routage': 'Configurations de routage IA',
  'app_check_policy': 'Attestation de l\'application',
  'ai_budget_policy': 'Plafonds de dépense IA',
  'couts_gcp': 'Coûts d\'infrastructure',
  'gcp-costs': 'Coûts d\'infrastructure',
  'couts_mensuels': 'Coûts du mois',
  'monthly-costs': 'Coûts du mois',
  'reconciliation_ia_mensuelle': 'Réconciliation des coûts IA',
  'ai-reco': 'Réconciliation des coûts IA',
  'reconstruction_usage_mensuel': 'Reconstruction de la consommation',
  'rebuild-usage-monthly': 'Reconstruction de la consommation',
  'consultation_journaux': 'Consultation des journaux',
  'relance_job_en_echec': 'Relance d\'un job en échec',
  'suppression_job_en_echec': 'Suppression d\'un job en échec',

  // ── Ce qui n'a jamais eu de nom ────────────────────────────────────────
  // Le défaut historique de toutes les fonctions appelables. Il ne devrait
  // plus apparaître : s'il revient, c'est qu'une fonction a été ajoutée sans
  // nommer son traitement.
  'call': 'Appel non nommé — à corriger',
};

/// Un traitement nommé : son libellé, et la précision qui distingue ce
/// départ-là des autres départs du même traitement.
class LogTreatmentName {
  const LogTreatmentName({required this.label, this.detail});

  /// « Génération d'une recette par l'IA ».
  final String label;

  /// « Créative » — ce qui suivait le deux-points, `null` s'il n'y en avait pas.
  final String? detail;

  /// Ce que l'écran affiche en titre de groupe.
  String get display => detail == null ? label : '$label — $detail';
}

/// Traduit la racine d'un `correlationId` en nom lisible.
///
/// La racine attendue est déjà débarrassée de son horodatage. Le deux-points
/// sépare l'étape de sa précision : `generation_recette:creative`.
LogTreatmentName logTreatmentName(String root) {
  final trimmed = root.trim();
  if (trimmed.isEmpty) return const LogTreatmentName(label: 'Hors traitement');

  final cut = trimmed.indexOf(':');
  final base = cut < 0 ? trimmed : trimmed.substring(0, cut);
  final rawDetail = cut < 0 ? '' : trimmed.substring(cut + 1).trim();

  return LogTreatmentName(
    label: kLogTreatmentLabels[base] ?? base,
    detail: rawDetail.isEmpty ? null : _humanizeDetail(rawDetail),
  );
}

/// Précisions dont le libellé est connu — accents compris.
///
/// Le reste vient d'une donnée libre (le nom d'une variante de génération, par
/// exemple) et ne se traduit pas : on se contente de le rendre présentable.
const Map<String, String> kLogTreatmentDetails = {
  'creation': 'Recette créée',
  'ingredients-modifies': 'Ingrédients modifiés',
  'entrees-modifiees': 'Portions, type de page ou texte modifiés',
  'rattrapage-planifie': 'Rattrapage planifié',
  'allergenes': 'Allergènes de la recette',
  'durees-estimees': 'Durées estimées par l\'IA',
  'backfill-demande': 'Reprise demandée depuis l\'écran',
  // Causes d\'avant la garde sur les entrées : le déclencheur se réveillait
  // sur ses propres écritures, et disait alors qu\'il n\'avait rien à faire.
  // Gardées pour les journaux déjà écrits.
  'nutrition-et-courses-a-calculer': 'Nutrition et courses à calculer',
  'rien-a-recalculer': 'Rien à recalculer',
  'suivi-du-job': 'Suivi du job',
  // Ancien nom, gardé pour les journaux déjà écrits : « Premier calcul » ne
  // disait pas de quoi — nutrition ? courses ? les deux ?
  'premier-calcul': 'Nutrition et courses à calculer',
  'sans-changement': 'Rien à recalculer',
};

/// Rend une précision lisible : traduite si on la connaît, présentable sinon.
String _humanizeDetail(String slug) {
  final connu = kLogTreatmentDetails[slug];
  if (connu != null) return connu;
  final spaced = slug.replaceAll(RegExp(r'[-_]+'), ' ').trim();
  if (spaced.isEmpty) return slug;
  return spaced[0].toUpperCase() + spaced.substring(1);
}
