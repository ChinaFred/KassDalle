import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Plafonds de dépense d'IA, tels que le serveur les applique.
///
/// Le plafond se règle en **euros**, la monnaie du foyer, alors que les
/// fournisseurs facturent en dollars : la comparaison passe par le taux relevé
/// sur la facture. Sans taux, le plafond monétaire devient inapplicable — et
/// c'est le plafond en **nombre d'appels** qui tient, lui qui ne dépend ni d'un
/// prix ni d'un taux.
class AiBudgetPolicy {
  /// Plafond quotidien par compte, en euros. `0` désactive ce critère.
  final double dailyCostEurPerUser;

  /// Plafond quotidien d'appels par compte. `0` désactive ce critère.
  final int dailyCallsPerUser;

  /// Seuil d'alerte mensuel, tous comptes confondus, en euros. `0` = aucune.
  final double monthlyAlertEur;

  /// Coupe les deux plafonds sans les effacer — le temps d'un import massif.
  final bool enabled;

  const AiBudgetPolicy({
    required this.dailyCostEurPerUser,
    required this.dailyCallsPerUser,
    required this.monthlyAlertEur,
    required this.enabled,
  });

  AiBudgetPolicy copyWith({
    double? dailyCostEurPerUser,
    int? dailyCallsPerUser,
    double? monthlyAlertEur,
    bool? enabled,
  }) {
    return AiBudgetPolicy(
      dailyCostEurPerUser: dailyCostEurPerUser ?? this.dailyCostEurPerUser,
      dailyCallsPerUser: dailyCallsPerUser ?? this.dailyCallsPerUser,
      monthlyAlertEur: monthlyAlertEur ?? this.monthlyAlertEur,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toMap() => {
    'dailyCostEurPerUser': dailyCostEurPerUser,
    'dailyCallsPerUser': dailyCallsPerUser,
    'monthlyAlertEur': monthlyAlertEur,
    'enabled': enabled,
  };

  static AiBudgetPolicy fromMap(Map<String, dynamic> map) {
    return AiBudgetPolicy(
      dailyCostEurPerUser:
          (map['dailyCostEurPerUser'] as num?)?.toDouble() ?? 0,
      dailyCallsPerUser: (map['dailyCallsPerUser'] as num?)?.toInt() ?? 0,
      monthlyAlertEur: (map['monthlyAlertEur'] as num?)?.toDouble() ?? 0,
      // Absent vaut actif : un plafond qui s'éteindrait faute de champ ne
      // protégerait plus, et rien ne le dirait.
      enabled: map['enabled'] != false,
    );
  }
}

/// Dépense d'un poste, pour un compte et sur la période demandée.
class FeatureSpend {
  final String feature;
  final double costUsd;
  final int calls;

  const FeatureSpend({
    required this.feature,
    required this.costUsd,
    required this.calls,
  });
}

/// Dépense d'un compte sur la période, avec sa ventilation par poste.
class UserSpend {
  final String uid;

  /// Nom d'affichage, ou l'identifiant quand le compte n'existe plus.
  final String label;
  final double costUsd;
  final int calls;
  final List<FeatureSpend> byFeature;

  const UserSpend({
    required this.uid,
    required this.label,
    required this.costUsd,
    required this.calls,
    required this.byFeature,
  });
}

/// Ce qu'un compte a consommé aujourd'hui — la seule unité où un plafond
/// quotidien a du sens.
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

  /// Taux dollar → euro relevé sur la facture, `null` si aucun.
  ///
  /// `null` n'est pas un détail d'affichage : c'est l'état où le plafond en
  /// euros ne s'applique pas, et où seul le compteur d'appels protège.
  final double? usdToEur;

  /// Le compte qui dispose du multiplicateur, et sa valeur.
  final String? founderUid;
  final int founderMultiplier;

  /// Jour UTC couvert par [today], au format `AAAA-MM-JJ`.
  final String day;

  /// Mois réellement lus pour [spends].
  final List<String> periods;

  /// Mois trop anciens pour porter la ventilation par poste.
  ///
  /// Elle n'est écrite que depuis la v0.20.21 : avant, un mois ne connaît que
  /// le total par compte. Le dire vaut mieux qu'un détail vide, qui se lirait
  /// « rien dépensé ». Une reconstruction des agrégats les rattrape.
  final List<String> periodsWithoutBreakdown;

  final List<UserSpend> spends;
  final List<DailySpendRow> today;

  const AiBudgetSnapshot({
    required this.policy,
    required this.usdToEur,
    required this.founderUid,
    required this.founderMultiplier,
    required this.day,
    required this.periods,
    required this.periodsWithoutBreakdown,
    required this.spends,
    required this.today,
  });

  /// Le plafond applicable à un compte, multiplicateur du fondateur compris.
  double costLimitEurFor(String uid) =>
      policy.dailyCostEurPerUser * (uid == founderUid ? founderMultiplier : 1);

  int callsLimitFor(String uid) =>
      policy.dailyCallsPerUser * (uid == founderUid ? founderMultiplier : 1);
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

  /// [depth] : nombre de mois à lire, `null` pour tout l'historique — la même
  /// convention que les deux autres onglets de la comptabilité.
  Future<AiBudgetSnapshot> fetch({int? depth}) async {
    try {
      final raw = await _functions
          .httpsCallable('getAiBudgetFn')
          .call<Map<String, dynamic>>({'depth': depth});
      return _parse(Map<String, dynamic>.from(raw.data));
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiBudget.fetch',
        error: e,
        stackTrace: st,
        context: {'depth': depth?.toString() ?? 'all'},
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

  AiBudgetSnapshot _parse(Map<String, dynamic> data) {
    final names = Map<String, dynamic>.from(data['names'] as Map? ?? const {});

    final spends = (data['spends'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map((e) {
          final uid = e['uid'] as String? ?? '';
          final rawFeatures = Map<String, dynamic>.from(
            e['byFeature'] as Map? ?? const {},
          );
          final features =
              rawFeatures.entries
                  .map(
                    (entry) => FeatureSpend(
                      feature: entry.key,
                      costUsd:
                          ((entry.value as Map?)?['costUsd'] as num?)
                              ?.toDouble() ??
                          0,
                      calls:
                          ((entry.value as Map?)?['calls'] as num?)?.toInt() ??
                          0,
                    ),
                  )
                  .toList()
                ..sort((a, b) => b.costUsd.compareTo(a.costUsd));

          return UserSpend(
            uid: uid,
            label: (names[uid] as String?) ?? uid,
            costUsd: (e['costUsd'] as num?)?.toDouble() ?? 0,
            calls: (e['calls'] as num?)?.toInt() ?? 0,
            byFeature: features,
          );
        })
        .toList(growable: false);

    return AiBudgetSnapshot(
      policy: AiBudgetPolicy.fromMap(
        Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
      ),
      usdToEur: (data['usdToEur'] as num?)?.toDouble(),
      founderUid: data['founderUid'] as String?,
      founderMultiplier: (data['founderMultiplier'] as num?)?.toInt() ?? 1,
      day: data['day'] as String? ?? '',
      periods: (data['periods'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      periodsWithoutBreakdown:
          (data['periodsWithoutBreakdown'] as List? ?? const [])
              .map((e) => e.toString())
              .toList(growable: false),
      spends: spends,
      today: (data['today'] as List? ?? const [])
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
  }
}
