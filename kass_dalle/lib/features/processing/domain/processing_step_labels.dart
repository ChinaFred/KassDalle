/// Convertit le code technique d'étape pipeline (`current_step` Firestore)
/// en libellé utilisateur en français.
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
      return 'Extraction du texte par l\'IA…';
    case 'parse':
      return 'Analyse de la recette…';
    case 'design':
      return 'Extraction des illustrations…';
    case 'save':
      return 'Enregistrement de la recette…';
    case 'normalize':
      // Le brouillon existe déjà à ce stade : le dire évite de faire croire que
      // la recette n'est pas encore consultable.
      return 'Normalisation des ingrédients (brouillon déjà créé)…';
    case 'done':
      return 'Terminé';
    default:
      return raw;
  }
}
