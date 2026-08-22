/// Client d'appel de `sandboxFn`, le point d'entrée unique du bac à sable.
///
/// DÉRIVÉ de `core/services/gemini_service.dart`, dont les mécanismes d'appel
/// sont privés : le contournement web y est écrit une fois, dans une classe
/// dont l'API publique ne connaît que des recettes. Plutôt que d'ouvrir cette
/// classe pour un usage expérimental, on en copie les trente lignes utiles.
///
/// Le contournement en question : sur web, le SDK `cloud_functions_web` casse
/// sur un accesseur Int64 non supporté par dart2js. On y fait donc un POST
/// direct au point d'entrée callable, au format `{"data": …}` / `{"result": …}`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../../core/services/error_report_service.dart';

const String _functionsRegion = 'europe-west1';
const String _firebaseProjectId = 'kassdale-6d948';
const String _functionName = 'sandboxFn';

/// Échec d'un appel au bac à sable, avec le code renvoyé par la fonction.
class SandboxCallException implements Exception {
  final String code;
  final String message;

  const SandboxCallException(this.code, this.message);

  @override
  String toString() => 'SandboxCallException($code): $message';
}

class SandboxFunctions {
  final ErrorReportService _errorReportService;
  FirebaseFunctions? _functions;

  SandboxFunctions({ErrorReportService? errorReportService})
    : _errorReportService = errorReportService ?? ErrorReportService();

  /// Appelle une expérience et rend son `data`.
  ///
  /// [experiment] est la clé du `switch` côté serveur — par exemple
  /// `image_import.detect_regions`.
  Future<Map<String, dynamic>> call(
    String experiment,
    Map<String, dynamic> payload,
  ) async {
    final data = {...payload, 'experiment': experiment};
    final dynamic result = kIsWeb
        ? await _callViaHttp(data)
        : await _callViaSdk(data);
    if (result is Map) return Map<String, dynamic>.from(result);
    throw SandboxCallException(
      'invalid-response',
      'Réponse inattendue : ${result.runtimeType}',
    );
  }

  Future<dynamic> _callViaSdk(Map<String, dynamic> data) async {
    final functions = _functions ??= FirebaseFunctions.instanceFor(
      region: _functionsRegion,
    );
    try {
      final result = await functions
          .httpsCallable(
            _functionName,
            options: HttpsCallableOptions(timeout: const Duration(minutes: 3)),
          )
          .call<dynamic>(data);
      return result.data;
    } on FirebaseFunctionsException catch (error, stackTrace) {
      unawaited(
        _errorReportService.reportError(
          feature: 'sandbox.call.sdk',
          error: error,
          stackTrace: stackTrace,
          context: {'experiment': data['experiment'], 'code': error.code},
        ),
      );
      throw SandboxCallException(error.code, error.message ?? '');
    }
  }

  Future<dynamic> _callViaHttp(Map<String, dynamic> data) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const SandboxCallException(
        'unauthenticated',
        'Utilisateur non connecté.',
      );
    }

    final String? idToken;
    try {
      idToken = await user.getIdToken();
    } catch (error, stackTrace) {
      unawaited(
        _errorReportService.reportError(
          feature: 'sandbox.call.token',
          error: error,
          stackTrace: stackTrace,
        ),
      );
      rethrow;
    }

    final url = Uri.parse(
      'https://$_functionsRegion-$_firebaseProjectId.cloudfunctions.net/'
      '$_functionName',
    );

    final http.Response response;
    try {
      response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({'data': data}),
      );
    } catch (error, stackTrace) {
      unawaited(
        _errorReportService.reportError(
          feature: 'sandbox.call.http',
          error: error,
          stackTrace: stackTrace,
          context: {'experiment': data['experiment']},
        ),
      );
      rethrow;
    }

    if (response.statusCode != 200) {
      String code = 'internal';
      String message = 'HTTP ${response.statusCode}';
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final error = body['error'] as Map<String, dynamic>?;
        if (error != null) {
          code = (error['status'] as String?)?.toLowerCase() ?? code;
          message = (error['message'] as String?) ?? message;
        }
      } catch (error, stackTrace) {
        // Un corps d'erreur illisible reste une erreur : on garde le code HTTP
        // et on signale que la lecture a échoué, plutôt que d'avaler les deux.
        unawaited(
          _errorReportService.reportError(
            feature: 'sandbox.call.errorBody',
            error: error,
            stackTrace: stackTrace,
            context: {'status': response.statusCode},
          ),
        );
      }
      throw SandboxCallException(code, message);
    }

    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return body['result'];
  }
}
