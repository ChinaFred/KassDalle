/// La semaine de planning : sept jours à partir du jour de démarrage du cycle.
///
/// C'est l'unité de lecture de l'onglet Liste. Elle suit le découpage de
/// « Nouveau planning » : un cycle y commence au [PlanningPreferences.cycleStartDay]
/// et dure `mealsPerCycle` jours — sept par défaut, donc une semaine. Quand le
/// cycle n'en fait pas sept, la semaine reste le repère : elle pave le
/// calendrier sans trou ni chevauchement, ce qu'un cycle de cinq jours ne
/// ferait pas.
///
/// Rien n'est stocké : une semaine est une position de lecture, pas une donnée
/// du planning.
library;

import 'planned_meal.dart';

/// Sept jours, du [start] inclus au sixième jour suivant.
class PlanningWeek {
  /// Premier jour, à minuit heure locale.
  final DateTime start;

  PlanningWeek(DateTime start)
    : start = DateTime(start.year, start.month, start.day);

  /// Dernier jour inclus.
  DateTime get end => _dayPlus(6);

  /// Les sept jours, dans l'ordre.
  List<DateTime> get days => List.generate(7, _dayPlus);

  PlanningWeek get next => PlanningWeek(_dayPlus(7));
  PlanningWeek get previous => PlanningWeek(_dayPlus(-7));

  /// Vrai si [day] tombe dans la semaine, quelle que soit son heure.
  bool contains(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  // Le constructeur normalise : passer par un changement d'heure ne décale
  // pas le jour, là où `add(Duration(days: n))` rend 23 h la veille.
  DateTime _dayPlus(int n) => DateTime(start.year, start.month, start.day + n);

  @override
  bool operator ==(Object other) =>
      other is PlanningWeek && other.start == start;

  @override
  int get hashCode => start.hashCode;

  @override
  String toString() => 'PlanningWeek(${start.toIso8601String()})';
}

/// La semaine contenant [day], pour un cycle qui démarre le [cycleStartDay]
/// (1 = lundi … 7 = dimanche, comme `DateTime.weekday`).
PlanningWeek planningWeekOf(DateTime day, {required int cycleStartDay}) {
  final d = DateTime(day.year, day.month, day.day);
  final back = (d.weekday - cycleStartDay + 7) % 7;
  return PlanningWeek(DateTime(d.year, d.month, d.day - back));
}

/// Les repas dont les ingrédients vont sur la liste de courses.
///
/// Seuls comptent ceux qui restent à cuisiner : le jour même compte, quelle
/// que soit l'heure du repas. Avec une [week], on ne garde que les repas de
/// cette semaine ; sans elle, toutes les semaines à venir — c'est la puce
/// « Tout » de l'onglet Liste.
List<PlannedMeal> mealsToShop(
  Iterable<PlannedMeal> meals, {
  required DateTime today,
  PlanningWeek? week,
}) {
  final firstDay = DateTime(today.year, today.month, today.day);
  return [
    for (final meal in meals)
      if (!meal.plannedAt.isBefore(firstDay) &&
          (week == null || week.contains(meal.plannedAt)))
        meal,
  ];
}

/// Les semaines à proposer dans la barre de navigation.
///
/// De la plus ancienne qui porte un repas à la plus tardive, sans trou, en
/// couvrant toujours la semaine d'aujourd'hui et la suivante : on doit pouvoir
/// aller planifier la semaine prochaine même quand rien n'y est encore prévu.
/// [alsoCover] force la présence d'autres jours — la semaine où l'on se trouve
/// après avoir navigué au-delà des repas.
List<PlanningWeek> planningWeeksFor({
  required Iterable<DateTime> mealDays,
  required DateTime today,
  required int cycleStartDay,
  Iterable<DateTime> alsoCover = const [],
}) {
  final thisWeek = planningWeekOf(today, cycleStartDay: cycleStartDay);
  var first = thisWeek;
  var last = thisWeek.next;
  for (final day in mealDays.followedBy(alsoCover)) {
    final week = planningWeekOf(day, cycleStartDay: cycleStartDay);
    if (week.start.isBefore(first.start)) first = week;
    if (week.start.isAfter(last.start)) last = week;
  }
  final weeks = <PlanningWeek>[];
  for (var w = first; !w.start.isAfter(last.start); w = w.next) {
    weeks.add(w);
  }
  return weeks;
}
