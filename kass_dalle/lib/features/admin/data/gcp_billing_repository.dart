import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'gemini_pricing.dart';

const String _functionsRegion = 'europe-west1';

/// Project ID Firebase — utilisé pour bâtir l'URL des callables en bypass web.
const String _firebaseProjectId = 'kassdale-6d948';

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

  Future<dynamic> _callViaSdk(
    String name,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    // Sur web, on bypass le SDK `cloud_functions_web` : il souffre d'un bug
    // dart2js ("Int64 accessor not supported") qui fait échouer l'encodage des
    // payloads contenant des entiers (ex: `limit`) AVANT même que la requête
    // parte, remonté en `internal` opaque (details=null). On fait donc un POST
    // HTTP direct, comme dans GeminiService.
    if (kIsWeb) {
      return _callViaHttp(name, payload);
    }
    try {
      // Rafraîchit le token côté client pour éviter les appels callable avec
      // header Authorization vide sur certaines sessions web.
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
      final res = await _functions
          .httpsCallable(name, options: HttpsCallableOptions(timeout: timeout))
          .call<dynamic>(payload);
      return res.data;
    } on FirebaseFunctionsException catch (e, st) {
      final details = e.details;
      throw Exception(
        'Callable $name failed: code=${e.code}, message=${e.message ?? 'n/a'}, '
        'details=$details\n$st',
      );
    }
  }

  /// Appel HTTP direct au endpoint callable (web uniquement).
  ///
  /// Format Firebase Callable : body `{"data": {...}}`, réponse `{"result": {...}}`.
  /// En cas d'erreur, on décode le corps `{error: {status, message, details}}`
  /// pour remonter le vrai message serveur (y compris le correlationId).
  Future<dynamic> _callViaHttp(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception(
        'Callable $name failed: code=unauthenticated, '
        'message=Utilisateur non connecté., details=null',
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
      dynamic details;
      try {
        final err = jsonDecode(res.body) as Map<String, dynamic>;
        final errObj = err['error'] as Map<String, dynamic>?;
        if (errObj != null) {
          code = (errObj['status'] as String?)?.toLowerCase() ?? code;
          message = (errObj['message'] as String?) ?? message;
          details = errObj['details'];
        }
      } catch (_) {}
      throw Exception(
        'Callable $name failed: code=$code, message=$message, details=$details',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['result'];
  }

  /// Déclenche le backfill des entrées `ai_usage` pour les améliorations
  /// d'images passées. Retourne `{created, skipped, total}`.
  Future<Map<String, int>> backfillEnhanceUsage() async {
    final dynamic raw = await _callViaSdk(
      'backfillEnhanceUsageFn',
      {},
      timeout: const Duration(minutes: 5),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'created': (data['created'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'total': (data['total'] as num?)?.toInt() ?? 0,
    };
  }

  /// Backfill des appels Gemini non tracés dans `ai_usage` depuis Cloud Logging.
  /// Retourne `{created, skipped, scanned}` + détails de skip.
  Future<Map<String, int>> backfillAiUsageFromLogs({
    required DateTime start,
    required DateTime end,
  }) async {
    final payload = <String, dynamic>{
      'startMs': start.toUtc().millisecondsSinceEpoch,
      'endMs': end.toUtc().millisecondsSinceEpoch,
    };

    final dynamic raw = await _callViaSdk(
      'backfillAiUsageFromLogsFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'created': (data['created'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
      'skippedNotGeminiSuccess':
          (data['skippedNotGeminiSuccess'] as num?)?.toInt() ?? 0,
      'skippedMissingFeatureOrUsage':
          (data['skippedMissingFeatureOrUsage'] as num?)?.toInt() ?? 0,
      'skippedAlreadyExists':
          (data['skippedAlreadyExists'] as num?)?.toInt() ?? 0,
    };
  }

  /// Backfill des `shopping_products` sur les recettes existantes.
  /// Retourne `{scanned, updated, skipped, failed, stoppedByDeadline, remaining}`.
  Future<Map<String, int>> backfillShoppingProducts({
    int limit = 50,
    bool onlyMissing = true,
  }) async {
    final payload = <String, dynamic>{
      'limit': limit,
      'onlyMissing': onlyMissing,
    };

    final dynamic raw = await _callViaSdk(
      'backfillShoppingProductsFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
      'updated': (data['updated'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
      'remaining': (data['remaining'] as num?)?.toInt() ?? 0,
    };
  }

  /// Backfill des snapshots nutrition sur les recettes existantes.
  /// Retourne `{scanned, updated, skipped, failed, stoppedByDeadline, remaining}`.
  Future<Map<String, int>> backfillRecipeNutrition({
    int limit = 50,
    bool onlyMissing = true,
  }) async {
    final payload = <String, dynamic>{
      'limit': limit,
      'onlyMissing': onlyMissing,
    };

    final dynamic raw = await _callViaSdk(
      'backfillRecipeNutritionFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
      'updated': (data['updated'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
      'remaining': (data['remaining'] as num?)?.toInt() ?? 0,
    };
  }

  /// Bootstrap de `nutrition_ingredients` depuis les ingrédients des recettes.
  /// Retourne:
  /// `{scannedRecipes, scannedIngredients, created, updatedExisting, skippedInvalid, failed, stoppedByDeadline}`.
  Future<Map<String, int>> backfillNutritionIngredientsFromRecipes({
    int limit = 200,
  }) async {
    final payload = <String, dynamic>{'limit': limit};

    final dynamic raw = await _callViaSdk(
      'backfillNutritionIngredientsFromRecipesFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scannedRecipes': (data['scannedRecipes'] as num?)?.toInt() ?? 0,
      'scannedIngredients': (data['scannedIngredients'] as num?)?.toInt() ?? 0,
      'created': (data['created'] as num?)?.toInt() ?? 0,
      'updatedExisting': (data['updatedExisting'] as num?)?.toInt() ?? 0,
      'skippedInvalid': (data['skippedInvalid'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
    };
  }

  /// Enrichit `nutrition_ingredients` en valeurs `per100g` via IA.
  /// Retourne `{scanned, enriched, skippedNoName, skippedHasPer100g, failed, remaining, stoppedByDeadline}`.
  Future<Map<String, int>> backfillNutritionIngredientsPer100g({
    int limit = 120,
    bool onlyPending = true,
  }) async {
    final payload = <String, dynamic>{
      'limit': limit,
      'onlyPending': onlyPending,
    };

    final dynamic raw = await _callViaSdk(
      'backfillNutritionIngredientsPer100gFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
      'enriched': (data['enriched'] as num?)?.toInt() ?? 0,
      'skippedNoName': (data['skippedNoName'] as num?)?.toInt() ?? 0,
      'skippedHasPer100g': (data['skippedHasPer100g'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
      'remaining': (data['remaining'] as num?)?.toInt() ?? 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
    };
  }

  /// Inventorie les unites observees dans les recettes vers `nutrition_units`.
  /// Retourne:
  /// `{scannedRecipes, scannedUnits, createdKnown, createdUnknown, updatedExisting, inferredPieceUnits, skippedInvalid, failed, stoppedByDeadline}`.
  Future<Map<String, int>> backfillNutritionUnitsFromRecipes({
    int limit = 200,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final payload = <String, dynamic>{
      'limit': limit,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    };

    final dynamic raw = await _callViaSdk(
      'backfillNutritionUnitsFromRecipesFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scannedRecipes': (data['scannedRecipes'] as num?)?.toInt() ?? 0,
      'scannedUnits': (data['scannedUnits'] as num?)?.toInt() ?? 0,
      'createdKnown': (data['createdKnown'] as num?)?.toInt() ?? 0,
      'createdUnknown': (data['createdUnknown'] as num?)?.toInt() ?? 0,
      'updatedExisting': (data['updatedExisting'] as num?)?.toInt() ?? 0,
      'inferredPieceUnits': (data['inferredPieceUnits'] as num?)?.toInt() ?? 0,
      'skippedInvalid': (data['skippedInvalid'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
    };
  }

  /// Supprime integralement nutrition_units et nutrition_ingredients,
  /// puis remet a zero les curseurs de backfill.
  /// Retourne `{deletedNutritionUnits, deletedNutritionIngredients}`.
  Future<Map<String, int>> resetNutritionReferences() async {
    final dynamic raw = await _callViaSdk(
      'resetNutritionReferencesFn',
      {'confirm': true},
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'deletedNutritionUnits': (data['deletedNutritionUnits'] as num?)?.toInt() ?? 0,
      'deletedNutritionIngredients': (data['deletedNutritionIngredients'] as num?)?.toInt() ?? 0,
    };
  }

  /// Rebuild global nutrition (normalisation référentiel + enrichissement + recalcul recettes).
  /// Retourne les compteurs de progression et l'état global `completed`.
  Future<Map<String, int>> rebuildAllNutrition({
    double maxMinutes = 8.5,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
    };

    final dynamic raw = await _callViaSdk(
      'rebuildAllNutritionFn',
      payload,
      timeout: const Duration(minutes: 10),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'normalizedDocs': (data['normalizedDocs'] as num?)?.toInt() ?? 0,
      'mergedDocs': (data['mergedDocs'] as num?)?.toInt() ?? 0,
      'enrichedDocs': (data['enrichedDocs'] as num?)?.toInt() ?? 0,
      'enrichmentFailed': (data['enrichmentFailed'] as num?)?.toInt() ?? 0,
      'recomputedRecipes': (data['recomputedRecipes'] as num?)?.toInt() ?? 0,
      'recomputeFailed': (data['recomputeFailed'] as num?)?.toInt() ?? 0,
      'remainingIngredientsWithoutPer100g':
          (data['remainingIngredientsWithoutPer100g'] as num?)?.toInt() ?? 0,
      'remainingRecipesWithoutNutrition':
          (data['remainingRecipesWithoutNutrition'] as num?)?.toInt() ?? 0,
      'completed': (data['completed'] == true) ? 1 : 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
    };
  }
}
