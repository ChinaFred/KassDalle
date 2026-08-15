/// Règles de créneau du planning, partagées avec le backend.
///
/// Ces quatre décisions existent en double, ici et dans
/// `functions/src/gemini/planning.ts` : le serveur les applique pour composer
/// le prompt et dédoublonner la réponse du modèle, le client les rejoue comme
/// filet de sécurité quand un créneau revient vide.
///
/// Un écart entre les deux ne casse aucun écran et ne lève aucune erreur : il
/// laisse passer un dessert d'un côté, décale un jour de préparation de l'autre.
/// Les cas vivent dans `test-fixtures/planning_slot_rules.json`, rejoués par
/// les deux suites.
library;

/// Marqueurs d'une demande explicite de sucré dans les contraintes.
const _dessertRequestMarkers = [
  'dessert',
  'sucre',
  'sucré',
  'gouter',
  'goûter',
  'petit dej',
  'petit-déj',
  'petit dejeuner',
  'petit-déjeuner',
  'brunch',
];

/// Marqueurs identifiant une recette sucrée.
const _dessertRecipeMarkers = [
  'dessert',
  'sucre',
  'sucré',
  'gateau',
  'gâteau',
  'tarte',
  'beignet',
  'crepe',
  'crêpe',
  'brownie',
  'cookie',
  'mousse',
  'patis',
  'pâtis',
  'glace',
  'sorbet',
  'banane split',
];

/// Vrai si les contraintes demandent explicitement du sucré.
bool planningAsksForDessert(String globalConstraints, String dailyNotes) {
  final text = '$globalConstraints $dailyNotes'.toLowerCase();
  return _dessertRequestMarkers.any(text.contains);
}

/// Vrai si les attributs d'une recette (titre, types, thèmes, occasions)
/// la désignent comme sucrée.
bool planningIsDessertBag(Iterable<String> attributes) {
  final bag = attributes.join(' ').toLowerCase();
  return _dessertRecipeMarkers.any(bag.contains);
}

/// Nature d'un créneau : `batch`, `reheat` ou `regular`.
///
/// Le jour de batch cooking l'emporte : on y sert un vrai repas du cycle, pas
/// un réchauffage, même si le jour porte aussi la case « réchauffage ».
String planningSlotKind({
  required int slotWeekday,
  required bool isReheatConstraint,
  required int? batchCookingDay,
}) {
  if (batchCookingDay != null && slotWeekday == batchCookingDay) return 'batch';
  if (isReheatConstraint) return 'reheat';
  return 'regular';
}

/// Date du dernier jour de batch cooking précédant [slotDate].
///
/// Un créneau tombant le jour de batch renvoie la semaine précédente : on ne
/// prépare pas à l'avance un plat servi le jour même.
DateTime planningPrepDate(DateTime slotDate, int batchCookingWeekday) {
  var daysBack = (slotDate.weekday - batchCookingWeekday + 7) % 7;
  if (daysBack == 0) daysBack = 7;
  return DateTime.utc(
    slotDate.year,
    slotDate.month,
    slotDate.day,
  ).subtract(Duration(days: daysBack));
}
