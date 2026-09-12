/// Ce que la fenêtre de variété regarde : les repas servis avant un cycle.
///
/// « Ne pas reproposer un plat servi dans les N dernières semaines » se décide
/// ici, côté client, à partir des repas déjà planifiés de l'utilisateur. Le
/// serveur reçoit la liste et retire ces recettes du corpus tant qu'il en
/// reste assez : un candidat absent est une certitude, une consigne dans le
/// prompt est un vœu.
library;

import 'planned_meal.dart';

/// Un repas servi avant le cycle, tel qu'il part au serveur.
typedef RecentlyServedMeal = ({
  String recipeId,
  String titre,
  DateTime servedAt,
});

/// Bornes de la fenêtre de variété, en semaines. Zéro la désactive.
const int kVarietyWindowMinWeeks = 0;
const int kVarietyWindowMaxWeeks = 4;
const int kVarietyWindowDefaultWeeks = 2;

/// Ramène une valeur lue dans les préférences entre les bornes admises.
int clampVarietyWindow(int weeks) =>
    weeks.clamp(kVarietyWindowMinWeeks, kVarietyWindowMaxWeeks);

/// Les repas servis dans les [windowWeeks] semaines qui précèdent
/// [cycleStart], du plus récent au plus ancien, une fois par recette.
///
/// La fenêtre se compte depuis le premier jour du cycle et non depuis
/// aujourd'hui : planifier la semaine prochaine un mercredi doit regarder les
/// mêmes repas que la planifier un dimanche. Un repas sans recette est un
/// créneau resté vide, pas un plat servi. Un repas du cycle lui-même n'en fait
/// pas partie : il sera remplacé ou doublé à la validation, ce n'est pas de
/// l'historique.
List<RecentlyServedMeal> recentlyServedBefore(
  Iterable<PlannedMeal> meals, {
  required DateTime cycleStart,
  required int windowWeeks,
}) {
  final weeks = clampVarietyWindow(windowWeeks);
  if (weeks == 0) return const [];
  // Borne haute exclue : le premier jour du cycle n'est pas « avant ».
  final end = DateTime(cycleStart.year, cycleStart.month, cycleStart.day);
  final start = DateTime(end.year, end.month, end.day - 7 * weeks);
  final byRecipe = <String, RecentlyServedMeal>{};
  for (final meal in meals) {
    final id = meal.recipeId;
    if (id == null || id.isEmpty) continue;
    final day = DateTime(
      meal.plannedAt.year,
      meal.plannedAt.month,
      meal.plannedAt.day,
    );
    if (day.isBefore(start) || !day.isBefore(end)) continue;
    final existing = byRecipe[id];
    if (existing == null || existing.servedAt.isBefore(meal.plannedAt)) {
      byRecipe[id] = (
        recipeId: id,
        titre: meal.recipeTitre,
        servedAt: meal.plannedAt,
      );
    }
  }
  final out = byRecipe.values.toList(growable: false)
    ..sort((a, b) => b.servedAt.compareTo(a.servedAt));
  return out;
}

/// Premier jour lu par la fenêtre, pour ne charger que les repas utiles.
DateTime varietyWindowStart({
  required DateTime cycleStart,
  required int windowWeeks,
}) {
  final weeks = clampVarietyWindow(windowWeeks);
  return DateTime(
    cycleStart.year,
    cycleStart.month,
    cycleStart.day - 7 * weeks,
  );
}
