import 'package:flutter/foundation.dart';

import 'error_report_service.dart';

/// Remontée d'erreur « best-effort » pour les endroits qui ne peuvent pas
/// attendre l'écriture Firestore : couche présentation, callbacks de widgets,
/// traitements dégradés qui doivent continuer malgré l'échec.
///
/// La règle du projet est qu'aucun `catch` ne reste silencieux (voir CLAUDE.md).
/// Dans les repositories et services qui possèdent déjà un `_errorReportService`
/// injecté, c'est celui-là qu'il faut utiliser. Cette fonction est le recours
/// pour tout le reste : elle évite d'avoir à injecter le service dans chaque
/// widget, sans pour autant laisser l'erreur disparaître.
///
/// L'appel est volontairement synchrone et non attendu : l'interface ne doit
/// jamais se figer parce qu'un rapport d'erreur met du temps à partir.
void reportUnexpectedError({
  required String feature,
  required Object error,
  StackTrace? stackTrace,
  Map<String, dynamic> context = const {},
  String? userId,
  String? jobId,
  ErrorReportService? service,
}) {
  final reporter = service ?? ErrorReportService();
  reporter
      .reportError(
        feature: feature,
        error: error,
        stackTrace: stackTrace,
        context: context,
        userId: userId,
        jobId: jobId,
      )
      .catchError((Object reportingError, StackTrace reportingStack) {
        // Dernier recours : si la remontée elle-même échoue (hors ligne, règles
        // Firestore, quota), il ne reste que la console. On perd l'erreur en
        // production, mais on ne masque ni l'erreur d'origine ni celle-ci.
        debugPrint(
          '[reportUnexpectedError] échec de la remontée pour "$feature" : '
          '$reportingError\n$reportingStack\n'
          'Erreur d\'origine : $error',
        );
        return '';
      });
}
