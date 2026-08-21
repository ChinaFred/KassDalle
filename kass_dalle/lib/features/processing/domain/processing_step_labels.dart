/// Convertit le code technique d'étape pipeline (`current_step` Firestore)
/// en libellé utilisateur en français.
///
/// Ces libellés doivent décrire ce qui SE PASSE, pas ce qui vient de finir.
/// « Enregistrement de la recette » couvrait autrefois le balisage, le contrôle
/// de fidélité et la normalisation des référentiels — jusqu’à sept minutes sous
/// un mot qui en promet une seconde. L’utilisateur voyait un enregistrement
/// interminable sans aucun moyen de savoir ce qui tournait.
///
/// Le calcul nutritionnel n’y figure pas, et c’est volontaire : il a lieu APRÈS
/// l’écriture, dans le déclencheur, sur une recette déjà consultable.
/// L’annoncer ici laisserait croire qu’il faut l’attendre.
///
/// Si la valeur reçue est déjà un libellé en clair (écrit par le client lors
/// d'un scan, ex. "Extraction du texte…"), elle est retournée telle quelle.
String formatProcessingStep(String? raw) {
  if (raw == null || raw.trim().isEmpty) return '';
  switch (raw) {
    case 'queued':
      return 'En attente…';
    case 'import':
      return 'Téléchargement du fichier…';
    case 'image_decode':
      return 'Préparation de l\'image…';
    case 'gemini_call':
      return 'Lecture de la page par l\'IA…';
    case 'parse':
      return 'Analyse de la recette…';
    case 'design':
      // « Extraction » depuis le retrait de l'extraction automatique, c'était
      // une promesse que le traitement ne tient plus : il REPÈRE les photos, il
      // n'en découpe aucune. Une étiquette qui annonce un travail supprimé fait
      // attendre un résultat qui ne viendra pas.
      return 'Recherche de photos sur la page…';
    case 'tagging':
      return 'Balisage de la recette par l\'IA…';
    case 'normalize':
      return 'Enrichissement des ingrédients par l\'IA…';
    case 'save':
      return 'Enregistrement de la recette…';
    case 'done':
      return 'Terminé';
    default:
      return raw;
  }
}
