import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/log_entry.dart';

const String _functionsRegion = 'europe-west1';
const String _firebaseProjectId = 'kassdale-6d948';

/// Accès à la Cloud Function `queryLogsFn` (lecture de Cloud Logging).
///
/// Sur web, on bypass le SDK `cloud_functions_web` qui a un bug persistant
/// ("Int64 accessor not supported by dart2js") en faisant un POST HTTP direct
/// vers le endpoint de la callable. Sur mobile/desktop on garde le SDK natif.
class LogsRepository {
  final FirebaseFunctions _functions;

  LogsRepository({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: _functionsRegion);

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

    final dynamic raw = kIsWeb
        ? await _callViaHttp('queryLogsFn', payload)
        : await _callViaSdk('queryLogsFn', payload);

    final data = Map<String, dynamic>.from(raw as Map);
    final entries = (data['entries'] as List?) ?? const [];
    return entries
        .whereType<Map>()
        .map((m) => LogEntry.fromMap(Map<String, dynamic>.from(m)))
        .toList(growable: false);
  }

  Future<dynamic> _callViaSdk(String name, Map<String, dynamic> payload) async {
    final res = await _functions
        .httpsCallable(
          name,
          options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
        )
        .call<dynamic>(payload);
    return res.data;
  }

  /// Appel HTTP direct au endpoint callable (web uniquement).
  /// Format Firebase Callable : body `{"data": {...}}`, response `{"result": {...}}`.
  Future<dynamic> _callViaHttp(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw FirebaseFunctionsException(
        code: 'unauthenticated',
        message: 'Utilisateur non connecté.',
      );
    }
    final idToken = await user.getIdToken();
    final url = Uri.parse(
      'https://$_functionsRegion-$_firebaseProjectId.cloudfunctions.net/$name',
    );
    final res = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode({'data': payload}),
    );
    if (res.statusCode != 200) {
      String code = 'internal';
      String message = 'HTTP ${res.statusCode}';
      try {
        final err = jsonDecode(res.body) as Map<String, dynamic>;
        final errObj = err['error'] as Map<String, dynamic>?;
        if (errObj != null) {
          code = (errObj['status'] as String?)?.toLowerCase() ?? code;
          message = (errObj['message'] as String?) ?? message;
        }
      } catch (parseError) {
        // Le corps d'erreur n'a pas la forme attendue : on le joint au message
        // plutôt que de le perdre silencieusement.
        message =
            '$message — corps d\'erreur non parsable ($parseError) : ${res.body}';
      }
      throw FirebaseFunctionsException(code: code, message: message);
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['result'];
  }
}
