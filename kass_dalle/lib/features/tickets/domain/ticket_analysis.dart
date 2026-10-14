import 'ticket.dart';

/// Une analyse du mainteneur, relevée sur l'Issue GitHub d'un ticket.
///
/// Élément de `tickets/{ticketId}/admin/analysis.analyses`, écrit par les
/// Cloud Functions seules (webhook, tâche horaire, décisions, backfill
/// « Analyses des tickets ») et lisible par l'administrateur seul.
class TicketAnalysis {
  /// Identifiant du commentaire GitHub, ou `null`.
  final int? commentId;

  /// Texte Markdown du commentaire, ligne de titre `## Analyse…` comprise.
  final String body;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Le texte dépassait 20 000 caractères : il a été coupé à la dernière
  /// ligne vide, la suite reste sur GitHub.
  final bool truncated;

  const TicketAnalysis({
    required this.commentId,
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
    final id = raw['comment_id'];
    return TicketAnalysis(
      commentId: id is num ? id.toInt() : null,
      body: body,
      createdAt: parseTicketDate(raw['created_at']),
      updatedAt: parseTicketDate(raw['updated_at']),
      truncated: raw['truncated'] == true,
    );
  }
}

/// Le sous-document `tickets/{ticketId}/admin/analysis`.
class TicketAnalysisDoc {
  /// Dans l'ordre chronologique, dix au plus.
  final List<TicketAnalysis> analyses;

  /// Dernier relevé des commentaires de l'Issue.
  final DateTime? checkedAt;

  const TicketAnalysisDoc({required this.analyses, required this.checkedAt});

  factory TicketAnalysisDoc.fromMap(Map<String, dynamic> data) {
    final raw = data['analyses'];
    return TicketAnalysisDoc(
      analyses: raw is List
          ? raw.map(TicketAnalysis.fromMap).whereType<TicketAnalysis>().toList()
          : const [],
      checkedAt: parseTicketDate(data['checked_at']),
    );
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

/// Le texte d'une analyse sans sa ligne de titre `## Analyse…`, que
/// l'en-tête « Analyse du … » remplace.
String ticketAnalysisDisplayBody(String body) {
  final text = body.replaceAll('\r\n', '\n').trimLeft();
  if (!text.startsWith('## Analyse')) return text;
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
