/// La semaine de planning : sept jours à partir du jour de démarrage du cycle.
///
/// C'est l'unité de lecture de l'écran Planning. Elle suit le découpage de
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

/// Une période de lecture du planning : des jours consécutifs, du [start] au
/// [end] inclus.
///
/// La période par défaut est une [PlanningWeek]. Une période libre — du
/// vendredi au mercredi, ou deux semaines à partir d'un lundi — se choisit
/// dans le calendrier et n'est pas stockée : elle disparaît à la fermeture de
/// l'écran.
class PlanningPeriod {
  /// Premier jour, à minuit heure locale.
  final DateTime start;

  /// Dernier jour inclus, à minuit heure locale.
  final DateTime end;

  /// Longueur maximale d'une période libre. Au-delà, la liste des jours
  /// devient trop longue à lire.
  static const maxLength = 31;

  PlanningPeriod(DateTime start, DateTime end)
    : start = DateTime(start.year, start.month, start.day),
      end = DateTime(end.year, end.month, end.day),
      assert(!end.isBefore(start));

  /// La période qui va de [a] à [b], dans l'ordre où elles tombent.
  factory PlanningPeriod.between(DateTime a, DateTime b) =>
      b.isBefore(a) ? PlanningPeriod(b, a) : PlanningPeriod(a, b);

  /// Nombre de jours, bornes comprises. Le calcul passe par UTC : un
  /// changement d'heure ne retire pas de jour.
  int get length =>
      DateTime.utc(
        end.year,
        end.month,
        end.day,
      ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
      1;

  /// Les jours, dans l'ordre.
  List<DateTime> get days => List.generate(length, _dayPlus);

  /// La période de même longueur qui suit, ou qui précède.
  PlanningPeriod get next => shifted(length);
  PlanningPeriod get previous => shifted(-length);

  PlanningPeriod shifted(int days) =>
      PlanningPeriod(_dayPlus(days), _dayPlus(length - 1 + days));

  /// Vrai si [day] tombe dans la période, quelle que soit son heure.
  bool contains(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    return !d.isBefore(start) && !d.isAfter(end);
  }

  // Le constructeur normalise : passer par un changement d'heure ne décale
  // pas le jour, là où `add(Duration(days: n))` rend 23 h la veille.
  DateTime _dayPlus(int n) => DateTime(start.year, start.month, start.day + n);

  @override
  bool operator ==(Object other) =>
      other is PlanningPeriod && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() =>
      'PlanningPeriod(${start.toIso8601String()} → ${end.toIso8601String()})';
}

/// Sept jours, du [start] inclus au sixième jour suivant.
class PlanningWeek extends PlanningPeriod {
  PlanningWeek(DateTime start)
    : super(start, DateTime(start.year, start.month, start.day + 6));

  @override
  PlanningWeek get next => PlanningWeek(_dayPlus(7));
  @override
  PlanningWeek get previous => PlanningWeek(_dayPlus(-7));
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
/// cette période ; sans elle, toutes les semaines à venir.
List<PlannedMeal> mealsToShop(
  Iterable<PlannedMeal> meals, {
  required DateTime today,
  PlanningPeriod? week,
}) {
  final firstDay = DateTime(today.year, today.month, today.day);
  return [
    for (final meal in meals)
      if (!meal.plannedAt.isBefore(firstDay) &&
          (week == null || week.contains(meal.plannedAt)))
        meal,
  ];
}

/// Les semaines qui couvrent [month], dans l'ordre : une ligne du calendrier
/// chacune.
///
/// La première contient le 1er du mois, la dernière son dernier jour. Le
/// calendrier les demande à partir du lundi.
List<PlanningWeek> planningWeeksCovering(
  DateTime month, {
  required int cycleStartDay,
}) {
  final first = planningWeekOf(
    DateTime(month.year, month.month),
    cycleStartDay: cycleStartDay,
  );
  final lastDay = DateTime(month.year, month.month + 1, 0);
  final weeks = <PlanningWeek>[];
  for (var w = first; !w.start.isAfter(lastDay); w = w.next) {
    weeks.add(w);
  }
  return weeks;
}

/// Les lignes du calendrier, du lundi au dimanche, qui contiennent [period].
List<PlanningWeek> calendarRowsFor(PlanningPeriod period) {
  final rows = <PlanningWeek>[];
  for (
    var w = planningWeekOf(period.start, cycleStartDay: DateTime.monday);
    !w.start.isAfter(period.end);
    w = w.next
  ) {
    rows.add(w);
  }
  return rows;
}
