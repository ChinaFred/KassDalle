import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_reporting.dart';

/// Fournisseur d'inférence d'un appel enregistré.
///
/// Déduit du modèle quand le champ `provider` est absent : les enregistrements
/// antérieurs à l'arrivée de Claude n'en portent pas, et une ligne « source
/// inconnue » sur tout l'historique rendrait la comparaison illisible.
String providerFromRecord({String? provider, required String model}) {
  final declared = (provider ?? '').trim();
  if (declared.isNotEmpty) return declared;
  return model.startsWith('claude') ? 'anthropic' : 'gemini';
}

/// Libellé lisible d'un fournisseur.
String providerLabel(String provider) => switch (provider) {
  'anthropic' => 'Claude',
  'gemini' => 'Gemini',
  _ => provider,
};

/// Enregistrement d'un appel d'IA.
class TokenUsageRecord {
  final String uid;
  final String feature;
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final String model;

  /// `gemini` ou `anthropic` — déduit du modèle pour l'historique.
  final String provider;
  final DateTime timestamp;
  final int imageOutputCount;

  const TokenUsageRecord({
    required this.uid,
    required this.feature,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.model,
    required this.provider,
    required this.timestamp,
    this.imageOutputCount = 0,
  });

  factory TokenUsageRecord.fromFirestore(Map<String, dynamic> data) {
    final model = data['model'] as String? ?? '';
    return TokenUsageRecord(
      uid: data['uid'] as String? ?? '',
      feature: data['feature'] as String? ?? '',
      inputTokens: data['input_tokens'] as int? ?? 0,
      outputTokens: data['output_tokens'] as int? ?? 0,
      totalTokens: data['total_tokens'] as int? ?? 0,
      model: model,
      provider: providerFromRecord(
        provider: data['provider'] as String?,
        model: model,
      ),
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      imageOutputCount: data['image_output_count'] as int? ?? 0,
    );
  }
}

/// Agrégation des tokens par utilisateur, feature, période et fournisseur.
class TokenUsageSummary {
  final String uid;
  final String feature;
  final String period; // "YYYY-MM"

  /// Fournisseur de la ligne, ou `null` quand l'agrégat est **globalisé** —
  /// c'est-à-dire tous fournisseurs confondus.
  final String? provider;
  final int totalInputTokens;
  final int totalOutputTokens;
  final int totalTokens;
  final int callCount;

  const TokenUsageSummary({
    required this.uid,
    required this.feature,
    required this.period,
    this.provider,
    required this.totalInputTokens,
    required this.totalOutputTokens,
    required this.totalTokens,
    required this.callCount,
  });
}

class TokenUsageRepository {
  final FirebaseFirestore _firestore;
  static const _collection = 'ai_usage';

  TokenUsageRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Enregistre un appel Gemini.
  Future<void> logUsage({
    required String uid,
    required String feature,
    required int inputTokens,
    required int outputTokens,
    required int totalTokens,
    required String model,
  }) async {
    try {
      await _firestore.collection(_collection).add({
        'uid': uid,
        'feature': feature,
        'input_tokens': inputTokens,
        'output_tokens': outputTokens,
        'total_tokens': totalTokens,
        'model': model,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (error, stackTrace) {
      // Ne pas faire échouer l'opération principale si le log rate — mais un
      // enregistrement de consommation perdu fausse le suivi des coûts IA :
      // l'échec doit être remonté.
      reportUnexpectedError(
        feature: 'tokenUsage.record',
        error: error,
        stackTrace: stackTrace,
        userId: uid,
        context: {
          'featureLoggee': feature,
          'model': model,
          'totalTokens': totalTokens,
        },
      );
    }
  }

  /// Stream des enregistrements d'un utilisateur (pour vue utilisateur).
  Stream<List<TokenUsageRecord>> watchByUser(String uid) {
    return _firestore
        .collection(_collection)
        .where('uid', isEqualTo: uid)
        .orderBy('timestamp', descending: true)
        .limit(500)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => TokenUsageRecord.fromFirestore(d.data()))
              .toList(),
        );
  }

  /// Stream de tous les enregistrements (admin uniquement).
  Stream<List<TokenUsageRecord>> watchAll() {
    return _firestore
        .collection(_collection)
        .orderBy('timestamp', descending: true)
        .limit(1000)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => TokenUsageRecord.fromFirestore(d.data()))
              .toList(),
        );
  }

  /// Calcule les agrégats, groupés par uid + feature + période, et par
  /// fournisseur si [splitByProvider] est vrai.
  ///
  /// Les deux vues répondent à deux questions différentes : globalisée, « que
  /// consomme ce poste » ; ventilée, « qu'est-ce que chaque moteur y coûte ».
  /// La seconde n'a de sens que depuis qu'il y a deux moteurs — et c'est elle
  /// qui permet de comparer une bascule à ce qu'elle a remplacé.
  static List<TokenUsageSummary> aggregate(
    List<TokenUsageRecord> records, {
    String? filterUid,
    String? filterProvider,
    bool splitByProvider = false,
  }) {
    var filtered = filterUid != null
        ? records.where((r) => r.uid == filterUid)
        : records;
    if (filterProvider != null) {
      filtered = filtered.where((r) => r.provider == filterProvider);
    }
    final map = <String, TokenUsageSummary>{};
    for (final r in filtered) {
      final period =
          '${r.timestamp.year}-${r.timestamp.month.toString().padLeft(2, '0')}';
      final provider = splitByProvider ? r.provider : null;
      final key = '${r.uid}|${r.feature}|$period|${provider ?? '*'}';
      final existing = map[key];
      if (existing == null) {
        map[key] = TokenUsageSummary(
          uid: r.uid,
          feature: r.feature,
          period: period,
          provider: provider,
          totalInputTokens: r.inputTokens,
          totalOutputTokens: r.outputTokens,
          totalTokens: r.totalTokens,
          callCount: 1,
        );
      } else {
        map[key] = TokenUsageSummary(
          uid: r.uid,
          feature: r.feature,
          period: period,
          provider: provider,
          totalInputTokens: existing.totalInputTokens + r.inputTokens,
          totalOutputTokens: existing.totalOutputTokens + r.outputTokens,
          totalTokens: existing.totalTokens + r.totalTokens,
          callCount: existing.callCount + 1,
        );
      }
    }
    final list = map.values.toList();
    // Tri : période décroissante, puis total décroissant
    list.sort((a, b) {
      final pCmp = b.period.compareTo(a.period);
      return pCmp != 0 ? pCmp : b.totalTokens.compareTo(a.totalTokens);
    });
    return list;
  }

  /// Crée le callback de logging à passer à GeminiService.
  static Future<void> Function(String, int, int, int) makeCallback(
    String uid,
    TokenUsageRepository repo, {
    String model = 'gemini-2.5-flash',
  }) {
    return (feature, input, output, total) => repo.logUsage(
      uid: uid,
      feature: feature,
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      model: model,
    );
  }
}
