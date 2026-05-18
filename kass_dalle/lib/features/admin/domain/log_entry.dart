/// Modèle d'entrée de log retournée par la Cloud Function admin `queryLogsFn`.
class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.severity,
    required this.labels,
    required this.payload,
    this.insertId,
  });

  /// Timestamp ISO-8601 UTC.
  final String timestamp;

  /// `INFO` / `WARNING` / `ERROR` / `DEBUG` / `DEFAULT`.
  final String severity;

  /// Labels indexés (correlationId, jobId, userId, moduleType, geminiStatus…).
  final Map<String, String> labels;

  /// `jsonPayload` complet (contient `message` + champs structurés).
  final Map<String, dynamic> payload;

  final String? insertId;

  factory LogEntry.fromMap(Map<String, dynamic> map) {
    final rawLabels = map['labels'];
    final labels = <String, String>{};
    if (rawLabels is Map) {
      rawLabels.forEach((k, v) {
        if (k is String && v != null) labels[k] = v.toString();
      });
    }
    final rawPayload = map['payload'];
    final payload = <String, dynamic>{};
    if (rawPayload is Map) {
      rawPayload.forEach((k, v) {
        if (k is String) payload[k] = v;
      });
    }
    return LogEntry(
      timestamp: (map['timestamp'] ?? '').toString(),
      severity: (map['severity'] ?? 'DEFAULT').toString(),
      labels: labels,
      payload: payload,
      insertId: map['insertId']?.toString(),
    );
  }

  /// Message principal (extrait de `payload.message`).
  String get message {
    final m = payload['message'];
    return m == null ? '' : m.toString();
  }

  DateTime? get timestampDate => DateTime.tryParse(timestamp);
}
