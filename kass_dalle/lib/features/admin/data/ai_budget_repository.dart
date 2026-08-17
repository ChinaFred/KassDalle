import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Plafonds de dépense d'IA, tels que le serveur les applique.
///
/// Deux plafonds et non un : le plafond en dollars ne tient plus quand la
/// grille tarifaire est illisible — les appels sont alors enregistrés **sans
/// montant**, et un plafond monétaire s'ouvrirait en grand pendant la panne.
/// Le plafond en nombre d'appels, lui, ne dépend d'aucun prix.
class AiBudgetPolicy {
  /// Plafond quotidien par compte, en dollars. `0` désactive ce critère.
  final double dailyCostUsdPerUser;

  /// Plafond quotidien d'appels par compte. `0` désactive ce critère.
  final int dailyCallsPerUser;

  /// Seuil d'alerte mensuel, tous comptes confondus. `0` = aucune alerte.
  final double monthlyAlertUsd;

  /// Coupe les deux plafonds sans les effacer — le temps d'un import massif.
  final bool enabled;

  const AiBudgetPolicy({
    required this.dailyCostUsdPerUser,
    required this.dailyCallsPerUser,
    required this.monthlyAlertUsd,
    required this.enabled,
  });

  AiBudgetPolicy copyWith({
    double? dailyCostUsdPerUser,
    int? dailyCallsPerUser,
    double? monthlyAlertUsd,
    bool? enabled,
  }) {
    return AiBudgetPolicy(
      dailyCostUsdPerUser: dailyCostUsdPerUser ?? this.dailyCostUsdPerUser,
      dailyCallsPerUser: dailyCallsPerUser ?? this.dailyCallsPerUser,
      monthlyAlertUsd: monthlyAlertUsd ?? this.monthlyAlertUsd,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toMap() => {
    'dailyCostUsdPerUser': dailyCostUsdPerUser,
    'dailyCallsPerUser': dailyCallsPerUser,
    'monthlyAlertUsd': monthlyAlertUsd,
    'enabled': enabled,
  };

  static AiBudgetPolicy fromMap(Map<String, dynamic> map) {
    return AiBudgetPolicy(
      dailyCostUsdPerUser:
          (map['dailyCostUsdPerUser'] as num?)?.toDouble() ?? 0,
      dailyCallsPerUser: (map['dailyCallsPerUser'] as num?)?.toInt() ?? 0,
      monthlyAlertUsd: (map['monthlyAlertUsd'] as num?)?.toDouble() ?? 0,
      // Absent vaut actif : un plafond qui s'éteindrait faute de champ ne
      // protégerait plus, et rien ne le dirait.
      enabled: map['enabled'] != false,
    );
  }
}

/// Ce qu'un compte a consommé aujourd'hui.
class DailySpendRow {
  final String uid;
  final double costUsd;
  final int calls;

  /// Appels passés pendant une panne de grille : comptés, jamais chiffrés.
  ///
  /// Affichés à part parce qu'ils rendent le montant **incomplet** : sans eux,
  /// une journée traversée par une panne paraîtrait simplement économe.
  final int unpricedCalls;

  const DailySpendRow({
    required this.uid,
    required this.costUsd,
    required this.calls,
    required this.unpricedCalls,
  });
}

class AiBudgetSnapshot {
  final AiBudgetPolicy policy;

  /// Jour UTC couvert par [spends], au format `AAAA-MM-JJ`.
  final String day;
  final List<DailySpendRow> spends;

  const AiBudgetSnapshot({
    required this.policy,
    required this.day,
    required this.spends,
  });
}

class AiBudgetRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  AiBudgetRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  Future<AiBudgetSnapshot> fetch() async {
    try {
      final raw = await _functions
          .httpsCallable('getAiBudgetFn')
          .call<Map<String, dynamic>>();
      final data = Map<String, dynamic>.from(raw.data);
      return AiBudgetSnapshot(
        policy: AiBudgetPolicy.fromMap(
          Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
        ),
        day: data['day'] as String? ?? '',
        spends: (data['spends'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .map(
              (e) => DailySpendRow(
                uid: e['uid'] as String? ?? '',
                costUsd: (e['costUsd'] as num?)?.toDouble() ?? 0,
                calls: (e['calls'] as num?)?.toInt() ?? 0,
                unpricedCalls: (e['unpricedCalls'] as num?)?.toInt() ?? 0,
              ),
            )
            .toList(growable: false),
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiBudget.fetch',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<AiBudgetPolicy> save(AiBudgetPolicy policy) async {
    try {
      final raw = await _functions
          .httpsCallable('setAiBudgetFn')
          .call<Map<String, dynamic>>({'policy': policy.toMap()});
      final data = Map<String, dynamic>.from(raw.data);
      return AiBudgetPolicy.fromMap(
        Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiBudget.save',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
