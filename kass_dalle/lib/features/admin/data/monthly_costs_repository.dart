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

/// Part d'un moteur dans un poste fonctionnel.
class FeatureProviderCost {
  final double costUsd;
  final int calls;
  final int inputTokens;
  final int outputTokens;

  /// Jetons de raisonnement, facturés au tarif de sortie.
  final int thinkingTokens;

  const FeatureProviderCost({
    required this.costUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
  });

  static const empty = FeatureProviderCost(
    costUsd: 0,
    calls: 0,
    inputTokens: 0,
    outputTokens: 0,
    thinkingTokens: 0,
  );

  /// Coût moyen d'un appel — la grandeur qui rend deux moteurs comparables.
  ///
  /// Un poste peut coûter cher parce qu'il est appelé souvent ou parce que
  /// chaque appel est lourd ; le total seul ne distingue pas les deux.
  double get unitCostUsd => calls > 0 ? costUsd / calls : 0;

  FeatureProviderCost operator +(FeatureProviderCost other) =>
      FeatureProviderCost(
        costUsd: costUsd + other.costUsd,
        calls: calls + other.calls,
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        thinkingTokens: thinkingTokens + other.thinkingTokens,
      );

  factory FeatureProviderCost.fromMap(Map<String, dynamic> data) =>
      FeatureProviderCost(
        costUsd: _toDouble(data['cost_usd']),
        calls: _toInt(data['calls']),
        inputTokens: _toInt(data['input_tokens']),
        outputTokens: _toInt(data['output_tokens']),
        thinkingTokens: _toInt(data['thinking_tokens']),
      );
}

/// Consommation d'un poste fonctionnel sur un mois.
class FeatureCost {
  final String feature;
  final double costUsd;
  final int calls;
  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int imageOutputs;

  /// Détail par moteur à l'intérieur du poste — ce qui permet de juger une
  /// bascule : sans lui, on voit le coût monter sans savoir lequel des deux
  /// moteurs le fait monter.
  final Map<String, FeatureProviderCost> byProvider;

  const FeatureCost({
    required this.feature,
    required this.costUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    required this.imageOutputs,
    required this.byProvider,
  });

  FeatureProviderCost provider(String name) =>
      byProvider[name] ?? FeatureProviderCost.empty;

  /// Coût moyen d'un appel, tous moteurs confondus.
  double get unitCostUsd => calls > 0 ? costUsd / calls : 0;

  factory FeatureCost.fromMap(String feature, Map<String, dynamic> data) {
    final providers = <String, FeatureProviderCost>{};
    final raw = data['by_provider'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map) {
          providers[entry.key.toString()] = FeatureProviderCost.fromMap(
            Map<String, dynamic>.from(value),
          );
        }
      }
    }
    return FeatureCost(
      feature: feature,
      costUsd: _toDouble(data['cost_usd']),
      calls: _toInt(data['calls']),
      inputTokens: _toInt(data['input_tokens']),
      outputTokens: _toInt(data['output_tokens']),
      thinkingTokens: _toInt(data['thinking_tokens']),
      imageOutputs: _toInt(data['image_outputs']),
      byProvider: providers,
    );
  }
}

/// Ce qu'un moteur d'IA a consommé et coûté sur un mois.
///
/// Deux mesures de la même dépense cohabitent ici sans jamais s'additionner :
/// ce que nous avons estimé au moment de l'appel, et ce que le fournisseur a
/// réellement facturé. Les sommer compterait la dépense deux fois ; ne garder
/// que l'estimation laisserait une dérive s'installer sans témoin.
class ProviderCost {
  final double estimatedUsd;

  /// Facturé par le fournisseur, ou null quand la facture est illisible.
  ///
  /// `null` n'est pas zéro : un export en panne ne prouve pas une dépense nulle.
  final double? billedUsd;

  final int calls;
  final int inputTokens;
  final int outputTokens;

  /// Jetons de raisonnement : invisibles dans la réponse, facturés au tarif de
  /// sortie. Les compter à part est ce qui distingue un poste qui produit
  /// beaucoup d'un poste qui fait beaucoup réfléchir.
  final int thinkingTokens;

  /// Le détail de la facture du fournisseur, ligne par ligne.
  ///
  /// Un écart réduit à un seul nombre ne se diagnostique pas. Rapproché des
  /// lignes de la facture, il désigne le poste sous-compté.
  final List<BilledLine> billedLines;

  const ProviderCost({
    required this.estimatedUsd,
    required this.billedUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    this.billedLines = const [],
  });

  static const empty = ProviderCost(
    estimatedUsd: 0,
    billedUsd: null,
    calls: 0,
    inputTokens: 0,
    outputTokens: 0,
    thinkingTokens: 0,
  );

  int get totalTokens => inputTokens + outputTokens + thinkingTokens;

  /// Le montant retenu pour les totaux : le facturé s'il existe, l'estimé sinon.
  double get effectiveUsd => billedUsd ?? estimatedUsd;

  /// Écart entre facturé et estimé, ou null si l'un des deux manque.
  double? get deltaUsd {
    final billed = billedUsd;
    if (billed == null) return null;
    return billed - estimatedUsd;
  }

  /// Écart relatif à la facture, ou null quand il n'est pas calculable.
  double? get deltaRatio {
    final billed = billedUsd;
    if (billed == null || billed == 0) return null;
    return (billed - estimatedUsd) / billed;
  }

  /// Vrai quand le moteur n'a ni consommé ni été facturé : rien à afficher.
  bool get isEmpty => calls == 0 && estimatedUsd == 0 && (billedUsd ?? 0) == 0;

  factory ProviderCost.fromMap(Map<String, dynamic> data) => ProviderCost(
    estimatedUsd: _toDouble(data['estimatedUsd']),
    billedUsd: data['billedUsd'] == null ? null : _toDouble(data['billedUsd']),
    calls: _toInt(data['calls']),
    inputTokens: _toInt(data['inputTokens']),
    outputTokens: _toInt(data['outputTokens']),
    thinkingTokens: _toInt(data['thinkingTokens']),
    billedLines: (data['billedLines'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => BilledLine.fromMap(Map<String, dynamic>.from(e)))
        .toList(growable: false),
  );
}

/// Une ligne de la facture du fournisseur, telle qu'il la libelle.
class BilledLine {
  final String label;
  final double costUsd;

  /// Quantité facturée et son unité, quand le fournisseur les renseigne.
  final double amount;
  final String unit;

  const BilledLine({
    required this.label,
    required this.costUsd,
    required this.amount,
    required this.unit,
  });

  factory BilledLine.fromMap(Map<String, dynamic> data) => BilledLine(
    label: data['sku']?.toString() ?? 'Ligne non libellée',
    costUsd: _toDouble(data['costUsd']),
    amount: _toDouble(data['amount']),
    unit: data['unit']?.toString() ?? '',
  );
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

  /// Taux USD → EUR de ce mois-là, tel que Google l'a appliqué à sa facture.
  ///
  /// Un taux par mois, pas un taux global : convertir une dépense de l'an
  /// dernier au cours d'aujourd'hui donne un montant que personne n'a payé.
  final double usdToEur;

  final double aiCostUsd;
  final int aiCalls;

  /// Appels partis chez le fournisseur puis échoués : facturés sans rien rendre.
  final int failedCalls;

  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int imageOutputs;
  final List<FeatureCost> features;

  /// Claude et Gemini, rendus sous la même forme pour être comparables.
  final ProviderCost anthropic;
  final ProviderCost gemini;

  /// Ce qui n'est pas de l'inférence — scan de sécurité, traitements internes.
  final ProviderCost internal;

  /// Coût IA par utilisateur.
  final Map<String, double> costByUser;

  /// Infrastructure : Functions, Storage, Tasks, BigQuery… L'inférence Gemini
  /// en est retirée, elle a sa propre section.
  final List<ServiceCost> services;
  final double gcpCostUsd;

  /// Total du mois, calculé par le serveur : facturé quand il est connu,
  /// estimé sinon.
  final double totalCostUsd;

  const MonthlyCost({
    required this.period,
    required this.usdToEur,
    required this.aiCostUsd,
    required this.aiCalls,
    required this.failedCalls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    required this.imageOutputs,
    required this.features,
    required this.anthropic,
    required this.gemini,
    required this.internal,
    required this.costByUser,
    required this.services,
    required this.gcpCostUsd,
    required this.totalCostUsd,
  });

  /// Jetons consommés sur le mois, raisonnement compris.
  int get totalTokens => inputTokens + outputTokens + thinkingTokens;

  /// Ce qu'Anthropic a réellement facturé, ou null si inconnu.
  double? get anthropicBilledUsd => anthropic.billedUsd;

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

    final gcpCostUsd = _toDouble(gcp['totalCostUsd']);
    final aiCostUsd = _toDouble(ai['totalCostUsd']);

    return MonthlyCost(
      period: data['period']?.toString() ?? '',
      usdToEur: _toDouble(data['usdToEur']),
      aiCostUsd: aiCostUsd,
      aiCalls: _toInt(ai['calls']),
      failedCalls: _toInt(ai['failedCalls']),
      inputTokens: _toInt(ai['inputTokens']),
      outputTokens: _toInt(ai['outputTokens']),
      thinkingTokens: _toInt(ai['thinkingTokens']),
      imageOutputs: _toInt(ai['imageOutputs']),
      features: features,
      anthropic: _provider(data['anthropic']),
      gemini: _provider(data['gemini']),
      internal: _provider(data['internal']),
      costByUser: _costMap(ai['byUser']),
      services: services,
      gcpCostUsd: gcpCostUsd,
      totalCostUsd: data['totalCostUsd'] == null
          ? aiCostUsd + gcpCostUsd
          : _toDouble(data['totalCostUsd']),
    );
  }
}

/// Série mensuelle complète, telle que servie par le backend.
class MonthlyCostsReport {
  final List<MonthlyCost> months;

  /// Taux de dernier recours, pour les mois sans facture Google.
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

  /// Jetons consommés sur toute la période affichée.
  int get totalTokens => months.fold(0, (sum, month) => sum + month.totalTokens);

  /// Taux du mois le plus récent qui en porte un — celui du haut de l'écran.
  double get latestRate {
    for (final month in months.reversed) {
      if (month.usdToEur > 0) return month.usdToEur;
    }
    return usdToEur;
  }

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

ProviderCost _provider(dynamic raw) => raw is Map
    ? ProviderCost.fromMap(Map<String, dynamic>.from(raw))
    : ProviderCost.empty;

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
