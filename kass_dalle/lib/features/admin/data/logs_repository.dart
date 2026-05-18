import 'package:cloud_functions/cloud_functions.dart';

import '../domain/log_entry.dart';

/// Accès à la Cloud Function `queryLogsFn` (lecture de Cloud Logging).
class LogsRepository {
  final FirebaseFunctions _functions;

  LogsRepository({FirebaseFunctions? functions})
    : _functions =
          functions ??
          FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Requête de logs avec filtres optionnels.
  ///
  /// [severity]        : "INFO" / "WARNING" / "ERROR" / "DEBUG"
  /// [correlationId]   : filtre exact sur le label.
  /// [jobId], [userId] : filtres exacts sur les labels.
  /// [timeRangeMinutes]: fenêtre en minutes (défaut 60, max 10080 = 7 jours).
  /// [freeText]        : recherche plein-texte dans `payload.message`.
  /// [pageSize]        : 1..200 (défaut 100).
  Future<List<LogEntry>> query({
    String? severity,
    String? correlationId,
    String? jobId,
    String? userId,
    int timeRangeMinutes = 60,
    String? freeText,
    int pageSize = 100,
  }) async {
    final payload = <String, dynamic>{
      'timeRangeMinutes': timeRangeMinutes,
      'pageSize': pageSize,
    };
    if (severity != null && severity.isNotEmpty) payload['severity'] = severity;
    if (correlationId != null && correlationId.isNotEmpty) {
      payload['correlationId'] = correlationId;
    }
    if (jobId != null && jobId.isNotEmpty) payload['jobId'] = jobId;
    if (userId != null && userId.isNotEmpty) payload['userId'] = userId;
    if (freeText != null && freeText.isNotEmpty) payload['freeText'] = freeText;

    final res = await _functions
        .httpsCallable(
          'queryLogsFn',
          options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
        )
        .call<dynamic>(payload);

    final data = Map<String, dynamic>.from(res.data as Map);
    final raw = (data['entries'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((m) => LogEntry.fromMap(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }
}
