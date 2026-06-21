import 'package:cloud_functions/cloud_functions.dart';

import 'gemini_pricing.dart';

const String _functionsRegion = 'europe-west1';

/// Coût agrégé d'un service GCP sur une période.
class GcpServiceCost {
  final String service;
  final double costUsd;
  final double grossUsd;
  final double creditsUsd;

  const GcpServiceCost({
    required this.service,
    required this.costUsd,
    required this.grossUsd,
    required this.creditsUsd,
  });

  double get costEur => costUsd * GeminiPricing.usdToEur;
}

/// Réponse complète de la Cloud Function `getGcpCostsFn`.
class GcpCostsReport {
  /// False si l'export BigQuery n'a pas encore créé la table (premier appel
  /// dans les 24h suivant l'activation).
  final bool ready;
  final List<GcpServiceCost> services;
  final double totalUsd;
  final String currency;
  final bool hasData;

  const GcpCostsReport({
    required this.ready,
    required this.services,
    required this.totalUsd,
    required this.currency,
    required this.hasData,
  });

  double get totalEur => totalUsd * GeminiPricing.usdToEur;
}

class GcpBillingRepository {
  final FirebaseFunctions _functions;

  GcpBillingRepository({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: _functionsRegion);

  Future<GcpCostsReport> fetchCosts({
    required DateTime start,
    required DateTime end,
  }) async {
    final payload = <String, dynamic>{
      'startMs': start.toUtc().millisecondsSinceEpoch,
      'endMs': end.toUtc().millisecondsSinceEpoch,
    };

    final dynamic raw = await _callViaSdk('getGcpCostsFn', payload);

    final data = Map<String, dynamic>.from(raw as Map);
    final services = ((data['services'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) {
          final mm = Map<String, dynamic>.from(m);
          return GcpServiceCost(
            service: (mm['service'] as String?) ?? 'Inconnu',
            costUsd: (mm['costUsd'] as num?)?.toDouble() ?? 0.0,
            grossUsd: (mm['grossUsd'] as num?)?.toDouble() ?? 0.0,
            creditsUsd: (mm['creditsUsd'] as num?)?.toDouble() ?? 0.0,
          );
        })
        .toList(growable: false);

    return GcpCostsReport(
      ready: (data['ready'] as bool?) ?? true,
      services: services,
      totalUsd: (data['totalUsd'] as num?)?.toDouble() ?? 0.0,
      currency: (data['currency'] as String?) ?? 'USD',
      hasData: (data['hasData'] as bool?) ?? services.isNotEmpty,
    );
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

  /// Déclenche le backfill des entrées `ai_usage` pour les améliorations
  /// d'images passées. Retourne `{created, skipped, total}`.
  Future<Map<String, int>> backfillEnhanceUsage() async {
    final dynamic raw = await _callViaSdk('backfillEnhanceUsageFn', {});
    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'created': (data['created'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'total': (data['total'] as num?)?.toInt() ?? 0,
    };
  }

  /// Backfill des appels Gemini non tracés dans `ai_usage` depuis Cloud Logging.
  /// Retourne `{created, skipped, scanned}`.
  Future<Map<String, int>> backfillAiUsageFromLogs({
    required DateTime start,
    required DateTime end,
  }) async {
    final payload = <String, dynamic>{
      'startMs': start.toUtc().millisecondsSinceEpoch,
      'endMs': end.toUtc().millisecondsSinceEpoch,
    };

    final dynamic raw = await _callViaSdk('backfillAiUsageFromLogsFn', payload);

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'created': (data['created'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
    };
  }

  /// Backfill des `shopping_products` sur les recettes existantes.
  /// Retourne `{scanned, updated, skipped, failed}`.
  Future<Map<String, int>> backfillShoppingProducts({
    int limit = 300,
    bool onlyMissing = true,
  }) async {
    final payload = <String, dynamic>{
      'limit': limit,
      'onlyMissing': onlyMissing,
    };

    final dynamic raw = await _callViaSdk(
      'backfillShoppingProductsFn',
      payload,
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
      'updated': (data['updated'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
    };
  }
}
