import '../../groups/domain/family_group.dart';

/// Les paramètres de « Déplacer mes repas vers un groupe » (Admin ›
/// Backfills) : le groupe cible et une période de jours locaux, inclusifs.
///
/// Le serveur ne connaît pas le fuseau de l'appareil : il reçoit les jours
/// (`AAAA-MM-JJ`, pour valider et pour le compte rendu) et les instants du
/// début du premier jour et du début du lendemain du dernier, calculés ici
/// dans le fuseau de l'appareil. Il sélectionne `startAt <= planned_at <
/// endAt` (`moveMealsToGroupBackfillCallable.ts`).
class MoveMealsRequest {
  /// Période la plus longue acceptée, en jours. Même valeur que
  /// `MAX_PERIOD_DAYS` côté serveur, qui la vérifie aussi.
  static const maxDays = 62;

  final String groupId;
  final String groupName;

  /// Premier et dernier jour, heure ignorée.
  final DateTime from;
  final DateTime to;

  MoveMealsRequest({
    required this.groupId,
    required this.groupName,
    required DateTime from,
    required DateTime to,
  }) : from = DateTime(from.year, from.month, from.day),
       to = DateTime(to.year, to.month, to.day);

  /// Jours de la période, bornes comprises. Compté sur des dates UTC : un
  /// changement d'heure ne retire pas un jour.
  int get dayCount =>
      DateTime.utc(
        to.year,
        to.month,
        to.day,
      ).difference(DateTime.utc(from.year, from.month, from.day)).inDays +
      1;

  bool get isValid => dayCount >= 1 && dayCount <= maxDays;

  String get fromDay => _isoDay(from);
  String get toDay => _isoDay(to);

  /// Minuit local du premier jour, en millisecondes.
  int get startAt => from.millisecondsSinceEpoch;

  /// Minuit local du lendemain du dernier jour, en millisecondes, exclu.
  int get endAt =>
      DateTime(to.year, to.month, to.day + 1).millisecondsSinceEpoch;

  Map<String, dynamic> toPayload() => {
    'groupId': groupId,
    'fromDay': fromDay,
    'toDay': toDay,
    'startAt': startAt,
    'endAt': endAt,
  };

  /// « Déplacer vos repas du ven. 8 au jeu. 14 mars vers « Groupe » ? »
  String get confirmQuestion =>
      'Déplacer vos repas ${formatShortPeriod(from, to)} vers « $groupName » ?';
}

/// Les groupes vers lesquels l'appelant peut déplacer ses repas : ceux dont
/// il est propriétaire et qui ne sont pas en pause, triés par nom.
List<FamilyGroup> ownedActiveGroups(
  Iterable<FamilyGroup> groups,
  Set<String> pausedIds,
  String uid,
) {
  return [
    for (final g in groups)
      if (g.ownerId == uid && !pausedIds.contains(g.id)) g,
  ]..sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
}

const _weekdays = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
const _months = [
  'janv.',
  'févr.',
  'mars',
  'avr.',
  'mai',
  'juin',
  'juil.',
  'août',
  'sept.',
  'oct.',
  'nov.',
  'déc.',
];

String _isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _dayNumber(DateTime d) => d.day == 1 ? '1er' : '${d.day}';

/// « du ven. 8 au jeu. 14 mars », « du lun. 30 sept. au jeu. 3 oct. »,
/// « du mar. 31 déc. 2030 au mer. 1er janv. 2031 », « du ven. 8 mars ».
String formatShortPeriod(DateTime from, DateTime to) {
  String day(DateTime d) => '${_weekdays[d.weekday - 1]} ${_dayNumber(d)}';
  String month(DateTime d) => _months[d.month - 1];
  if (from.year == to.year && from.month == to.month && from.day == to.day) {
    return 'du ${day(from)} ${month(from)}';
  }
  if (from.year != to.year) {
    return 'du ${day(from)} ${month(from)} ${from.year} '
        'au ${day(to)} ${month(to)} ${to.year}';
  }
  if (from.month != to.month) {
    return 'du ${day(from)} ${month(from)} au ${day(to)} ${month(to)}';
  }
  return 'du ${day(from)} au ${day(to)} ${month(to)}';
}
