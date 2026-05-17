import 'package:cloud_firestore/cloud_firestore.dart';

/// Enregistrement d'un appel Gemini.
class TokenUsageRecord {
  final String uid;
  final String feature;
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final String model;
  final DateTime timestamp;

  const TokenUsageRecord({
    required this.uid,
    required this.feature,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.model,
    required this.timestamp,
  });

  factory TokenUsageRecord.fromFirestore(Map<String, dynamic> data) {
    return TokenUsageRecord(
      uid: data['uid'] as String? ?? '',
      feature: data['feature'] as String? ?? '',
      inputTokens: data['input_tokens'] as int? ?? 0,
      outputTokens: data['output_tokens'] as int? ?? 0,
      totalTokens: data['total_tokens'] as int? ?? 0,
      model: data['model'] as String? ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}

/// Agrégation des tokens par utilisateur et par feature.
class TokenUsageSummary {
  final String uid;
  final String feature;
  final int totalInputTokens;
  final int totalOutputTokens;
  final int totalTokens;
  final int callCount;

  const TokenUsageSummary({
    required this.uid,
    required this.feature,
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
    } catch (_) {
      // Ne pas faire échouer l'opération principale si le log rate
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

  /// Calcule les agrégats depuis une liste d'enregistrements.
  static List<TokenUsageSummary> aggregate(
    List<TokenUsageRecord> records, {
    String? filterUid,
  }) {
    final filtered =
        filterUid != null ? records.where((r) => r.uid == filterUid) : records;
    final map = <String, TokenUsageSummary>{};
    for (final r in filtered) {
      final key = '${r.uid}|${r.feature}';
      final existing = map[key];
      if (existing == null) {
        map[key] = TokenUsageSummary(
          uid: r.uid,
          feature: r.feature,
          totalInputTokens: r.inputTokens,
          totalOutputTokens: r.outputTokens,
          totalTokens: r.totalTokens,
          callCount: 1,
        );
      } else {
        map[key] = TokenUsageSummary(
          uid: r.uid,
          feature: r.feature,
          totalInputTokens: existing.totalInputTokens + r.inputTokens,
          totalOutputTokens: existing.totalOutputTokens + r.outputTokens,
          totalTokens: existing.totalTokens + r.totalTokens,
          callCount: existing.callCount + 1,
        );
      }
    }
    final list = map.values.toList();
    list.sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
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
