import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/nutrition_policy.dart';
import 'gemini_pricing.dart';

const String _functionsRegion = 'europe-west1';

/// Project ID Firebase — utilisé pour bâtir l'URL des callables en bypass web.
const String _firebaseProjectId = 'kassdale-6d948';

/// Coût agrégé d'un service GCP sur une période.
///
/// Deux montants, et non un seul converti après coup : [costNative] est le
/// chiffre de la facture, dans la devise du compte de facturation ; [costUsd]
/// est ce même montant ramené en dollars par le taux que Google a lui-même
/// appliqué. Un taux de change codé en dur donnait un troisième chiffre, faux,
/// et impossible à rapprocher de la console.
class GcpServiceCost {
  final String service;
  final double costUsd;
  final double grossUsd;
  final double creditsUsd;
  final double costNative;
  final double grossNative;
  final double creditsNative;

  /// Devise du compte de facturation, portée ici pour que [costEur] sache si
  /// [costNative] est déjà en euros.
  final String currency;

  const GcpServiceCost({
    required this.service,
    required this.costUsd,
    required this.grossUsd,
    required this.creditsUsd,
    required this.costNative,
    required this.grossNative,
    required this.creditsNative,
    required this.currency,
  });

  /// Montant en euros. Si Google facture déjà en euros — c'est le cas de ce
  /// compte — on rend le chiffre exact de la facture ; sinon on convertit
  /// depuis les dollars au taux indicatif de [GeminiPricing.usdToEur].
  double get costEur => currency == 'EUR'
      ? costNative
      : costUsd * GeminiPricing.usdToEur;
}

/// Réponse complète de la Cloud Function `getGcpCostsFn`.
class GcpCostsReport {
  /// False si l'export BigQuery n'a pas encore créé la table (premier appel
  /// dans les 24h suivant l'activation).
  final bool ready;
  final List<GcpServiceCost> services;
  final double totalUsd;

  /// Total dans la devise du compte de facturation.
  final double totalNative;

  /// Devise du compte de facturation — celle de la facture Google.
  final String currency;

  /// Lignes de facturation dépourvues de taux de change : leur montant manque
  /// aux totaux en dollars. Zéro en temps normal.
  final int unconvertedRows;
  final bool hasData;

  const GcpCostsReport({
    required this.ready,
    required this.services,
    required this.totalUsd,
    required this.totalNative,
    required this.currency,
    required this.unconvertedRows,
    required this.hasData,
  });

  double get totalEur =>
      currency == 'EUR' ? totalNative : totalUsd * GeminiPricing.usdToEur;
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
    final currency = (data['currency'] as String?) ?? 'USD';
    final services = ((data['services'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) {
          final mm = Map<String, dynamic>.from(m);
          return GcpServiceCost(
            service: (mm['service'] as String?) ?? 'Inconnu',
            costUsd: (mm['costUsd'] as num?)?.toDouble() ?? 0.0,
            grossUsd: (mm['grossUsd'] as num?)?.toDouble() ?? 0.0,
            creditsUsd: (mm['creditsUsd'] as num?)?.toDouble() ?? 0.0,
            costNative: (mm['costNative'] as num?)?.toDouble() ?? 0.0,
            grossNative: (mm['grossNative'] as num?)?.toDouble() ?? 0.0,
            creditsNative: (mm['creditsNative'] as num?)?.toDouble() ?? 0.0,
            currency: currency,
          );
        })
        .toList(growable: false);

    return GcpCostsReport(
      ready: (data['ready'] as bool?) ?? true,
      services: services,
      totalUsd: (data['totalUsd'] as num?)?.toDouble() ?? 0.0,
      totalNative: (data['totalNative'] as num?)?.toDouble() ?? 0.0,
      currency: currency,
      unconvertedRows: (data['unconvertedRows'] as num?)?.toInt() ?? 0,
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
      } catch (parseError) {
        // Le corps d'erreur n'a pas la forme attendue : on le remonte tel quel
        // dans l'exception plutôt que de le perdre silencieusement.
        details = 'corps non parsable ($parseError) : ${res.body}';
      }
      throw Exception(
        'Callable $name failed: code=$code, message=$message, details=$details',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return body['result'];
  }

  /// Backfill unique d'enrichissement des référentiels :
  /// - poids (`grams_per_unit`) des unités manquantes (estimé par IA avec le
  ///   contexte des ingrédients associés) ;
  /// - `per100g` des ingrédients manquants (estimé par IA).
  ///
  /// Idempotent, reprise sur checkpoint. Retourne les compteurs de progression :
  /// `{scannedUnits, enrichedUnits, scannedIngredients, enrichedIngredients,
  /// failedIngredients, remainingUnitsWithoutWeight, completed, stoppedByDeadline}`.
  Future<Map<String, int>> backfillEnrichReferentials({
    double maxMinutes = 8.5,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    };

    final dynamic raw = await _callViaSdk(
      'backfillEnrichReferentialsFn',
      payload,
      timeout: const Duration(minutes: 10),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scannedUnits': (data['scannedUnits'] as num?)?.toInt() ?? 0,
      'enrichedUnits': (data['enrichedUnits'] as num?)?.toInt() ?? 0,
      'scannedIngredients': (data['scannedIngredients'] as num?)?.toInt() ?? 0,
      'enrichedIngredients':
          (data['enrichedIngredients'] as num?)?.toInt() ?? 0,
      'failedIngredients': (data['failedIngredients'] as num?)?.toInt() ?? 0,
      'remainingUnitsWithoutWeight':
          (data['remainingUnitsWithoutWeight'] as num?)?.toInt() ?? 0,
      'completed': (data['completed'] == true) ? 1 : 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
    };
  }

  /// KPIs courants de normalisation des référentiels.
  /// Retourne `{recipesTotal, nutritionIngredientsTotal, nutritionIngredientsEnriched, nutritionIngredientsPending}`.
  Future<Map<String, int>> getRecipeReferentialKpis() async {
    final dynamic raw = await _callViaSdk(
      'getRecipeReferentialKpisFn',
      {},
      timeout: const Duration(minutes: 2),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'recipesTotal': (data['recipesTotal'] as num?)?.toInt() ?? 0,
      'nutritionIngredientsTotal':
          (data['nutritionIngredientsTotal'] as num?)?.toInt() ?? 0,
      'nutritionIngredientsEnriched':
          (data['nutritionIngredientsEnriched'] as num?)?.toInt() ?? 0,
      'nutritionIngredientsPending':
          (data['nutritionIngredientsPending'] as num?)?.toInt() ?? 0,
    };
  }

  /// Audite les identifiants du référentiel d'ingrédients.
  ///
  /// [apply] à false ne fait que constater ; à true, fusionne les documents
  /// devenus inatteignables vers l'identifiant que la règle en vigueur produit.
  Future<IngredientCleanupReport> cleanupIngredientReferential({
    bool apply = false,
  }) async {
    final dynamic raw = await _callViaSdk(
      'cleanupIngredientReferentialFn',
      <String, dynamic>{'apply': apply},
      timeout: const Duration(minutes: 10),
    );
    return IngredientCleanupReport.fromMap(
      Map<String, dynamic>.from(raw as Map),
    );
  }

  /// Verse la table d'amorçage des poids à la pièce dans le référentiel.
  ///
  /// Non destructif : un ingrédient qui porte déjà un poids — estimé par l'IA
  /// ou corrigé à la main — est laissé intact.
  Future<Map<String, int>> seedIngredientPieceWeights() async {
    final dynamic raw = await _callViaSdk(
      'seedIngredientPieceWeightsFn',
      const <String, dynamic>{},
      timeout: const Duration(minutes: 5),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'candidates': (data['candidates'] as num?)?.toInt() ?? 0,
      'created': (data['created'] as num?)?.toInt() ?? 0,
      'skipped': (data['skipped'] as num?)?.toInt() ?? 0,
    };
  }

  /// Relance la réconciliation des coûts IA pour [period] (`YYYY-MM`).
  ///
  /// Le rapport est aussi produit chaque mois par `scheduledAiReconciliation` :
  /// ce déclenchement manuel sert à regarder tout de suite, pas à remplacer la
  /// planification. Relancer sur une période déjà réconciliée écrase le rapport
  /// précédent — l'opération est idempotente.
  ///
  /// Retourne l'identifiant du document écrit (`ai_reconciliation_monthly/{period}`) ;
  /// c'est Firestore qui sert ensuite de source d'affichage.
  Future<String> generateAiReconciliation({required String period}) async {
    final dynamic raw = await _callViaSdk(
      'generateAiReconciliationMonthlyFn',
      <String, dynamic>{'period': period},
      timeout: const Duration(minutes: 3),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    return data['reportId'] as String? ?? period;
  }

  /// Lit la politique de calcul nutritionnel en vigueur.
  ///
  /// Tant que le document `app_config/nutrition_source_policy` n'a jamais été
  /// écrit, le backend rend ses valeurs par défaut : l'écran affiche donc ce
  /// qui s'applique réellement, pas un formulaire vide.
  Future<NutritionPolicy> fetchNutritionPolicy() async {
    final dynamic raw = await _callViaSdk(
      'getNutritionSourcePolicyFn',
      const <String, dynamic>{},
      timeout: const Duration(seconds: 30),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    final policy = data['policy'];
    if (policy is! Map) return NutritionPolicy.defaults;
    return NutritionPolicy.fromMap(Map<String, dynamic>.from(policy));
  }

  /// Enregistre la politique. Le backend borne les valeurs et refuse les
  /// incohérences — il rejette notamment un seuil « pour 100 g » plus permissif
  /// que le seuil de calcul partiel.
  Future<NutritionPolicy> saveNutritionPolicy(NutritionPolicy policy) async {
    final dynamic raw = await _callViaSdk(
      'setNutritionSourcePolicyFn',
      <String, dynamic>{'policy': policy.toPayload()},
      timeout: const Duration(seconds: 30),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    final saved = data['policy'];
    if (saved is! Map) return policy;
    return NutritionPolicy.fromMap(Map<String, dynamic>.from(saved));
  }

  /// Amorce les custom claims (rôle, révocation) de tous les comptes existants.
  ///
  /// Sans ce parcours, les règles Storage restent inertes : le déclencheur ne
  /// se réveille qu'à l'écriture d'un document utilisateur.
  Future<Map<String, int>> backfillUserClaims() async {
    final dynamic raw = await _callViaSdk(
      'backfillUserClaimsFn',
      const <String, dynamic>{},
      timeout: const Duration(minutes: 9),
    );
    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scanned': (data['scanned'] as num?)?.toInt() ?? 0,
      'updated': (data['updated'] as num?)?.toInt() ?? 0,
      'failed': (data['failed'] as num?)?.toInt() ?? 0,
    };
  }
}

/// Un document du référentiel dont l'identifiant n'est plus celui que la règle
/// de normalisation en vigueur produirait : il est devenu inatteignable.
class MisnormalizedIngredient {
  final String currentId;
  final String expectedId;
  final bool targetExists;
  final bool hasPer100g;

  const MisnormalizedIngredient({
    required this.currentId,
    required this.expectedId,
    required this.targetExists,
    required this.hasPer100g,
  });

  factory MisnormalizedIngredient.fromMap(Map<String, dynamic> data) =>
      MisnormalizedIngredient(
        currentId: data['currentId'] as String? ?? '',
        expectedId: data['expectedId'] as String? ?? '',
        targetExists: data['targetExists'] as bool? ?? false,
        hasPer100g: data['hasPer100g'] as bool? ?? false,
      );
}

/// Résultat d'un audit — ou d'une réparation — du référentiel d'ingrédients.
class IngredientCleanupReport {
  final int scanned;
  final List<MisnormalizedIngredient> misnormalized;
  final int merged;
  final int renamed;
  final int deleted;
  final bool applied;

  const IngredientCleanupReport({
    required this.scanned,
    required this.misnormalized,
    required this.merged,
    required this.renamed,
    required this.deleted,
    required this.applied,
  });

  factory IngredientCleanupReport.fromMap(Map<String, dynamic> data) =>
      IngredientCleanupReport(
        scanned: (data['scanned'] as num?)?.toInt() ?? 0,
        misnormalized: ((data['misnormalized'] as List?) ?? const [])
            .whereType<Map>()
            .map(
              (m) =>
                  MisnormalizedIngredient.fromMap(Map<String, dynamic>.from(m)),
            )
            .toList(growable: false),
        merged: (data['merged'] as num?)?.toInt() ?? 0,
        renamed: (data['renamed'] as num?)?.toInt() ?? 0,
        deleted: (data['deleted'] as num?)?.toInt() ?? 0,
        applied: data['applied'] as bool? ?? false,
      );
}
