import 'dart:async';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../domain/data_quality_report.dart';
import '../domain/nutrition_policy.dart';
import '../domain/recipe_protein_backfill_report.dart';
import '../domain/recipe_roles_backfill_report.dart';

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

  /// Taux en vigueur, utilisé seulement si Google ne facture pas en euros.
  final double usdToEur;

  const GcpServiceCost({
    required this.service,
    required this.costUsd,
    required this.grossUsd,
    required this.creditsUsd,
    required this.costNative,
    required this.grossNative,
    required this.creditsNative,
    required this.currency,
    required this.usdToEur,
  });

  /// Montant en euros. Si Google facture déjà en euros — c'est le cas de ce
  /// compte — on rend le chiffre exact de la facture, sans conversion du tout ;
  /// sinon on convertit depuis les dollars au taux relevé.
  double get costEur => currency == 'EUR' ? costNative : costUsd * usdToEur;
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

  /// Taux en vigueur, utilisé seulement si Google ne facture pas en euros.
  final double usdToEur;
  final bool hasData;

  const GcpCostsReport({
    required this.ready,
    required this.services,
    required this.totalUsd,
    required this.totalNative,
    required this.currency,
    required this.unconvertedRows,
    required this.usdToEur,
    required this.hasData,
  });

  double get totalEur => currency == 'EUR' ? totalNative : totalUsd * usdToEur;
}

class GcpBillingRepository {
  final FirebaseFunctions _functions;

  GcpBillingRepository({FirebaseFunctions? functions})
    : _functions =
          functions ?? FirebaseFunctions.instanceFor(region: _functionsRegion);

  Future<GcpCostsReport> fetchCosts({
    required DateTime start,
    required DateTime end,
    required double usdToEur,
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
            usdToEur: usdToEur,
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
      usdToEur: usdToEur,
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
      return _callViaHttp(name, payload, timeout: timeout);
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
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw Exception(
        'Callable $name failed: code=unauthenticated, '
        'message=Utilisateur non connecté., details=null',
      );
    }
    // Jeton rafraîchi de force : le chemin web réutilisait un jeton de cache
    // qui pouvait être expiré, et un refus d'authentification arrive alors
    // sans en-tête CORS — le navigateur le présente comme un « Failed to
    // fetch » réseau, indiscernable d'une fonction injoignable.
    final idToken = await user.getIdToken(true);
    final url = Uri.parse(
      'https://$_functionsRegion-$_firebaseProjectId.cloudfunctions.net/$name',
    );
    final http.Response res;
    try {
      res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({'data': payload}),
          )
          // Le paramètre `timeout` n'était pas transmis sur ce chemin : une
          // opération longue restait suspendue sans borne, et l'échec
          // ressortait en exception réseau opaque.
          .timeout(timeout);
    } on TimeoutException {
      throw Exception(
        'Callable $name : pas de réponse après ${timeout.inMinutes} min. '
        'Le traitement se poursuit peut-être côté serveur — relancez pour '
        'reprendre au point de contrôle.',
      );
    }
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
  /// Enrichit les référentiels par passes courtes.
  ///
  /// La passe durait 8,5 minutes — au plus près du timeout de 540 s de la
  /// fonction. Or une requête de cette durée derrière un `fetch` de navigateur
  /// est fragile par nature : un intermédiaire coupe, et l'erreur revient en
  /// « Failed to fetch » sans rien dire du travail réellement accompli.
  ///
  /// Le backfill est idempotent et reprend sur point de contrôle : plusieurs
  /// passes de quatre minutes font le même travail, sans le risque. Relancer
  /// continue là où la précédente s'est arrêtée.
  ///
  /// [refreshSodium] change la cible : au lieu des profils vides, la passe
  /// reprend ceux qui portent du sodium. C'est la réparation du sel compté deux
  /// fois — une dépense volontaire, jamais le mode par défaut.
  Future<Map<String, int>> backfillEnrichReferentials({
    double maxMinutes = 4,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
    bool refreshSodium = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
      'refreshSodium': refreshSodium,
    };

    final dynamic raw = await _callViaSdk(
      'backfillEnrichReferentialsFn',
      payload,
      // Une marge au-dessus de la passe serveur, pas dix minutes : au-delà,
      // c'est l'infrastructure qui coupe, pas nous.
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'scannedUnits': (data['scannedUnits'] as num?)?.toInt() ?? 0,
      'enrichedUnits': (data['enrichedUnits'] as num?)?.toInt() ?? 0,
      'scannedIngredients': (data['scannedIngredients'] as num?)?.toInt() ?? 0,
      'enrichedIngredients':
          (data['enrichedIngredients'] as num?)?.toInt() ?? 0,
      'failedIngredients': (data['failedIngredients'] as num?)?.toInt() ?? 0,
      'refreshedIngredients':
          (data['refreshedIngredients'] as num?)?.toInt() ?? 0,
      'remainingUnitsWithoutWeight':
          (data['remainingUnitsWithoutWeight'] as num?)?.toInt() ?? 0,
      'completed': (data['completed'] == true) ? 1 : 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
    };
  }

  /// Reprend le calcul nutritionnel des recettes incomplètes, à la demande.
  ///
  /// Le passage planifié de 5 h suffit au quotidien. Celui-ci sert quand on
  /// vient de corriger un référentiel et qu'on veut voir l'effet tout de suite :
  /// il lève les deux bornes de patience du planifié — l'âge de l'instantané et
  /// le plafond de tentatives.
  ///
  /// Idempotent, avec point de reprise serveur. Relancer continue là où l'appel
  /// précédent s'est arrêté, jusqu'à ce que `completed` vaille 1.
  Future<Map<String, int>> backfillNutrition({
    double maxMinutes = 4,
    int maxRecipes = 40,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'maxRecipes': maxRecipes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    };

    final dynamic raw = await _callViaSdk(
      'backfillNutritionFn',
      payload,
      timeout: const Duration(minutes: 5),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    return {
      'examinees': (data['examinees'] as num?)?.toInt() ?? 0,
      'reprises': (data['reprises'] as num?)?.toInt() ?? 0,
      'completees': (data['completees'] as num?)?.toInt() ?? 0,
      'echouees': (data['echouees'] as num?)?.toInt() ?? 0,
      'laissees': (data['laissees'] as num?)?.toInt() ?? 0,
      'completed': (data['completed'] == true) ? 1 : 0,
      'stoppedByDeadline': (data['stoppedByDeadline'] == true) ? 1 : 0,
      'stoppedByBudget': (data['stoppedByBudget'] == true) ? 1 : 0,
    };
  }

  /// Rôle des recettes dans un repas : plat, accompagnement, entrée, dessert,
  /// snack, avec ce que la recette apporte déjà et ses accompagnements
  /// classiques. Un appel de modèle par recette non classée.
  ///
  /// Réentrante, reprise sur point de contrôle : relancer tant que le
  /// résultat indique « incomplet ». [force] reclasse aussi les recettes
  /// déjà classées. Le compte rendu porte `restantes`, compté sur toute la
  /// collection : ce qu'il reste à classer, et non ce que ce passage a fait.
  Future<RecipeRolesBackfillReport> backfillRecipeRoles({
    double maxMinutes = 8,
    int maxRecipes = 40,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
    bool force = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'maxRecipes': maxRecipes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
      'force': force,
    };

    final dynamic raw = await _callViaSdk(
      'backfillRecipeRolesFn',
      payload,
      timeout: const Duration(minutes: 9),
    );

    return RecipeRolesBackfillReport.fromMap(
      Map<String, dynamic>.from(raw as Map),
      finishedAt: DateTime.now(),
    );
  }

  /// Protéine et féculent principaux des plats et accompagnements qui n'en
  /// ont pas. Un appel de modèle par recette concernée ; rien d'autre n'est
  /// réécrit. Réentrante, reprise sur point de contrôle : relancer tant que
  /// le résultat indique « incomplet ».
  Future<RecipeProteinBackfillReport> backfillRecipeProtein({
    double maxMinutes = 8,
    int maxRecipes = 40,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final dynamic raw = await _callViaSdk('backfillRecipeProteinFn', {
      'maxMinutes': maxMinutes,
      'maxRecipes': maxRecipes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    }, timeout: const Duration(minutes: 9));

    return RecipeProteinBackfillReport.fromMap(
      Map<String, dynamic>.from(raw as Map),
      finishedAt: DateTime.now(),
    );
  }

  /// Pose [text] dans les contraintes globales de planning des autres comptes :
  /// vides, il les remplace ; écrites, il s'ajoute à la suite ; déjà présent,
  /// rien. Sans appel de modèle. Les drapeaux valent 1 ou 0.
  Future<Map<String, int>> backfillPlanningDefaults({
    required String text,
  }) async {
    final dynamic raw = await _callViaSdk(
      'backfillPlanningDefaultsFn',
      <String, dynamic>{'text': text},
      timeout: const Duration(minutes: 9),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    final out = <String, int>{};
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is num) {
        out[entry.key] = value.toInt();
      } else if (value is bool) {
        out[entry.key] = value ? 1 : 0;
      }
    }
    return out;
  }

  /// Recalcule `shopping_products` sur toutes les recettes, sans appel de
  /// modèle. Réentrante, avec reprise sur point de contrôle. Rend les
  /// compteurs tels quels ; les drapeaux valent 1 ou 0.
  Future<Map<String, int>> backfillShopping({
    double maxMinutes = 8,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    };

    final dynamic raw = await _callViaSdk(
      'backfillShoppingFn',
      payload,
      timeout: const Duration(minutes: 9),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    final out = <String, int>{};
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is num) {
        out[entry.key] = value.toInt();
      } else if (value is bool) {
        out[entry.key] = value ? 1 : 0;
      }
    }
    return out;
  }

  /// Allergènes : examine par lots de quarante les ingrédients du référentiel
  /// qui n'en ont pas (appels de modèle, poste `backfill_allergens`), puis
  /// recalcule `allergens` sur les recettes, sans appel. Réentrante, avec
  /// reprise sur point de contrôle. Rend les compteurs tels quels ; les
  /// drapeaux valent 1 ou 0.
  Future<Map<String, int>> backfillAllergens({
    double maxMinutes = 8,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    };

    final dynamic raw = await _callViaSdk(
      'backfillAllergensFn',
      payload,
      timeout: const Duration(minutes: 9),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    final out = <String, int>{};
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is num) {
        out[entry.key] = value.toInt();
      } else if (value is bool) {
        out[entry.key] = value ? 1 : 0;
      }
    }
    return out;
  }

  /// Durées estimées : estime, huit recettes par appel de modèle (poste
  /// `backfill_time_estimate_batch`), la préparation et la cuisson des
  /// recettes qui n'en donnent pas. Une recette déjà estimée pour son contenu
  /// n'est ni redemandée ni refacturée. Réentrante, avec reprise sur point de
  /// contrôle. Rend les compteurs tels quels ; les drapeaux valent 1 ou 0.
  Future<Map<String, int>> backfillEstimatedTimes({
    double maxMinutes = 8,
    bool resumeFromCheckpoint = true,
    bool resetCheckpoint = false,
  }) async {
    final payload = <String, dynamic>{
      'maxMinutes': maxMinutes,
      'resumeFromCheckpoint': resumeFromCheckpoint,
      'resetCheckpoint': resetCheckpoint,
    };

    final dynamic raw = await _callViaSdk(
      'backfillEstimatedTimesFn',
      payload,
      timeout: const Duration(minutes: 9),
    );

    final data = Map<String, dynamic>.from(raw as Map);
    final out = <String, int>{};
    for (final entry in data.entries) {
      final value = entry.value;
      if (value is num) {
        out[entry.key] = value.toInt();
      } else if (value is bool) {
        out[entry.key] = value ? 1 : 0;
      }
    }
    return out;
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

  /// Dashboard de qualité des données : quatre anomalies détectées sur les
  /// référentiels nutrition, en lecture seule. Le scan complet peut prendre
  /// plusieurs dizaines de secondes sur un gros référentiel.
  Future<DataQualityReport> getDataQualityReport() async {
    final dynamic raw = await _callViaSdk(
      'getDataQualityReportFn',
      const {},
      timeout: const Duration(minutes: 3),
    );
    return DataQualityReport.fromMap(Map<String, dynamic>.from(raw as Map));
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
}
