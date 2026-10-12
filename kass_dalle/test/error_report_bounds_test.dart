import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';

/// Bornes d'un rapport d'erreur : ce que le client écrit doit toujours passer
/// les règles Firestore de `error_reports` (le double de ces longueurs), sans
/// perdre de rapport.
void main() {
  ErrorReport report({
    String message = 'boom',
    String? stack,
    Map<String, dynamic> context = const {},
  }) => ErrorReport(
    id: '',
    userId: 'u1',
    timestamp: DateTime.utc(2026, 10, 12),
    appVersion: '0.23.46+393',
    feature: 'test',
    errorType: 'StateError',
    errorMessage: message,
    stackTrace: stack,
    context: context,
  );

  test('écrit exactement les champs admis par les règles', () {
    final data = report().toFirestore();
    expect(data.keys.toSet(), {
      'user_id',
      'job_id',
      'timestamp',
      'app_version',
      'feature',
      'error_type',
      'error_message',
      'stack_trace',
      'context',
    });
    expect(data['context'], isA<String>());
  });

  test('message, pile et contexte de 500 Ko sont tronqués sous les bornes', () {
    final huge = 'x' * 500000;
    final data = report(
      message: huge,
      stack: huge,
      context: {for (var i = 0; i < 200; i++) 'k$i': huge},
    ).toFirestore();
    expect(
      (data['error_message'] as String).length,
      lessThanOrEqualTo(ErrorReport.maxMessage),
    );
    expect(
      (data['stack_trace'] as String).length,
      lessThanOrEqualTo(ErrorReport.maxStackTrace),
    );
    final context = data['context'] as String;
    expect(context.length, lessThanOrEqualTo(ErrorReport.maxContext));
    final decoded = jsonDecode(context) as Map<String, dynamic>;
    expect(decoded['_omis'], greaterThan(0));
  });

  test('ne coupe pas un caractère en deux', () {
    final value = '${'a' * 9}😀b';
    final cut = ErrorReport.truncate(value, 10);
    expect(cut.length, lessThanOrEqualTo(10));
    expect(cut.endsWith('…'), isTrue);
    expect(utf8.encode(cut), isNotEmpty);
  });

  test('relit le contexte écrit en JSON, et l’ancienne carte', () {
    final written = report(
      context: {'recipeId': 'r1', 'count': 3, 'flag': true},
    ).toFirestore();
    final read = ErrorReport.fromFirestore('id', {
      ...written,
      'timestamp': null,
    });
    expect(read.context, {'recipeId': 'r1', 'count': 3, 'flag': true});

    final legacy = ErrorReport.fromFirestore('id', {
      'context': {'recipeId': 'r1'},
    });
    expect(legacy.context, {'recipeId': 'r1'});

    final broken = ErrorReport.fromFirestore('id', {'context': '{pas du json'});
    expect(broken.context, {'brut': '{pas du json'});
  });
}
