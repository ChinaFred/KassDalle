import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Ce que la politique App Check fait d'un appel non attesté.
enum AppCheckMode {
  /// Rien n'est vérifié, rien n'est journalisé.
  off,

  /// Rien n'est refusé, mais chaque appel non attesté laisse une trace.
  monitor,

  /// Un appel non attesté est refusé.
  enforce;

  String get wireName => name;

  static AppCheckMode fromWire(String? value) => switch (value) {
    'off' => AppCheckMode.off,
    'enforce' => AppCheckMode.enforce,
    _ => AppCheckMode.monitor,
  };

  String get label => switch (this) {
    AppCheckMode.off => 'Désactivé',
    AppCheckMode.monitor => 'Observation',
    AppCheckMode.enforce => 'Exigé',
  };

  String get description => switch (this) {
    AppCheckMode.off =>
      'Aucune vérification, aucune trace. À réserver au diagnostic.',
    AppCheckMode.monitor =>
      'Tout passe, mais chaque appel non attesté est journalisé en '
          'avertissement. Le silence de ces traces est la condition pour exiger.',
    AppCheckMode.enforce =>
      'Un appel dont l\'application n\'est pas attestée est refusé. '
          'Le client Windows desktop ne sait pas attester : il perd l\'IA.',
  };
}

/// État de la politique, tel que le serveur le rapporte.
class AppCheckSnapshot {
  final AppCheckMode mode;

  /// L'appel qui a servi cet écran était-il lui-même attesté ?
  ///
  /// C'est le seul signal honnête avant de passer en [AppCheckMode.enforce] :
  /// si l'écran d'administration n'atteste pas, exiger l'attestation met son
  /// propre utilisateur dehors le premier. Le serveur refuse d'ailleurs le
  /// passage à `enforce` depuis un appel non attesté.
  final bool callerAttested;

  const AppCheckSnapshot({required this.mode, required this.callerAttested});
}

class AppCheckRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  AppCheckRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  Future<AppCheckSnapshot> fetch() async {
    try {
      final raw = await _functions
          .httpsCallable('getAppCheckPolicyFn')
          .call<Map<String, dynamic>>();
      return _parse(Map<String, dynamic>.from(raw.data));
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'appCheck.fetch',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<AppCheckSnapshot> save(AppCheckMode mode) async {
    try {
      final raw = await _functions
          .httpsCallable('setAppCheckPolicyFn')
          .call<Map<String, dynamic>>({'mode': mode.wireName});
      return _parse(Map<String, dynamic>.from(raw.data));
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'appCheck.save',
        error: e,
        stackTrace: st,
        context: {'mode': mode.wireName},
      );
      rethrow;
    }
  }

  AppCheckSnapshot _parse(Map<String, dynamic> data) {
    final policy = Map<String, dynamic>.from(
      data['policy'] as Map? ?? const {},
    );
    return AppCheckSnapshot(
      mode: AppCheckMode.fromWire(policy['mode'] as String?),
      callerAttested: data['callerAttested'] == true,
    );
  }
}
