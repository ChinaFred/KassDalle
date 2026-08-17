/// Contexte de préparation à l'avance, transporté à l'ouverture d'une recette.
///
/// Une recette planifiée pour mardi mais cuisinée dimanche ne se lit pas comme
/// la même recette cuisinée pour le soir même : il manque le refroidissement,
/// la conservation, le réchauffage, et ce qu'il vaut mieux ajouter au dernier
/// moment. Ce contexte est ce qui manquait au lecteur.
///
/// Il ne s'écrit **nulle part** : ni sur la recette, qui est partagée et que
/// deux membres de la famille peuvent planifier à deux dates différentes, ni
/// sur le profil du lecteur, qui n'a pas de date. Il voyage en paramètre
/// d'adresse, comme les portions, et disparaît avec l'écran — voir la règle
/// « redimensionner ne modifie jamais l'originale » du CLAUDE.md.
library;

import 'meal_storage_rules.dart';

/// Paramètre d'adresse portant le jour de préparation.
const String kPrepDateQueryParam = 'prep';

/// Paramètre d'adresse portant le jour du repas.
const String kMealDateQueryParam = 'meal';

/// Le couple (jour de préparation, jour du repas) d'un repas planifié.
class MealPrepContext {
  final DateTime prepDate;
  final DateTime mealDate;

  const MealPrepContext({required this.prepDate, required this.mealDate});

  /// Nombre de jours calendaires entre la préparation et le repas.
  int get daysAhead =>
      mealStorageDaysAhead(prepDate: prepDate, mealDate: mealDate);

  /// Mode de conservation imposé par ce délai.
  MealStorageMode get mode => mealStorageMode(daysAhead);

  /// Vrai quand le plat attend réellement : sinon il n'y a rien à conserver.
  bool get isAhead => daysAhead > 0;

  /// Consigne calculée, indépendante de toute génération de texte.
  String get instruction => mealStorageInstruction(daysAhead);

  static String _formatDay(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  /// Paramètres d'adresse à joindre à `/recipes/{id}`.
  Map<String, String> toQueryParameters() => {
    kPrepDateQueryParam: _formatDay(prepDate),
    kMealDateQueryParam: _formatDay(mealDate),
  };

  /// Relit le contexte depuis une adresse, ou null s'il n'y en a pas.
  ///
  /// Une date illisible n'est pas une erreur à remonter : c'est une adresse
  /// bricolée à la main, et la recette s'ouvre alors sans contexte.
  static MealPrepContext? fromQueryParameters(Map<String, String> params) {
    final prep = DateTime.tryParse(params[kPrepDateQueryParam] ?? '');
    final meal = DateTime.tryParse(params[kMealDateQueryParam] ?? '');
    if (prep == null || meal == null) return null;
    return MealPrepContext(prepDate: prep, mealDate: meal);
  }
}
