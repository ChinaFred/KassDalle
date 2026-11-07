/// Qui a choisi la recette d'un repas planifié.
///
/// Le libellé dit l'origine sans la confondre : une recette tirée par les
/// règles de Kass'Dalle ne s'affiche pas comme un choix de l'IA. Stocké dans
/// `planned_meals.choice_source` ; absent sur un repas antérieur à ce champ.
enum MealChoiceSource {
  /// Le modèle a choisi parmi les candidats présélectionnés.
  ai('ai', 'Choisie par l\'IA'),

  /// Le code a choisi, sans modèle : « Autre suggestion », panne ou plafond.
  rules('rules', 'Choisie par Kass\'Dalle'),

  /// Le modèle a rédigé la recette (conception IA).
  concept('concept', 'Conçue par l\'IA'),

  /// L'utilisateur l'a choisie lui-même.
  manual('manual', 'Choisie par vous'),

  /// Le repas vient de l'atelier repas (Explorer › « Composer un repas avec
  /// l'IA ») : composé en conversation, puis posé dans le planning. Le plat
  /// principal peut être un brouillon rédigé par l'IA ou une recette de la
  /// bibliothèque liée telle quelle : ni « conçue », ni « choisie parmi des
  /// candidats » (v0.24.78). Écarter sa recette compte comme un refus
  /// (`countsAsRefusal`).
  workshop('workshop', 'Composée avec l\'IA');

  const MealChoiceSource(this.value, this.label);

  /// Valeur Firestore.
  final String value;

  /// Ligne d'origine affichée sous le repas.
  final String label;

  /// Lecture tolérante : une valeur inconnue ou absente rend `null`.
  static MealChoiceSource? fromValue(Object? value) {
    for (final s in values) {
      if (s.value == value) return s;
    }
    return null;
  }

  /// Source d'une suggestion du serveur : `model` → [ai], `code` → [rules].
  static MealChoiceSource fromServer(Object? source) =>
      source == 'model' ? ai : rules;
}
