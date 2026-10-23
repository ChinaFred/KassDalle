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
  ///
  /// Même lecture que `parseSchedule` côté serveur (fixture
  /// `test-fixtures/backfill_schedule.json`) : heure et jours entiers, sans
  /// conversion — « 5 », 5.5, `null` ou `true` rendent l'entrée illisible ;
  /// `enabled` ne vaut vrai que pour le booléen `true`.
  static BackfillSchedule? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final hour = _strictInt(raw['hour'], 0, 23);
    final rawDays = raw['days'];
    if (hour == null || rawDays is! List) return null;
    final days = <int>{};
    for (final d in rawDays) {
      final day = _strictInt(d, 1, 7);
      if (day == null) return null;
      days.add(day);
    }
    final sorted = days.toList()..sort();
    final uid = raw['programme_par_uid'];
    final trimmed = uid is String ? uid.trim() : '';
    return BackfillSchedule(
      enabled: raw['enabled'] == true && sorted.isNotEmpty,
      days: List.unmodifiable(sorted),
      hour: hour,
      programmeParUid: trimmed.isEmpty ? null : trimmed,
    );
  }

  /// Un entier de [min] à [max] — un `num` sans partie décimale —, ou `null`.
  static int? _strictInt(Object? value, int min, int max) {
    if (value is! num || value != value.truncate()) return null;
    final n = value.toInt();
    return n >= min && n <= max ? n : null;
  }
}

/// Le document `app_config/backfill_schedules`, lu.
///
/// Tant que le document ne dit rien d'un backfill qui a un défaut au registre
/// (`defaultSchedule` — la nutrition, tous les jours à 5 h), c'est ce défaut
/// qui vaut : le serveur l'applique dès son premier passage horaire et l'écrit
/// alors dans le document. L'écran l'affiche « (par défaut) » et l'éditeur
/// en part, pour qu'un « Enregistrer » ne coupe pas le rattrapage quotidien.
class BackfillSchedules {
  final Map<String, Object?> _raw;

  const BackfillSchedules(this._raw);

  static const empty = BackfillSchedules({});

  /// La programmation qui vaut pour [key] : celle du document, sinon le défaut
  /// du registre ; `null` si l'entrée est illisible ou s'il n'y a ni l'une ni
  /// l'autre (« Non programmé »).
  BackfillSchedule? scheduleFor(String key) {
    if (_raw.containsKey(key)) return BackfillSchedule.fromMap(_raw[key]);
    final fallback = backfillDefinition(key)?.defaultSchedule;
    if (fallback == null) return null;
    return BackfillSchedule(
      enabled: true,
      days: fallback.days,
      hour: fallback.hour,
    );
  }

  /// Vrai quand [scheduleFor] rend le défaut du registre, faute d'entrée.
  bool isDefault(String key) =>
      !_raw.containsKey(key) &&
      backfillDefinition(key)?.defaultSchedule != null;
}

/// « Tous les dimanches à 3 h », « Lun., mer. et ven. à 3 h »,
/// « Tous les jours à 5 h » ou « Non programmé ». [isDefault] ajoute
/// « (par défaut) » : la programmation vient du registre, pas du document.
String backfillScheduleLabel(
  BackfillSchedule? schedule, {
  bool isDefault = false,
}) {
  final label = _scheduleLabel(schedule);
  return isDefault && (schedule?.isActive ?? false)
      ? '$label (par défaut)'
      : label;
}

String _scheduleLabel(BackfillSchedule? schedule) {
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

enum BackfillRunStatus {
  jamais,
  enCours,
  termine,
  incomplet,
  erreur,

  /// Verrou dont l'échéance (`en_cours_expire_le`, posée par le serveur) est
  /// passée : le passage a été interrompu.
  interrompu,
}

class BackfillRunState {
  final String key;
  final String? statut;
  final DateTime? enCoursDepuis;
  final DateTime? enCoursExpireLe;
  final String? enCoursOrigine;
  final DateTime? dernierPassageLe;
  final String? dernierPassageOrigine;
  final String? dernierPassageErreur;
  final bool arretPlafond;
  final bool repriseDue;

  /// Éléments traités par le dernier passage et restés en échec, sans être
  /// exclus (`echecs_restants`). Un passage au parcours fini qui en laisse est
  /// « incomplet » sans reprise à l'heure suivante : le serveur ne reposerait
  /// pas les mêmes questions une heure plus tard.
  final int echecsRestants;
  final Map<String, dynamic>? lastReport;
  final DateTime? termineLe;
  final String? termineVersion;
  final String? terminePar;

  const BackfillRunState({
    required this.key,
    this.statut,
    this.enCoursDepuis,
    this.enCoursExpireLe,
    this.enCoursOrigine,
    this.dernierPassageLe,
    this.dernierPassageOrigine,
    this.dernierPassageErreur,
    this.arretPlafond = false,
    this.repriseDue = false,
    this.echecsRestants = 0,
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
    final echecs = data['echecs_restants'];
    return BackfillRunState(
      key: key,
      statut: str('dernier_passage_statut'),
      enCoursDepuis: date('en_cours_depuis'),
      enCoursExpireLe: date('en_cours_expire_le'),
      enCoursOrigine: str('en_cours_origine'),
      dernierPassageLe: date('dernier_passage_le'),
      dernierPassageOrigine: str('dernier_passage_origine'),
      dernierPassageErreur: str('dernier_passage_erreur'),
      arretPlafond: data['arret_plafond'] == true,
      repriseDue: data['reprise_due'] == true,
      echecsRestants: echecs is num && echecs > 0 ? echecs.toInt() : 0,
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
        // L'échéance vient du serveur : la durée de vie du verrou n'existe
        // que là. Sans échéance, le verrou ne se date pas : interrompu.
        final expire = enCoursExpireLe;
        if (enCoursDepuis == null || expire == null || now.isAfter(expire)) {
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

  /// « , 4 exclus après 3 échecs » quand le compteur est positif, sinon rien.
  String exclus(String k, String singular, String plural) {
    final v = n(k);
    return v > 0 ? ', ${_count(v, singular, plural)} après 3 échecs' : '';
  }

  /// Un compteur cité seulement quand il est positif.
  String siPositif(String k, String singular, String plural) {
    final v = n(k);
    return v > 0 ? ', ${_count(v, singular, plural)}' : '';
  }

  String restantes(String k, String singular, String plural) {
    final v = report[k];
    if (v is! num) return 'reste inconnu';
    return _count(v.toInt(), singular, plural);
  }

  switch (key) {
    case BackfillKeys.nutrition:
      // « laissees » ne compte que les recettes laissées faute de temps ou de
      // plafond : les appeler « restantes » faisait lire « 0 restante » à côté
      // de neuf recettes reprises sans succès.
      return '${_count(n('reprises'), 'reprise', 'reprises')}, '
          '${_count(n('completees'), 'complétée', 'complétées')}, '
          '${_count(n('echouees'), 'encore incomplète', 'encore incomplètes')}'
          '${siPositif('laissees', 'laissée faute de temps', 'laissées faute de temps')}'
          '${siPositif('nonReprenables', 'sans reprise possible', 'sans reprise possible')}'
          '${siPositif('abandonnees', 'abandonnée', 'abandonnées')}';
    case BackfillKeys.enrichReferentials:
      return '${_count(n('enrichedUnits'), 'unité enrichie', 'unités enrichies')}, '
          '${_count(n('enrichedIngredients'), 'ingrédient enrichi', 'ingrédients enrichis')}, '
          '${_count(n('failedIngredients'), 'échec', 'échecs')}'
          '${exclus('excludedUnits', 'unité exclue', 'unités exclues')}'
          '${exclus('excludedIngredients', 'ingrédient exclu', 'ingrédients exclus')}';
    case BackfillKeys.allergens:
      return '${_count(n('ingredientsExamines'), 'ingrédient examiné', 'ingrédients examinés')}, '
          '${_count(n('recettesCalculees'), 'recette recalculée', 'recettes recalculées')}, '
          '${_count(n('recettesIncompletes'), 'incomplète', 'incomplètes')}'
          '${exclus('ingredientsExclus', 'ingrédient exclu', 'ingrédients exclus')}';
    case BackfillKeys.recipeRoles:
      return '${_count(n('classees'), 'classée', 'classées')}, '
          '${restantes('restantes', 'restante', 'restantes')}'
          '${exclus('exclues', 'recette exclue', 'recettes exclues')}';
    case BackfillKeys.shoppingProducts:
      return '${_count(n('recalculees'), 'recalculée', 'recalculées')}, '
          '${_count(n('identiques'), 'identique', 'identiques')}, '
          '${_count(n('echouees'), 'échec', 'échecs')}';
    case BackfillKeys.refreshSodium:
      return '${_count(n('refreshedIngredients'), 'ingrédient repris', 'ingrédients repris')}, '
          '${_count(n('failedIngredients'), 'échec', 'échecs')}';
    case BackfillKeys.retention:
      return '${_count(n('rapportsSupprimes'), 'rapport supprimé', 'rapports supprimés')}, '
          '${_count(n('capturesSupprimees'), 'capture supprimée', 'captures supprimées')}'
          '${siPositif('capturesEchouees', 'échec', 'échecs')}'
          '${siPositif('lotsRapportsEchoues', 'lot de rapports en échec', 'lots de rapports en échec')}';
    default:
      return '';
  }
}

/// Le menu ⋮ d'une tuile propose-t-il « Marquer comme terminé » ou
/// « Remettre à lancer » ? Un ponctuel, oui ; un récurrent, non.
bool backfillOffersDoneMenu(BackfillDefinition def) => !def.isRecurrent;

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
      // Parcours fini, mais des éléments en échec : pas de reprise à l'heure
      // suivante. Ils reviennent au prochain passage programmé, s'il y en a
      // un ; sinon, seul un passage manuel les reprend.
      if (state.echecsRestants > 0) {
        final echecs = _count(
          state.echecsRestants,
          'élément en échec',
          'éléments en échec',
        );
        final next = def.isRecurrent ? nextScheduledRun(schedule, now) : null;
        return next == null
            ? 'Incomplet$when$withSummary · $echecs. Relancez pour réessayer.'
            : 'Incomplet$when$withSummary · $echecs, nouvel essai '
                  '${formatNextRunShort(next, now)}';
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

/// Texte de « Copier la liste » des ponctuels terminés : une ligne par
/// backfill, dans l'ordre de l'écran — clé technique, titre, date et version
/// de fin, manuel ou automatique, dernier compte rendu et éléments à revoir.
///
/// La session qui retire un ponctuel du code le demande à l'administrateur
/// (skill `backfill`, « Retrait ») : il dit ce qui a tourné, sans capture.
String backfillDoneListText(
  List<BackfillDefinition> done,
  Map<String, BackfillRunState> states,
) {
  final lines = <String>[];
  for (final def in done) {
    final state = states[def.key];
    final at = state?.termineLe;
    final known = [
      if (at != null) 'le ${formatParisDate(at)}',
      if (state?.termineVersion != null) 'en v${state!.termineVersion}',
    ];
    final missing = [
      if (at == null) 'date inconnue',
      if (state?.termineVersion == null) 'version inconnue',
    ];
    final end = [
      'terminé',
      ...known,
      if (missing.isNotEmpty) '(${missing.join(', ')})',
    ].join(' ');
    final by = state?.terminePar == 'manuel'
        ? 'marqué à la main'
        : 'automatique';
    final summary = backfillReportSummary(def.key, state?.lastReport);
    final report = summary.isEmpty ? 'absent' : summary;
    final toReview = state?.failures?.total ?? 0;
    lines.add(
      '${def.key} — ${def.title} — $end — $by — '
      'dernier compte rendu : $report — à revoir : $toReview',
    );
  }
  return lines.join('\n');
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
