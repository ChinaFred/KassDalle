/// Libellés de la modération d'images.
///
/// L'écran ne montre jamais de clé technique. Un administrateur doit pouvoir
/// dire pourquoi une image a été refusée sans ouvrir le code.
///
/// **Une clé retirée du serveur reste ici**, exactement comme un poste de coût
/// retiré reste au catalogue : les décisions déjà prises sous cette clé
/// cesseraient sinon de s'expliquer, et le journal de modération est fait pour
/// être relu des mois plus tard.
library;

/// Critères rendus par le moteur, dans l'ordre d'affichage.
///
/// L'ordre n'est pas alphabétique : il va du plus grave au plus anecdotique,
/// parce que c'est dans cet ordre qu'on lit une fiche quand on cherche à
/// comprendre un refus.
const Map<String, String> kModerationCriteria = {
  'adult': 'Contenu adulte',
  'racy': 'Suggestif',
  'violence': 'Violence',
  'medical': 'Médical',
  'spoof': 'Montage',
};

/// Paliers de confiance du moteur.
///
/// `UNKNOWN` a son libellé propre : c'est un état, pas une absence. Le
/// confondre avec « très peu probable » ferait lire une ignorance comme un
/// signal rassurant.
const Map<String, String> kModerationLikelihoods = {
  'VERY_UNLIKELY': 'Très peu probable',
  'UNLIKELY': 'Peu probable',
  'POSSIBLE': 'Possible',
  'LIKELY': 'Probable',
  'VERY_LIKELY': 'Très probable',
  'UNKNOWN': 'Non déterminé',
};

/// Phrase de motif, affichée sous l'identification.
///
/// C'est la réponse à « pourquoi cette image a-t-elle ce statut ? », écrite
/// pour être lue telle quelle.
const Map<String, String> kModerationReasons = {
  'sexual_explicit': 'Refusée : contenu sexuel explicite.',
  'violence_no_culinary_context':
      'À revoir : violence probable, sans contexte culinaire.',
  'violent_content': 'Refusée : scène de violence, sans contexte culinaire.',
  'suggestive_content':
      "À revoir : contenu suggestif. Ce n'est pas un refus — le suggestif ne "
      'refuse jamais seul.',
  'culinary_context':
      'Approuvée : contexte culinaire reconnu malgré une alerte de violence.',
  'no_signal': 'Approuvée : aucun signal.',
  'unreadable_signal':
      'À revoir : le moteur n\'a pas su lire un critère. Ne pas savoir '
      'n\'autorise pas à publier.',
  'engine_unavailable':
      'Sans verdict : moteur injoignable. L\'image attend, elle n\'est ni '
      'publiée ni refusée.',
  'moderation_disabled':
      'Publiée sans analyse : la modération était désactivée.',
  'ai_generated':
      'Publiée sans analyse : image produite par l\'IA, qui applique déjà ses '
      'propres garde-fous.',
  'bundled_asset': 'Publiée sans analyse : image livrée avec l\'application.',
  'manual_approved': 'Publiée par décision d\'un administrateur.',
  'manual_rejected': 'Refusée par décision d\'un administrateur.',
};

/// Libellé d'un état.
const Map<String, String> kModerationStatuses = {
  'approved': 'Publiée',
  'rejected': 'Refusée',
  'manual_review': 'À revoir',
  'pending': 'Sans verdict',
};

/// Destination d'une image, en clair.
const Map<String, String> kModerationTargets = {
  'book_cover': 'Couverture de livre',
  'recipe_illustration': 'Illustration de recette',
  'draft_illustration': 'Illustration extraite',
  'free_recipe_cover': 'Couverture de recette libre',
};

/// Libellé d'une clé, ou la clé elle-même si elle est inconnue.
///
/// Une clé inconnue s'affiche **telle quelle** plutôt que de disparaître : un
/// motif qui s'évanouit de l'écran est un motif qu'on ne corrigera jamais,
/// puisque personne ne saura qu'il manque. `test/moderation_labels_test.dart`
/// vérifie que toutes les clés servies par le serveur ont leur libellé.
String moderationLabel(Map<String, String> table, String? key) {
  if (key == null || key.isEmpty) return '—';
  return table[key] ?? key;
}
