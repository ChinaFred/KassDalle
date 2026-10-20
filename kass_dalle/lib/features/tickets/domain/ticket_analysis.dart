import 'ticket.dart';

/// Nature d'une entrée relevée sur l'Issue : analyse du mainteneur
/// (`## Analyse…`), réponse de l'administrateur publiée par « Répondre »
/// (`## Précisions de l'administrateur`, identifiant enregistré par le
/// serveur), ou commentaire `## Précisions…` du même compte qui n'a pas été
/// publié depuis l'application (une session Claude Code signe comme ce
/// compte) : affiché « Non publiée depuis l'application ».
enum TicketAnalysisKind {
  analysis('analysis'),
  reply('reply'),
  unverifiedReply('unverified_reply');

  const TicketAnalysisKind(this.value);

  final String value;

  /// `kind` absent (entrée écrite avant les réponses) : une analyse. Valeur
  /// inconnue de cette version : `null`, l'entrée est écartée.
  static TicketAnalysisKind? fromStored(Object? value) {
    if (value == null) return TicketAnalysisKind.analysis;
    for (final k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Une analyse du mainteneur, ou une réponse de l'administrateur, relevée
/// sur l'Issue GitHub d'un ticket.
///
/// Élément de `tickets/{ticketId}/admin/analysis.analyses`, écrit par les
/// Cloud Functions seules (webhook, tâche horaire, décisions) et lisible par
/// l'administrateur seul.
class TicketAnalysis {
  /// Identifiant du commentaire GitHub, ou `null`.
  final int? commentId;

  final TicketAnalysisKind kind;

  /// Texte Markdown du commentaire, ligne de titre (`## Analyse…`,
  /// `## Précisions…`) comprise.
  final String body;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Le texte dépassait 20 000 caractères : il a été coupé à la dernière
  /// ligne vide, la suite reste sur GitHub.
  final bool truncated;

  const TicketAnalysis({
    required this.commentId,
    this.kind = TicketAnalysisKind.analysis,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.truncated,
  });

  /// `null` pour une entrée illisible : une analyse mal formée ne fait pas
  /// tomber la section.
  static TicketAnalysis? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final body = raw['body'];
    if (body is! String || body.trim().isEmpty) return null;
    final kind = TicketAnalysisKind.fromStored(raw['kind']);
    if (kind == null) return null;
    final id = raw['comment_id'];
    return TicketAnalysis(
      commentId: id is num ? id.toInt() : null,
      kind: kind,
      body: body,
      createdAt: parseTicketDate(raw['created_at']),
      updatedAt: parseTicketDate(raw['updated_at']),
      truncated: raw['truncated'] == true,
    );
  }
}

/// Le sous-document `tickets/{ticketId}/admin/analysis`.
class TicketAnalysisDoc {
  /// Analyses et réponses, dans l'ordre chronologique, dix au plus.
  final List<TicketAnalysis> analyses;

  /// Dernier relevé des commentaires de l'Issue.
  final DateTime? checkedAt;

  /// Le champ `validated_at` existe : la date du dernier « validé » posé par
  /// le mainteneur est connue ([validatedAt], `null` s'il n'y en a aucun).
  /// Absent : date inconnue, le ticket n'est pas dit bloqué.
  final bool validatedAtKnown;

  final DateTime? validatedAt;

  const TicketAnalysisDoc({
    required this.analyses,
    required this.checkedAt,
    this.validatedAtKnown = false,
    this.validatedAt,
  });

  factory TicketAnalysisDoc.fromMap(Map<String, dynamic> data) {
    final raw = data['analyses'];
    return TicketAnalysisDoc(
      analyses: raw is List
          ? raw.map(TicketAnalysis.fromMap).whereType<TicketAnalysis>().toList()
          : const [],
      checkedAt: parseTicketDate(data['checked_at']),
      validatedAtKnown: data.containsKey('validated_at'),
      validatedAt: parseTicketDate(data['validated_at']),
    );
  }

  /// Nombre d'analyses du mainteneur, réponses exclues.
  int get analysisCount =>
      analyses.where((a) => a.kind == TicketAnalysisKind.analysis).length;

  bool get hasAnalysis => analysisCount > 0;

  /// Date de la dernière analyse relevée, ou `null`.
  DateTime? get lastAnalysisAt {
    DateTime? best;
    for (final a in analyses) {
      final at = a.createdAt;
      if (a.kind != TicketAnalysisKind.analysis || at == null) continue;
      if (best == null || at.isAfter(best)) best = at;
    }
    return best;
  }

  /// Date de la réponse de l'administrateur publiée après la dernière
  /// analyse (sans analyse : la dernière réponse de l'Issue), ou `null` : la
  /// prochaine analyse la lira.
  DateTime? get pendingAnswerAt {
    final last = lastAnalysisAt;
    DateTime? best;
    for (final a in analyses) {
      final at = a.createdAt;
      if (a.kind != TicketAnalysisKind.reply || at == null) continue;
      if (last != null && !at.isAfter(last)) continue;
      if (best == null || at.isAfter(best)) best = at;
    }
    return best;
  }
}

/// Ce que montre la section « Analyses » de la fiche admin.
enum TicketAnalysisView {
  /// Au moins une analyse à afficher.
  list,

  /// « Pas encore analysé. »
  notAnalyzed,

  /// « Analyse pas encore relevée. » : le ticket a dépassé Reçu, mais aucun
  /// relevé n'a encore eu lieu (ticket antérieur au backfill).
  notYetCollected,
}

/// L'état de la section, selon le statut du ticket et le sous-document lu
/// (`null` s'il n'existe pas).
TicketAnalysisView ticketAnalysisView({
  required TicketStatus status,
  required TicketAnalysisDoc? doc,
}) {
  if (doc != null && doc.analyses.isNotEmpty) return TicketAnalysisView.list;
  final beyondReceived =
      status != TicketStatus.sending && status != TicketStatus.received;
  if (doc == null && beyondReceived) return TicketAnalysisView.notYetCollected;
  return TicketAnalysisView.notAnalyzed;
}

/// Le texte d'une analyse ou d'une réponse sans sa ligne de titre
/// (`## Analyse…`, `## Précisions…`), que l'en-tête « Analyse du … » ou
/// « Votre réponse du … » remplace.
String ticketAnalysisDisplayBody(String body) {
  final text = body.replaceAll('\r\n', '\n').trimLeft();
  if (!text.startsWith('## Analyse') && !text.startsWith('## Précisions')) {
    return text;
  }
  final newline = text.indexOf('\n');
  return newline < 0 ? '' : text.substring(newline + 1).trim();
}

/// Un lien d'analyse ne s'ouvre que s'il vise une page web (`http`, `https`).
Uri? openableAnalysisLink(String? href) {
  if (href == null) return null;
  final uri = Uri.tryParse(href.trim());
  if (uri == null || !uri.hasAuthority) return null;
  return uri.scheme == 'http' || uri.scheme == 'https' ? uri : null;
}

/// Ce qui remplace une image dans une analyse : elle n'est pas chargée.
String ticketAnalysisImagePlaceholder(String? alt) {
  final text = alt?.trim() ?? '';
  return text.isEmpty ? '[Image non affichée]' : '[Image non affichée : $text]';
}
