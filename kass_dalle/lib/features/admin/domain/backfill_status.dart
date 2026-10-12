/// État et programmation des backfills d'Admin › Backfills — modèles et
/// libellés, sans Firestore ni Flutter : tout se teste seul.
///
/// Deux sources, écrites par le serveur seul :
///
/// - `app_config/backfill_run_<clé>` : l'état d'un backfill — dernier passage,
///   verrou, compte rendu, « terminé » (`functions/src/backfills/runner.ts`) ;
/// - `app_config/backfill_schedules` : la programmation des récurrents, une
///   entrée par clé (`setBackfillScheduleFn`).
///
/// Les heures s'affichent à l'heure de Paris, celle de la programmation.
library;

import 'backfill_failures.dart';
import 'backfill_registry.dart';

// ── Heure de Paris ──────────────────────────────────────────────────────────

/// Heure d'été de l'Union européenne : du dernier dimanche de mars au dernier
/// dimanche d'octobre, à 1 h UTC. Règle de la directive 2000/84/CE.
bool _isEuSummerTime(DateTime utc) {
  DateTime lastSunday(int year, int month) {
    final lastDay = DateTime.utc(year, month + 1, 0);
    return DateTime.utc(year, month, lastDay.day - lastDay.weekday % 7, 1);
  }

  final start = lastSunday(utc.year, 3);
  final end = lastSunday(utc.year, 10);
  return !utc.isBefore(start) && utc.isBefore(end);
}

/// L'heure murale de Paris pour l'instant [instant], rendue comme une
/// `DateTime` UTC dont les champs sont ceux de Paris. Sert à l'affichage et
/// à la comparaison avec la programmation, jamais à un calcul de durée.
DateTime parisWallTime(DateTime instant) {
  final utc = instant.toUtc();
  return utc.add(Duration(hours: _isEuSummerTime(utc) ? 2 : 1));
}

const _weekdaysShort = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
const _weekdaysLong = [
  'lundi',
  'mardi',
  'mercredi',
  'jeudi',
  'vendredi',
  'samedi',
  'dimanche',
];
const _months = [
  'janvier',
  'février',
  'mars',
  'avril',
  'mai',
  'juin',
  'juillet',
  'août',
  'septembre',
  'octobre',
  'novembre',
  'décembre',
];

String _two(int n) => n.toString().padLeft(2, '0');

/// « 03:02 », heure de Paris.
String formatParisTime(DateTime instant) {
  final p = parisWallTime(instant);
  return '${_two(p.hour)}:${_two(p.minute)}';
}

/// « dim. 11/10 à 03:02 », heure de Paris.
String formatParisDateTime(DateTime instant) {
  final p = parisWallTime(instant);
  return '${_weekdaysShort[p.weekday - 1]} ${_two(p.day)}/${_two(p.month)} '
      'à ${_two(p.hour)}:${_two(p.minute)}';
}

/// « 10/10/2026 », heure de Paris.
String formatParisDate(DateTime instant) {
  final p = parisWallTime(instant);
  return '${_two(p.day)}/${_two(p.month)}/${p.year}';
}

/// « 3 h ».
String formatHour(int hour) => '$hour h';

// ── Programmation ───────────────────────────────────────────────────────────

/// Jours ISO : lundi = 1 … dimanche = 7.
const List<int> kAllBackfillDays = [1, 2, 3, 4, 5, 6, 7];

class BackfillSchedule {
  final bool enabled;

  /// Jours ISO, triés, sans doublon.
  final List<int> days;

  /// Heure de Paris, 0 à 23.
  final int hour;

  /// Administrateur imputé, `null` pour le défaut de la nutrition.
  final String? programmeParUid;

  const BackfillSchedule({
    required this.enabled,
    required this.days,
    required this.hour,
    this.programmeParUid,
  });

  bool get isActive => enabled && days.isNotEmpty;

  /// Lit une entrée stockée ; `null` si elle est mal formée.
  static BackfillSchedule? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final rawDays = raw['days'];
    final rawHour = raw['hour'];
    if (rawDays is! List || rawHour is! num) return null;
    final hour = rawHour.toInt();
    if (hour < 0 || hour > 23) return null;
    final days = <int>{
      for (final d in rawDays)
        if (d is num && d.toInt() >= 1 && d.toInt() <= 7) d.toInt(),
    }.toList()..sort();
    final uid = raw['programme_par_uid'];
    return BackfillSchedule(
      enabled: raw['enabled'] == true && days.isNotEmpty,
      days: List.unmodifiable(days),
      hour: hour,
      programmeParUid: uid is String && uid.trim().isNotEmpty ? uid : null,
    );
  }
}

/// Programmations appliquées sans réglage stocké. Même valeur que
/// `DEFAULT_BACKFILL_SCHEDULES` côté serveur : la nutrition reprend tous les
/// jours à 5 h, comme l'ancienne tâche `scheduledNutritionCatchUp`.
const Map<String, BackfillSchedule> kDefaultBackfillSchedules = {
  BackfillKeys.nutrition: BackfillSchedule(
    enabled: true,
    days: kAllBackfillDays,
    hour: 5,
  ),
};

/// Le document `app_config/backfill_schedules`, lu.
class BackfillSchedules {
  final Map<String, Object?> _raw;

  const BackfillSchedules(this._raw);

  static const empty = BackfillSchedules({});

  /// La programmation qui vaut pour [key] : celle du document, ou le défaut
  /// si le document ne dit rien de cette clé. Une entrée illisible vaut
  /// « non programmé ».
  BackfillSchedule? scheduleFor(String key) {
    if (!_raw.containsKey(key)) return kDefaultBackfillSchedules[key];
    return BackfillSchedule.fromMap(_raw[key]);
  }
}

/// « Tous les dimanches à 3 h », « Lun., mer. et ven. à 3 h »,
/// « Tous les jours à 5 h » ou « Non programmé ».
String backfillScheduleLabel(BackfillSchedule? schedule) {
  if (schedule == null || !schedule.isActive) return 'Non programmé';
  final at = 'à ${formatHour(schedule.hour)}';
  final days = schedule.days;
  if (days.length == 7) return 'Tous les jours $at';
  if (days.length == 1) return 'Tous les ${_weekdaysLong[days.first - 1]}s $at';
  final names = [for (final d in days) _weekdaysShort[d - 1]];
  final list =
      '${names.sublist(0, names.length - 1).join(', ')} et ${names.last}';
  return '${list[0].toUpperCase()}${list.substring(1)} $at';
}

/// Prochain créneau programmé strictement après [now], en heure murale de
/// Paris (voir [parisWallTime]) ; `null` si non programmé.
DateTime? nextScheduledRun(BackfillSchedule? schedule, DateTime now) {
  if (schedule == null || !schedule.isActive) return null;
  final utc = now.toUtc();
  final start = DateTime.utc(utc.year, utc.month, utc.day, utc.hour + 1);
  // Paris est à une heure ronde d'UTC : les heures pleines coïncident.
  for (var i = 0; i < 24 * 8; i++) {
    final wall = parisWallTime(start.add(Duration(hours: i)));
    if (schedule.days.contains(wall.weekday) && wall.hour == schedule.hour) {
      return wall;
    }
  }
  return null;
}

/// « dimanche 18 octobre à 3 h ».
String formatNextRunLong(DateTime wall) =>
    '${_weekdaysLong[wall.weekday - 1]} ${wall.day} ${_months[wall.month - 1]} '
    'à ${formatHour(wall.hour)}';

/// « aujourd'hui à 03:00 », « demain à 03:00 » ou « dim. 18/10 à 03:00 ».
String formatNextRunShort(DateTime wall, DateTime now) {
  final today = parisWallTime(now);
  final day = DateTime.utc(wall.year, wall.month, wall.day);
  final base = DateTime.utc(today.year, today.month, today.day);
  final diff = day.difference(base).inDays;
  final time = '${_two(wall.hour)}:${_two(wall.minute)}';
  if (diff == 0) return 'aujourd\'hui à $time';
  if (diff == 1) return 'demain à $time';
  return '${_weekdaysShort[wall.weekday - 1]} ${_two(wall.day)}/${_two(wall.month)} à $time';
}

/// Résumé du contrôle de programmation : « Tous les dimanches à 3 h.
/// Prochain passage : dimanche 18 octobre à 3 h. »
String backfillScheduleSummary(BackfillSchedule schedule, DateTime now) {
  final next = nextScheduledRun(schedule, now);
  final label = backfillScheduleLabel(schedule);
  if (next == null) return '$label.';
  return '$label. Prochain passage : ${formatNextRunLong(next)}.';
}

// ── État d'un backfill ──────────────────────────────────────────────────────

/// Durée de vie d'un verrou, comme `BACKFILL_LOCK_TTL_MS` côté serveur.
const Duration kBackfillLockTtl = Duration(minutes: 10);

enum BackfillRunStatus {
  jamais,
  enCours,
  termine,
  incomplet,
  erreur,

  /// Verrou plus vieux que [kBackfillLockTtl] : le passage a été interrompu.
  interrompu,
}

class BackfillRunState {
  final String key;
  final String? statut;
  final DateTime? enCoursDepuis;
  final String? enCoursOrigine;
  final DateTime? dernierPassageLe;
  final String? dernierPassageOrigine;
  final String? dernierPassageErreur;
  final bool arretPlafond;
  final bool repriseDue;
  final Map<String, dynamic>? lastReport;
  final DateTime? termineLe;
  final String? termineVersion;
  final String? terminePar;

  const BackfillRunState({
    required this.key,
    this.statut,
    this.enCoursDepuis,
    this.enCoursOrigine,
    this.dernierPassageLe,
    this.dernierPassageOrigine,
    this.dernierPassageErreur,
    this.arretPlafond = false,
    this.repriseDue = false,
    this.lastReport,
    this.termineLe,
    this.termineVersion,
    this.terminePar,
  });

  /// Lit un document d'état dont les horodatages ont déjà été convertis en
  /// `DateTime` par le repository.
  factory BackfillRunState.fromMap(String key, Map<String, dynamic> data) {
    String? str(String k) {
      final v = data[k];
      return v is String && v.isNotEmpty ? v : null;
    }

    DateTime? date(String k) {
      final v = data[k];
      return v is DateTime ? v : null;
    }

    final report = data['last_report'];
    return BackfillRunState(
      key: key,
      statut: str('dernier_passage_statut'),
      enCoursDepuis: date('en_cours_depuis'),
      enCoursOrigine: str('en_cours_origine'),
      dernierPassageLe: date('dernier_passage_le'),
      dernierPassageOrigine: str('dernier_passage_origine'),
      dernierPassageErreur: str('dernier_passage_erreur'),
      arretPlafond: data['arret_plafond'] == true,
      repriseDue: data['reprise_due'] == true,
      lastReport: report is Map ? Map<String, dynamic>.from(report) : null,
      termineLe: date('termine_le'),
      termineVersion: str('termine_version'),
      terminePar: str('termine_par'),
    );
  }

  bool get isDone => termineLe != null;

  BackfillRunStatus status(DateTime now) {
    switch (statut) {
      case 'en_cours':
        final depuis = enCoursDepuis;
        if (depuis == null || now.difference(depuis) > kBackfillLockTtl) {
          return BackfillRunStatus.interrompu;
        }
        return BackfillRunStatus.enCours;
      case 'termine':
        return BackfillRunStatus.termine;
      case 'incomplet':
        return BackfillRunStatus.incomplet;
      case 'erreur':
        return BackfillRunStatus.erreur;
      default:
        return BackfillRunStatus.jamais;
    }
  }

  /// Liste « à revoir » du dernier passage.
  BackfillFailures? get failures =>
      BackfillFailures.fromMap(lastReport?['aRevoir']);
}

String _origine(String? origin) =>
    origin == 'programme' ? 'programmé' : 'manuel';

String _count(int n, String singular, String plural) =>
    '$n ${n > 1 ? plural : singular}';

/// Résumé chiffré du dernier compte rendu : « 38 traitées, 0 restante ».
/// Vide quand le compte rendu manque.
String backfillReportSummary(String key, Map<String, dynamic>? report) {
  if (report == null) return '';
  int n(String k) => (report[k] as num?)?.toInt() ?? 0;
  String restantes(String k, String singular, String plural) {
    final v = report[k];
    if (v is! num) return 'reste inconnu';
    return _count(v.toInt(), singular, plural);
  }

  switch (key) {
    case BackfillKeys.nutrition:
      return '${_count(n('reprises'), 'reprise', 'reprises')}, '
          '${_count(n('completees'), 'complétée', 'complétées')}, '
          '${_count(n('laissees'), 'restante', 'restantes')}';
    case BackfillKeys.enrichReferentials:
      return '${_count(n('enrichedUnits'), 'unité enrichie', 'unités enrichies')}, '
          '${_count(n('enrichedIngredients'), 'ingrédient enrichi', 'ingrédients enrichis')}, '
          '${_count(n('failedIngredients'), 'échec', 'échecs')}';
    case BackfillKeys.allergens:
      return '${_count(n('ingredientsExamines'), 'ingrédient examiné', 'ingrédients examinés')}, '
          '${_count(n('recettesCalculees'), 'recette recalculée', 'recettes recalculées')}, '
          '${_count(n('recettesIncompletes'), 'incomplète', 'incomplètes')}';
    case BackfillKeys.recipeRoles:
      return '${_count(n('classees'), 'classée', 'classées')}, '
          '${restantes('restantes', 'restante', 'restantes')}';
    case BackfillKeys.shoppingProducts:
      return '${_count(n('recalculees'), 'recalculée', 'recalculées')}, '
          '${_count(n('identiques'), 'identique', 'identiques')}, '
          '${_count(n('echouees'), 'échec', 'échecs')}';
    case BackfillKeys.recipeProtein:
      return '${_count(n('traitees'), 'traitée', 'traitées')}, '
          '${restantes('restantes', 'restante', 'restantes')}';
    case BackfillKeys.estimatedTimes:
      return '${_count(n('estimees'), 'estimée', 'estimées')}, '
          '${_count(n('enErreur'), 'en erreur', 'en erreur')}';
    case BackfillKeys.refreshSodium:
      return '${_count(n('refreshedIngredients'), 'ingrédient repris', 'ingrédients repris')}, '
          '${_count(n('failedIngredients'), 'échec', 'échecs')}';
    case BackfillKeys.planningDefaults:
      return '${_count(n('poses') + n('completes'), 'compte mis à jour', 'comptes mis à jour')}, '
          '${_count(n('restants'), 'restant', 'restants')}';
    default:
      return '';
  }
}

/// La ligne d'état d'une tuile, selon la proposition validée.
///
/// [schedule] ne sert qu'aux récurrents : il date la reprise.
String backfillStatusLine({
  required BackfillDefinition def,
  required BackfillRunState? state,
  required BackfillSchedule? schedule,
  required DateTime now,
}) {
  final status = state?.status(now) ?? BackfillRunStatus.jamais;
  final at = state?.dernierPassageLe;
  final when = at == null ? '' : ' — ${formatParisDateTime(at)}';
  final summary = backfillReportSummary(def.key, state?.lastReport);
  final withSummary = summary.isEmpty ? '' : ' · $summary';

  switch (status) {
    case BackfillRunStatus.jamais:
      return def.isRecurrent
          ? 'Jamais lancé. Lancez un premier passage ou programmez-le.'
          : 'Jamais lancé.';
    case BackfillRunStatus.enCours:
      final depuis = state!.enCoursDepuis!;
      return 'En cours depuis ${formatParisTime(depuis)} '
          '(${_origine(state.enCoursOrigine)})';
    case BackfillRunStatus.interrompu:
      return 'En erreur — passage interrompu';
    case BackfillRunStatus.erreur:
      final message = state?.dernierPassageErreur ?? 'erreur inconnue';
      return 'En erreur$when : $message';
    case BackfillRunStatus.termine:
      final origin = ', ${_origine(state?.dernierPassageOrigine)}';
      return 'Terminé$when$origin$withSummary';
    case BackfillRunStatus.incomplet:
      if (state!.arretPlafond) {
        final next = def.isRecurrent ? nextScheduledRun(schedule, now) : null;
        return next == null
            ? 'Incomplet — plafond de dépense atteint. Relancez pour continuer.'
            : 'Incomplet — plafond de dépense atteint · reprise '
                  '${formatNextRunShort(next, now)}';
      }
      if (def.isRecurrent &&
          state.repriseDue &&
          (schedule?.isActive ?? false)) {
        final utc = now.toUtc();
        final nextHour = DateTime.utc(
          utc.year,
          utc.month,
          utc.day,
          utc.hour + 1,
        );
        return 'Incomplet$when$withSummary · reprise à '
            '${formatParisTime(nextHour)}';
      }
      return 'Incomplet$when$withSummary. Relancez pour continuer.';
  }
}

/// « Terminé le 10/10/2026 en v0.23.30 — à retirer du code (automatique) ».
String backfillDoneLine(BackfillRunState state) {
  final at = state.termineLe;
  final date = at == null ? '' : ' le ${formatParisDate(at)}';
  final version = state.termineVersion == null
      ? ''
      : ' en v${state.termineVersion}';
  final by = state.terminePar == 'manuel'
      ? '(marqué à la main)'
      : '(automatique)';
  return 'Terminé$date$version — à retirer du code $by';
}

// ── Rangement ───────────────────────────────────────────────────────────────

/// Les trois sections de l'écran, dans l'ordre fixe du registre.
class BackfillSections {
  final List<BackfillDefinition> recurrents;
  final List<BackfillDefinition> ponctuelsALancer;
  final List<BackfillDefinition> ponctuelsTermines;

  const BackfillSections({
    required this.recurrents,
    required this.ponctuelsALancer,
    required this.ponctuelsTermines,
  });
}

/// Range [registry] : récurrents, ponctuels à lancer, ponctuels terminés.
/// Un état absent (lecture en cours ou en échec) laisse le ponctuel à lancer.
BackfillSections backfillSections(
  List<BackfillDefinition> registry,
  Map<String, BackfillRunState> states,
) {
  final recurrents = <BackfillDefinition>[];
  final aLancer = <BackfillDefinition>[];
  final termines = <BackfillDefinition>[];
  for (final def in registry) {
    if (def.isRecurrent) {
      recurrents.add(def);
    } else if (states[def.key]?.isDone ?? false) {
      termines.add(def);
    } else {
      aLancer.add(def);
    }
  }
  return BackfillSections(
    recurrents: List.unmodifiable(recurrents),
    ponctuelsALancer: List.unmodifiable(aLancer),
    ponctuelsTermines: List.unmodifiable(termines),
  );
}
