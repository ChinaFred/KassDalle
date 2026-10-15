import 'ticket.dart';
import 'ticket_launch.dart';

/// Raison serveur d'une livraison refusée parce que la PR modifie un fichier
/// sensible (`.github/`, `.claude/`, `deploy.ps1`, `kass_dalle/firebase.json`,
/// tout `CLAUDE.md`, `CLAUDE.local.md` ou `.mcp.json`) : la boîte grise alors
/// « Livrer »
/// (`DELIVERY_SENSITIVE_REASON`). Verrouillée par
/// `test-fixtures/ticket_decisions.json`.
const kTicketDeliverySensitiveReason = 'delivery_sensitive_files';

/// Nature d'un compte rendu publié par la session de livraison.
enum TicketDeliveryReportKind {
  /// `## Livraison — blocage`
  blocked('blocked'),

  /// `## Livraison — terminée`
  done('done');

  const TicketDeliveryReportKind(this.value);

  final String value;

  static TicketDeliveryReportKind? fromValue(Object? value) {
    for (final k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Un compte rendu `## Livraison — …` du mainteneur relevé sur l'Issue.
class TicketDeliveryReport {
  final int? commentId;
  final TicketDeliveryReportKind kind;

  /// Texte Markdown, ligne de titre comprise.
  final String body;
  final DateTime? createdAt;

  /// Coupé à 20 000 caractères, la suite reste sur GitHub.
  final bool truncated;

  const TicketDeliveryReport({
    required this.commentId,
    required this.kind,
    required this.body,
    required this.createdAt,
    required this.truncated,
  });

  /// `null` pour une entrée illisible ou d'une nature inconnue.
  static TicketDeliveryReport? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final kind = TicketDeliveryReportKind.fromValue(raw['kind']);
    final body = raw['body'];
    if (kind == null || body is! String || body.trim().isEmpty) return null;
    final id = raw['comment_id'];
    return TicketDeliveryReport(
      commentId: id is num ? id.toInt() : null,
      kind: kind,
      body: body,
      createdAt: parseTicketDate(raw['created_at']),
      truncated: raw['truncated'] == true,
    );
  }
}

/// Le sous-document `tickets/{ticketId}/admin/delivery`, écrit par le
/// serveur seul (webhook, tâche horaire, `launchTicketDelivery`) et lisible
/// par l'administrateur seul : état « PR prête » et comptes rendus de
/// livraison. Le client n'y recalcule rien : il affiche.
class TicketDelivery {
  /// PR ouvertes, non brouillon, du mainteneur, branche `claude/…`, qui
  /// ferment l'Issue.
  final int eligiblePrCount;

  /// La PR éligible quand elle est seule.
  final int? prNumber;
  final String? prUrl;

  /// `false` : conflit avec `master` ; `null` : pas encore calculé.
  final bool? mergeable;

  /// État du dernier run « CI » sur la tête (`queued`, `in_progress`,
  /// `completed`…), `null` sans run.
  final String? ciStatus;
  final String? ciConclusion;
  final DateTime? ciCompletedAt;

  /// « PR prête », calculé par le serveur.
  final bool ready;

  /// Comptes rendus, dans l'ordre chronologique.
  final List<TicketDeliveryReport> reports;

  const TicketDelivery({
    this.eligiblePrCount = 0,
    this.prNumber,
    this.prUrl,
    this.mergeable,
    this.ciStatus,
    this.ciConclusion,
    this.ciCompletedAt,
    this.ready = false,
    this.reports = const [],
  });

  factory TicketDelivery.fromMap(Map<String, dynamic> data) {
    int? optInt(Object? v) => v is num ? v.toInt() : null;
    String? optStr(Object? v) => v is String && v.isNotEmpty ? v : null;
    final raw = data['reports'];
    final mergeable = data['mergeable'];
    return TicketDelivery(
      eligiblePrCount: optInt(data['eligible_pr_count']) ?? 0,
      prNumber: optInt(data['pr_number']),
      prUrl: optStr(data['pr_url']),
      mergeable: mergeable is bool ? mergeable : null,
      ciStatus: optStr(data['ci_status']),
      ciConclusion: optStr(data['ci_conclusion']),
      ciCompletedAt: parseTicketDate(data['ci_completed_at']),
      ready: data['ready'] == true,
      reports: raw is List
          ? raw
                .map(TicketDeliveryReport.fromMap)
                .whereType<TicketDeliveryReport>()
                .toList()
          : const [],
    );
  }

  /// Date du dernier compte rendu « blocage », ou `null`.
  DateTime? get lastBlockedAt {
    DateTime? best;
    for (final r in reports) {
      final at = r.createdAt;
      if (r.kind != TicketDeliveryReportKind.blocked || at == null) continue;
      if (best == null || at.isAfter(best)) best = at;
    }
    return best;
  }

  /// L'adresse de la PR éligible unique, seulement en `https` sur
  /// `github.com`, ou `null`.
  Uri? get openablePrLink {
    final href = prUrl;
    if (prNumber == null || eligiblePrCount != 1 || href == null) return null;
    final uri = Uri.tryParse(href.trim());
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      return null;
    }
    return uri;
  }
}

/// Le texte d'un compte rendu sans sa ligne `## Livraison — …`, que l'en-tête
/// de la carte remplace.
String ticketDeliveryReportDisplayBody(String body) {
  final text = body.replaceAll('\r\n', '\n').trimLeft();
  if (!text.startsWith('## Livraison')) return text;
  final newline = text.indexOf('\n');
  return newline < 0 ? '' : text.substring(newline + 1).trim();
}

/// `app_config/tickets_status.delivery_running` : une livraison à la fois
/// pour tout le dépôt.
class TicketDeliveryLock {
  final String? ticketId;
  final int? issueNumber;
  final DateTime? launchedAt;
  final DateTime? retryAfter;

  const TicketDeliveryLock({
    required this.ticketId,
    required this.issueNumber,
    required this.launchedAt,
    required this.retryAfter,
  });

  factory TicketDeliveryLock.fromMap(Map<String, dynamic> data) {
    final id = data['ticket_id'];
    final issue = data['issue_number'];
    return TicketDeliveryLock(
      ticketId: id is String && id.isNotEmpty ? id : null,
      issueNumber: issue is int ? issue : null,
      launchedAt: parseTicketDate(data['launched_at']),
      retryAfter: parseTicketDate(data['retry_after']),
    );
  }
}

/// Le verrou tient : ses quatre champs se lisent, [now] précède son
/// échéance, et le ticket verrouillé est toujours `in_progress`
/// ([lockedTicketRawStatus] `null` : ticket introuvable). La même règle que le
/// serveur (`deliveryLockActive`), verrouillée par
/// `test-fixtures/ticket_decisions.json` (section `delivery_lock`).
bool ticketDeliveryLockActive({
  required TicketDeliveryLock? lock,
  required String? lockedTicketRawStatus,
  required DateTime now,
}) {
  if (lock == null) return false;
  final issue = lock.issueNumber;
  final retryAfter = lock.retryAfter;
  if (lock.ticketId == null || issue == null || issue <= 0) return false;
  if (lock.launchedAt == null || retryAfter == null) return false;
  if (!now.isBefore(retryAfter)) return false;
  return lockedTicketRawStatus == TicketStatus.inProgress.value;
}

/// Ce que la barre de décision d'un ticket En cours propose.
enum TicketDeliveryLineKind {
  running,
  loading,
  unreadable,
  multiplePrs,
  conflict,
  ciFailed,
  ciRunning,
  noPr,
  elsewhere,
  blocked,
  expired,
  ready,
}

/// L'action principale de la barre : « Livrer » ou « Relancer la livraison ».
enum TicketDeliveryAction { deliver, relaunch }

/// La ligne d'état de la barre d'un ticket En cours, et son action.
class TicketDeliveryBar {
  final TicketDeliveryLineKind kind;
  final String text;
  final TicketDeliveryAction? action;

  /// Livraison ailleurs : le ticket qui tient le verrou, pour « Ouvrir le
  /// ticket #K ».
  final String? elsewhereTicketId;
  final int? elsewhereIssueNumber;

  const TicketDeliveryBar({
    required this.kind,
    required this.text,
    this.action,
    this.elsewhereTicketId,
    this.elsewhereIssueNumber,
  });
}

/// « 14:05 », ou « le 14/10/26 à 14:05 » quand [since] est d'un autre jour.
String _sinceText(DateTime since, DateTime now) {
  final s = since.toLocal();
  final n = now.toLocal();
  final sameDay = s.year == n.year && s.month == n.month && s.day == n.day;
  final hour =
      '${s.hour.toString().padLeft(2, '0')}:'
      '${s.minute.toString().padLeft(2, '0')}';
  return sameDay ? hour : 'le ${formatTicketDateTime(s)}';
}

/// La ligne et l'action de la barre d'un ticket En cours, une seule, dans cet
/// ordre de priorité : livraison en cours ici, chargement, état illisible,
/// plusieurs PR, conflit, CI en échec, CI en cours, aucune PR prête,
/// livraison ailleurs, blocage relevé, échéance passée, PR prête.
///
/// [run] : la règle « en cours » de la livraison sur ce ticket.
/// [lockElsewhere] : le verrou global, déjà reconnu actif et tenu par un
/// autre ticket ; `null` sinon, ou s'il ne se lit pas (« Livrer » reste
/// offert, le serveur tranche).
TicketDeliveryBar ticketDeliveryBar({
  required TicketLaunchRunState run,
  required bool deliveryLoading,
  required bool deliveryError,
  required TicketDelivery? delivery,
  required int issueNumber,
  required TicketDeliveryLock? lockElsewhere,
  required DateTime now,
}) {
  final since = run.runningSince;
  if (since != null) {
    return TicketDeliveryBar(
      kind: TicketDeliveryLineKind.running,
      text: ticketLaunchRunningLine(TicketLaunchAction.delivery, since, now),
    );
  }
  if (deliveryLoading) {
    return const TicketDeliveryBar(
      kind: TicketDeliveryLineKind.loading,
      text: 'Vérification de la pull request…',
    );
  }
  if (deliveryError) {
    return const TicketDeliveryBar(
      kind: TicketDeliveryLineKind.unreadable,
      text: 'État de la pull request illisible.',
    );
  }
  final d = delivery ?? const TicketDelivery();
  final pr = d.prNumber;
  if (d.eligiblePrCount > 1) {
    return TicketDeliveryBar(
      kind: TicketDeliveryLineKind.multiplePrs,
      text:
          '${d.eligiblePrCount} pull requests ferment l\'Issue #$issueNumber : '
          'fermez celles à abandonner sur GitHub.',
    );
  }
  if (pr != null && d.eligiblePrCount == 1) {
    if (d.mergeable == false) {
      return TicketDeliveryBar(
        kind: TicketDeliveryLineKind.conflict,
        text: 'Conflit sur la PR #$pr',
      );
    }
    if (d.ciStatus == 'completed' && d.ciConclusion != 'success') {
      return TicketDeliveryBar(
        kind: TicketDeliveryLineKind.ciFailed,
        text: 'CI de la PR #$pr en échec',
      );
    }
    if (d.ciStatus != 'completed') {
      return TicketDeliveryBar(
        kind: TicketDeliveryLineKind.ciRunning,
        text: 'CI de la PR #$pr en cours',
      );
    }
  }
  if (!d.ready || pr == null) {
    return const TicketDeliveryBar(
      kind: TicketDeliveryLineKind.noPr,
      text: 'Aucune PR prête',
    );
  }
  final lock = lockElsewhere;
  final lockSince = lock?.launchedAt;
  if (lock != null && lockSince != null) {
    return TicketDeliveryBar(
      kind: TicketDeliveryLineKind.elsewhere,
      text:
          'Livraison du ticket #${lock.issueNumber} en cours depuis '
          '${_sinceText(lockSince, now)}',
      elsewhereTicketId: lock.ticketId,
      elsewhereIssueNumber: lock.issueNumber,
    );
  }
  final completed = d.ciCompletedAt;
  final readyText = completed == null
      ? 'PR #$pr prête — CI verte'
      : 'PR #$pr prête — CI verte le ${formatTicketDateTime(completed)}';
  final relaunchOf = run.relaunchOf;
  if (relaunchOf != null && run.blocked) {
    return TicketDeliveryBar(
      kind: TicketDeliveryLineKind.blocked,
      text:
          'La livraison du ${formatTicketDateTime(relaunchOf)} s\'est arrêtée : '
          'lisez « Livraison — blocage » ci-dessous.',
      action: TicketDeliveryAction.relaunch,
    );
  }
  if (relaunchOf != null) {
    return TicketDeliveryBar(
      kind: TicketDeliveryLineKind.expired,
      text: readyText,
      action: TicketDeliveryAction.relaunch,
    );
  }
  return TicketDeliveryBar(
    kind: TicketDeliveryLineKind.ready,
    text: readyText,
    action: TicketDeliveryAction.deliver,
  );
}
