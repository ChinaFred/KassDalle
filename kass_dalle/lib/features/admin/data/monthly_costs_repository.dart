import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Coûts de l'application, mois par mois.
///
/// Tout vient du serveur, déjà agrégé et déjà chiffré. Les écrans ne
/// recalculent plus rien : le coût d'un appel est figé au moment où il a lieu,
/// par la grille tarifaire du backend. La version précédente relisait chaque
/// ligne d'appel — plafonnée à mille — et appliquait la grille Dart par-dessus.
/// Deux grilles pour un même appel finissent toujours par diverger, et un
/// plafond de lecture transforme un total en échantillon sans le dire.

/// Consommation d'un poste fonctionnel sur un mois.
class FeatureCost {
  final String feature;
  final double costUsd;
  final int calls;
  final int inputTokens;
  final int outputTokens;
  final int imageOutputs;

  /// Coût par moteur à l'intérieur du poste — ce qui permet de juger une bascule.
  final Map<String, double> costByProvider;

  const FeatureCost({
    required this.feature,
    required this.costUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.imageOutputs,
    required this.costByProvider,
  });

  factory FeatureCost.fromMap(String feature, Map<String, dynamic> data) {
    final providers = <String, double>{};
    final raw = data['by_provider'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map) {
          providers[entry.key.toString()] = _toDouble(value['cost_usd']);
        }
      }
    }
    return FeatureCost(
      feature: feature,
      costUsd: _toDouble(data['cost_usd']),
      calls: _toInt(data['calls']),
      inputTokens: _toInt(data['input_tokens']),
      outputTokens: _toInt(data['output_tokens']),
      imageOutputs: _toInt(data['image_outputs']),
      costByProvider: providers,
    );
  }
}

/// Coût d'un service d'infrastructure sur un mois.
class ServiceCost {
  final String service;
  final double costUsd;

  const ServiceCost({required this.service, required this.costUsd});
}

/// Ce que l'application a coûté sur un mois donné.
class MonthlyCost {
  /// `AAAA-MM`.
  final String period;

  final double aiCostUsd;
  final int aiCalls;
  final int inputTokens;
  final int outputTokens;
  final int imageOutputs;
  final List<FeatureCost> features;

  /// Coût IA par moteur, tous postes confondus.
  final Map<String, double> costByProvider;

  /// Coût IA par utilisateur.
  final Map<String, double> costByUser;

  /// Infrastructure : Functions, Storage, Tasks, BigQuery…
  final List<ServiceCost> services;
  final double gcpCostUsd;

  /// Ce qu'Anthropic a réellement facturé ce mois-là, ou null si inconnu.
  ///
  /// Jamais additionné au coût estimé : ce sont deux mesures de la même
  /// dépense, les sommer la compterait deux fois.
  final double? anthropicBilledUsd;

  const MonthlyCost({
    required this.period,
    required this.aiCostUsd,
    required this.aiCalls,
    required this.inputTokens,
    required this.outputTokens,
    required this.imageOutputs,
    required this.features,
    required this.costByProvider,
    required this.costByUser,
    required this.services,
    required this.gcpCostUsd,
    this.anthropicBilledUsd,
  });

  double get totalCostUsd => aiCostUsd + gcpCostUsd;

  /// Coût IA estimé pour le moteur Claude, sur ce mois.
  double get anthropicEstimatedUsd => costByProvider['anthropic'] ?? 0;

  /// Écart entre le facturé Anthropic et notre estimation, ou null si l'un
  /// des deux manque.
  double? get anthropicDeltaUsd {
    final billed = anthropicBilledUsd;
    if (billed == null) return null;
    return billed - anthropicEstimatedUsd;
  }

  /// Année de la période, pour les regroupements annuels.
  String get year => period.split('-').first;

  /// Libellé court du mois, ex. « août 2026 ».
  String get label {
    final parts = period.split('-');
    if (parts.length != 2) return period;
    const mois = [
      'janvier',
      'février',
      'mars',
      'avril',
      'mai',
      'juin',
      'juillet',
      'août',
      'septembre',
      'octobre',
      'novembre',
      'décembre',
    ];
    final index = int.tryParse(parts[1]) ?? 0;
    if (index < 1 || index > 12) return period;
    return '${mois[index - 1]} ${parts[0]}';
  }

  factory MonthlyCost.fromMap(Map<String, dynamic> data) {
    final ai = Map<String, dynamic>.from(data['ai'] as Map? ?? const {});
    final gcp = Map<String, dynamic>.from(data['gcp'] as Map? ?? const {});

    final features = <FeatureCost>[];
    final rawFeatures = ai['byFeature'];
    if (rawFeatures is Map) {
      for (final entry in rawFeatures.entries) {
        final value = entry.value;
        if (value is Map) {
          features.add(
            FeatureCost.fromMap(
              entry.key.toString(),
              Map<String, dynamic>.from(value),
            ),
          );
        }
      }
    }
    features.sort((a, b) => b.costUsd.compareTo(a.costUsd));

    final services = <ServiceCost>[];
    final rawServices = gcp['services'];
    if (rawServices is List) {
      for (final entry in rawServices) {
        if (entry is Map) {
          services.add(
            ServiceCost(
              service: entry['service']?.toString() ?? 'Autre',
              costUsd: _toDouble(entry['costUsd']),
            ),
          );
        }
      }
    }

    return MonthlyCost(
      period: data['period']?.toString() ?? '',
      aiCostUsd: _toDouble(ai['totalCostUsd']),
      aiCalls: _toInt(ai['calls']),
      inputTokens: _toInt(ai['inputTokens']),
      outputTokens: _toInt(ai['outputTokens']),
      imageOutputs: _toInt(ai['imageOutputs']),
      features: features,
      costByProvider: _costMap(ai['byProvider']),
      costByUser: _costMap(ai['byUser']),
      services: services,
      gcpCostUsd: _toDouble(gcp['totalCostUsd']),
      anthropicBilledUsd: data['anthropicBilledUsd'] == null
          ? null
          : _toDouble(data['anthropicBilledUsd']),
    );
  }
}

/// Série mensuelle complète, telle que servie par le backend.
class MonthlyCostsReport {
  final List<MonthlyCost> months;
  final double usdToEur;

  /// Vrai quand la facturation Google n'a pas pu être lue : les montants
  /// d'infrastructure de ce rapport ne veulent alors rien dire.
  final bool gcpQueryFailed;

  /// Vrai quand l'historique IA remonte plus loin que la facturation Google :
  /// les mois les plus anciens n'ont alors pas de coût d'infrastructure.
  final bool gcpTruncated;

  /// Vrai quand le rapport de coûts Anthropic a pu être lu.
  final bool anthropicAvailable;

  /// Message d'échec de la lecture Anthropic, ou null.
  final String? anthropicError;

  const MonthlyCostsReport({
    required this.months,
    required this.usdToEur,
    required this.gcpQueryFailed,
    this.gcpTruncated = false,
    this.anthropicAvailable = false,
    this.anthropicError,
  });

  double get totalCostUsd =>
      months.fold(0, (sum, month) => sum + month.totalCostUsd);

  /// Les mois regroupés par année, de la plus récente à la plus ancienne.
  Map<String, List<MonthlyCost>> get byYear {
    final grouped = <String, List<MonthlyCost>>{};
    for (final month in months) {
      grouped.putIfAbsent(month.year, () => []).add(month);
    }
    return Map.fromEntries(
      grouped.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
  }
}

class MonthlyCostsRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  MonthlyCostsRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Les [months] derniers mois, IA et infrastructure réunies.
  ///
  /// [all] remonte à la première consommation enregistrée. L'IA est alors
  /// complète ; l'infrastructure s'arrête à la fenêtre d'export de la
  /// facturation Google, ce que le rapport signale.
  Future<MonthlyCostsReport> fetch({int months = 12, bool all = false}) async {
    try {
      final result = await _functions
          .httpsCallable('getMonthlyCostsFn')
          .call<dynamic>({'months': months, if (all) 'all': true});
      final data = Map<String, dynamic>.from(result.data as Map);
      final rawMonths = (data['months'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => MonthlyCost.fromMap(Map<String, dynamic>.from(m)))
          .toList(growable: false);
      return MonthlyCostsReport(
        months: rawMonths,
        usdToEur: _toDouble(data['usdToEur']),
        gcpQueryFailed: data['gcpQueryFailed'] == true,
        gcpTruncated: data['gcpTruncated'] == true,
        anthropicAvailable: data['anthropicAvailable'] == true,
        anthropicError: data['anthropicError'] as String?,
      );
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'monthly_costs_fetch',
        error: error,
        stackTrace: stackTrace,
        context: {'months': months, 'all': all},
      );
      rethrow;
    }
  }

  /// Reconstruit les agrégats depuis les lignes d'appel.
  ///
  /// Sert au rattrapage de l'historique comme à la réparation d'un mois dont
  /// les compteurs auraient dérivé.
  Future<int> rebuild({int months = 12}) async {
    try {
      final result = await _functions
          .httpsCallable('rebuildAiUsageMonthlyFn')
          .call<dynamic>({'months': months});
      final data = Map<String, dynamic>.from(result.data as Map);
      return (data['rebuilt'] as List? ?? const []).length;
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'monthly_costs_rebuild',
        error: error,
        stackTrace: stackTrace,
        context: {'months': months},
      );
      rethrow;
    }
  }
}

Map<String, double> _costMap(dynamic raw) {
  final result = <String, double>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is Map) {
        result[entry.key.toString()] = _toDouble(value['cost_usd']);
      }
    }
  }
  return result;
}

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int _toInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
