import 'ticket.dart';
import 'ticket_form.dart' show parisDayKey;

/// Les deux routines Claude Code qu'un administrateur lance depuis la fiche
/// d'un ticket. [value] est la valeur stockée (`action`) et le premier mot du
/// texte que le serveur envoie à la routine.
enum TicketLaunchAction {
  analysis('analyse', TicketStatus.received),
  development('developpement', TicketStatus.validated);

  const TicketLaunchAction(this.value, this.fromStatus);

  final String value;

  /// Le statut d'où part le lancement, et qu'il doit garder pour rester
  /// « en cours ».
  final TicketStatus fromStatus;

  static TicketLaunchAction? fromValue(Object? value) {
    for (final a in values) {
      if (a.value == value) return a;
    }
    return null;
  }

  /// « Analyse lancée » / « Développement lancé ».
  String get historyTitle => switch (this) {
    TicketLaunchAction.analysis => 'Analyse lancée',
    TicketLaunchAction.development => 'Développement lancé',
  };

  /// « Analyse » / « Développement », en tête de la ligne « … en cours ».
  String get noun => switch (this) {
    TicketLaunchAction.analysis => 'Analyse',
    TicketLaunchAction.development => 'Développement',
  };
}

/// Résultat d'un lancement, tel qu'écrit par le serveur.
enum TicketLaunchOutcome {
  launched('launched'),
  failed('failed'),
  unknown('unknown');

  const TicketLaunchOutcome(this.value);

  final String value;

  static TicketLaunchOutcome? fromValue(Object? value) {
    for (final o in values) {
      if (o.value == value) return o;
    }
    return null;
  }
}

/// Une entrée de `tickets/{ticketId}/admin/launches.launches`, écrite par
/// `launchTicketAnalysis` et `launchTicketDevelopment` seules, lisible par
/// l'administrateur seul.
class TicketLaunch {
  final String id;

  /// Valeur stockée (`analyse`, `developpement`) ; [action] vaut `null` pour
  /// une valeur inconnue de cette version.
  final String rawAction;
  final TicketLaunchAction? action;

  final DateTime? launchedAt;
  final String launchedByName;

  /// Valeur stockée ; [outcome] vaut `null` pour une valeur inconnue.
  final String rawOutcome;
  final TicketLaunchOutcome? outcome;

  final String? sessionUrl;
  final String? errorReason;

  /// Statut du ticket au lancement (valeur stockée).
  final String? fromStatus;

  /// Échéance calculée par le serveur : 1 h (analyse), 3 h (développement).
  final DateTime? retryAfter;

  const TicketLaunch({
    required this.id,
    required this.rawAction,
    required this.action,
    required this.launchedAt,
    required this.launchedByName,
    required this.rawOutcome,
    required this.outcome,
    required this.sessionUrl,
    required this.errorReason,
    required this.fromStatus,
    required this.retryAfter,
  });

  /// `null` pour une entrée qui n'est pas un objet : une entrée mal formée ne
  /// fait pas tomber la section.
  static TicketLaunch? fromMap(Object? raw) {
    if (raw is! Map) return null;
    String str(Object? v) => v is String ? v : '';
    String? optStr(Object? v) => v is String && v.isNotEmpty ? v : null;
    final action = str(raw['action']);
    final outcome = str(raw['outcome']);
    return TicketLaunch(
      id: str(raw['id']),
      rawAction: action,
      action: TicketLaunchAction.fromValue(action),
      launchedAt: parseTicketDate(raw['launched_at']),
      launchedByName: str(raw['launched_by_name']),
      rawOutcome: outcome,
      outcome: TicketLaunchOutcome.fromValue(outcome),
      sessionUrl: optStr(raw['session_url']),
      errorReason: optStr(raw['error_reason']),
      fromStatus: optStr(raw['from_status']),
      retryAfter: parseTicketDate(raw['retry_after']),
    );
  }
}

/// Les entrées du sous-document, plus récente en tête (sans date : en fin),
/// vingt au plus. Document absent : liste vide.
List<TicketLaunch> ticketLaunchesFromDoc(Map<String, dynamic>? data) {
  final raw = data?['launches'];
  if (raw is! List) return const [];
  final list = raw.map(TicketLaunch.fromMap).whereType<TicketLaunch>().toList();
  final far = DateTime.utc(1);
  list.sort((a, b) => (b.launchedAt ?? far).compareTo(a.launchedAt ?? far));
  return list.length > kTicketLaunchHistoryMax
      ? list.sublist(0, kTicketLaunchHistoryMax)
      : list;
}

/// Entrées gardées par le serveur (`LAUNCH_HISTORY_MAX`).
const kTicketLaunchHistoryMax = 20;

/// Plafond quotidien des lancements quand `app_config/tickets` ne le règle
/// pas (`DEFAULT_LAUNCHES_PER_DAY`), verrouillé par
/// `test-fixtures/ticket_decisions.json`.
const kTicketDefaultLaunchesPerDay = 10;

/// Borne haute de `app_config/tickets.launches_per_day`
/// (`MAX_LAUNCHES_PER_DAY`) : au-delà, le serveur refuse tout lancement.
/// Verrouillée par `test-fixtures/ticket_decisions.json`.
const kTicketMaxLaunchesPerDay = 50;

/// L'état d'un type de lancement d'après l'historique.
class TicketLaunchRunState {
  /// Lancement en cours depuis cet instant, ou `null`.
  final DateTime? runningSince;

  /// Échéance passée sans changement de statut : le lancement de cet instant
  /// peut être relancé. `null` sinon.
  final DateTime? relaunchOf;

  /// Échéance du lancement en cours (`retry_after`) : à cet instant, la
  /// fiche se redessine et propose « Relancer… ». `null` hors lancement en
  /// cours.
  final DateTime? runningUntil;

  const TicketLaunchRunState({
    this.runningSince,
    this.relaunchOf,
    this.runningUntil,
  });

  bool get running => runningSince != null;

  static const none = TicketLaunchRunState();
}

/// La règle « en cours », la même que le serveur (`launchRunState`,
/// `functions/src/tickets/rules.ts`) : logique dupliquée, verrouillée par
/// `test-fixtures/ticket_decisions.json` (section `launch_runs`).
///
/// Seule compte la dernière entrée de ce type (plus grand `launched_at`).
/// Elle est en cours si son résultat est `launched` ou `unknown`, si le
/// ticket a toujours le statut d'où elle est partie, et si [now] précède son
/// échéance. Échéance passée, mêmes conditions : relance proposée.
TicketLaunchRunState ticketLaunchRunState({
  required List<TicketLaunch> launches,
  required TicketLaunchAction action,
  required String rawStatus,
  required DateTime now,
}) {
  TicketLaunch? last;
  for (final e in launches) {
    final at = e.launchedAt;
    if (e.rawAction != action.value || at == null) continue;
    if (last == null || at.isAfter(last.launchedAt!)) last = e;
  }
  if (last == null) return TicketLaunchRunState.none;
  if (last.rawOutcome != 'launched' && last.rawOutcome != 'unknown') {
    return TicketLaunchRunState.none;
  }
  if (last.fromStatus != rawStatus) return TicketLaunchRunState.none;
  final retryAfter = last.retryAfter;
  if (retryAfter == null) return TicketLaunchRunState.none;
  if (now.isBefore(retryAfter)) {
    return TicketLaunchRunState(
      runningSince: last.launchedAt,
      runningUntil: retryAfter,
    );
  }
  return TicketLaunchRunState(relaunchOf: last.launchedAt);
}

/// « Analyse en cours depuis 14:05 », ou « … depuis le 13/10/26 à 14:05 »
/// quand le lancement date d'un autre jour.
String ticketLaunchRunningLine(
  TicketLaunchAction action,
  DateTime since,
  DateTime now,
) {
  final s = since.toLocal();
  final n = now.toLocal();
  final sameDay = s.year == n.year && s.month == n.month && s.day == n.day;
  final hour =
      '${s.hour.toString().padLeft(2, '0')}:'
      '${s.minute.toString().padLeft(2, '0')}';
  return sameDay
      ? '${action.noun} en cours depuis $hour'
      : '${action.noun} en cours depuis le ${formatTicketDateTime(s)}';
}

/// Le lien d'une session ne s'ouvre que s'il vise `https://claude.ai`.
Uri? openableSessionLink(String? href) {
  if (href == null) return null;
  final uri = Uri.tryParse(href.trim());
  if (uri == null || !uri.hasAuthority) return null;
  if (uri.scheme != 'https' || uri.host != 'claude.ai') return null;
  return uri;
}

/// Un compteur affiché, avec sa période (`AAAAMMJJ` ou `AAAAMM`).
typedef TicketLaunchCounter = ({String period, int count});

/// Le document `app_config/tickets_status`, écrit par le serveur seul et
/// lisible par l'administrateur seul.
class TicketsStatus {
  /// Jeton GitHub refusé depuis cet instant (`token_invalid_since`).
  final DateTime? githubTokenInvalidSince;

  /// Jeton de la routine refusé (`routine_invalid_since.analyse` et
  /// `.developpement`).
  final DateTime? analysisRoutineInvalidSince;
  final DateTime? developmentRoutineInvalidSince;

  /// `launches_today` (`{day, count}`) et `launches_month` (`{month, count}`).
  final TicketLaunchCounter? launchesToday;
  final TicketLaunchCounter? launchesMonth;

  const TicketsStatus({
    this.githubTokenInvalidSince,
    this.analysisRoutineInvalidSince,
    this.developmentRoutineInvalidSince,
    this.launchesToday,
    this.launchesMonth,
  });

  factory TicketsStatus.fromMap(Map<String, dynamic>? data) {
    final routines = data?['routine_invalid_since'];
    TicketLaunchCounter? counter(Object? raw, String key) {
      if (raw is! Map) return null;
      final period = raw[key];
      final count = raw['count'];
      if (period is! String || count is! num) return null;
      return (period: period, count: count < 0 ? 0 : count.toInt());
    }

    return TicketsStatus(
      githubTokenInvalidSince: parseTicketDate(data?['token_invalid_since']),
      analysisRoutineInvalidSince: routines is Map
          ? parseTicketDate(routines['analyse'])
          : null,
      developmentRoutineInvalidSince: routines is Map
          ? parseTicketDate(routines['developpement'])
          : null,
      launchesToday: counter(data?['launches_today'], 'day'),
      launchesMonth: counter(data?['launches_month'], 'month'),
    );
  }

  /// Lancements comptés aujourd'hui (jour de Paris) ; 0 si le compteur est
  /// d'un autre jour.
  int launchesTodayAt(DateTime now) {
    final c = launchesToday;
    return c != null && c.period == parisDayKey(now) ? c.count : 0;
  }

  /// Lancements comptés ce mois-ci (mois de Paris) ; 0 si le compteur est
  /// d'un autre mois.
  int launchesMonthAt(DateTime now) {
    final c = launchesMonth;
    return c != null && c.period == parisDayKey(now).substring(0, 6)
        ? c.count
        : 0;
  }
}

/// Ce que rend un lancement abouti ou au résultat inconnu.
class TicketLaunchResult {
  final TicketLaunchOutcome outcome;
  final String? sessionUrl;

  /// Message du serveur pour un résultat inconnu venu d'une réponse 5xx
  /// (« Claude ne répond pas. Vérifiez sur claude.ai/code avant de
  /// relancer. »), sinon `null`.
  final String? message;

  const TicketLaunchResult({
    required this.outcome,
    required this.sessionUrl,
    this.message,
  });

  /// Réponse du serveur ; un résultat illisible se lit `unknown`.
  factory TicketLaunchResult.fromMap(Map<String, dynamic> data) {
    final outcome = TicketLaunchOutcome.fromValue(data['outcome']);
    final url = data['session_url'];
    final message = data['message'];
    return TicketLaunchResult(
      message: message is String && message.trim().isNotEmpty
          ? message.trim()
          : null,
      outcome: outcome == TicketLaunchOutcome.launched
          ? TicketLaunchOutcome.launched
          : TicketLaunchOutcome.unknown,
      sessionUrl: url is String && url.isNotEmpty ? url : null,
    );
  }
}

/// Refus d'un lancement par le serveur (statut, plafond, routine non
/// configurée, réponse d'erreur de Claude) : rien n'a été lancé, le message
/// s'affiche tel quel dans la boîte de confirmation.
class TicketLaunchError implements Exception {
  final String message;
  const TicketLaunchError(this.message);

  @override
  String toString() => message;
}
