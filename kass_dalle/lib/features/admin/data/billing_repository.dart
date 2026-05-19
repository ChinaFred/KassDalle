import 'package:cloud_firestore/cloud_firestore.dart';

import 'gemini_pricing.dart';
import 'token_usage_repository.dart';

/// Période de facturation (bornes inclusives / exclusives ISO).
class BillingPeriod {
  final String id;
  final String label;
  final DateTime start; // inclusive
  final DateTime end; // exclusive

  const BillingPeriod({
    required this.id,
    required this.label,
    required this.start,
    required this.end,
  });

  /// Construit la liste des périodes proposées dans l'UI.
  static List<BillingPeriod> buildPresets({DateTime? now}) {
    final ref = now ?? DateTime.now();
    final currentStart = DateTime(ref.year, ref.month, 1);
    final nextMonth = DateTime(ref.year, ref.month + 1, 1);
    final prevStart = DateTime(ref.year, ref.month - 1, 1);
    final start3 = DateTime(ref.year, ref.month - 2, 1);
    final start12 = DateTime(ref.year, ref.month - 11, 1);

    String monthName(DateTime d) {
      const m = [
        'janvier', 'février', 'mars', 'avril', 'mai', 'juin',
        'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre',
      ];
      return '${m[d.month - 1]} ${d.year}';
    }

    return [
      BillingPeriod(
        id: 'current',
        label: 'Mois en cours (${monthName(currentStart)})',
        start: currentStart,
        end: nextMonth,
      ),
      BillingPeriod(
        id: 'previous',
        label: 'Mois précédent (${monthName(prevStart)})',
        start: prevStart,
        end: currentStart,
      ),
      BillingPeriod(
        id: 'last3',
        label: '3 derniers mois',
        start: start3,
        end: nextMonth,
      ),
      BillingPeriod(
        id: 'last12',
        label: '12 derniers mois',
        start: start12,
        end: nextMonth,
      ),
      BillingPeriod(
        id: 'all',
        label: 'Tout l\'historique',
        start: DateTime(2020, 1, 1),
        end: nextMonth,
      ),
    ];
  }
}

/// Une ligne du tableau de facturation Gemini : (uid, feature, model).
class BillingRow {
  final String uid;
  final String feature;
  final String model;
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final int callCount;
  final double costUsd;
  final double costEur;

  const BillingRow({
    required this.uid,
    required this.feature,
    required this.model,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.callCount,
    required this.costUsd,
    required this.costEur,
  });
}

/// Totaux agrégés pour la période sélectionnée.
class BillingTotals {
  final int inputTokens;
  final int outputTokens;
  final int totalTokens;
  final int callCount;
  final double costUsd;
  final double costEur;
  final int userCount;

  const BillingTotals({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.callCount,
    required this.costUsd,
    required this.costEur,
    required this.userCount,
  });

  static const empty = BillingTotals(
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: 0,
    callCount: 0,
    costUsd: 0,
    costEur: 0,
    userCount: 0,
  );
}

/// Résultat complet pour une période donnée : lignes détaillées + totaux.
class BillingReport {
  final BillingPeriod period;
  final List<BillingRow> rows;
  final BillingTotals totals;

  const BillingReport({
    required this.period,
    required this.rows,
    required this.totals,
  });
}

class BillingRepository {
  final FirebaseFirestore _firestore;

  BillingRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Requête `ai_usage` sur la période et agrège par (uid, feature, model).
  Future<BillingReport> fetchReport(BillingPeriod period) async {
    final snap = await _firestore
        .collection('ai_usage')
        .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(period.start))
        .where('timestamp', isLessThan: Timestamp.fromDate(period.end))
        .get();

    final records = snap.docs
        .map((d) => TokenUsageRecord.fromFirestore(d.data()))
        .toList();

    final byKey = <String, _AggBucket>{};
    final users = <String>{};

    for (final r in records) {
      users.add(r.uid);
      final model = r.model.isEmpty ? 'unknown' : r.model;
      final key = '${r.uid}|${r.feature}|$model';
      final bucket = byKey.putIfAbsent(
        key,
        () => _AggBucket(uid: r.uid, feature: r.feature, model: model),
      );
      bucket.inputTokens += r.inputTokens;
      bucket.outputTokens += r.outputTokens;
      bucket.totalTokens += r.totalTokens;
      bucket.callCount += 1;
    }

    final rows = byKey.values.map((b) {
      final usd = GeminiPricing.costUsd(
        model: b.model,
        inputTokens: b.inputTokens,
        outputTokens: b.outputTokens,
      );
      return BillingRow(
        uid: b.uid,
        feature: b.feature,
        model: b.model,
        inputTokens: b.inputTokens,
        outputTokens: b.outputTokens,
        totalTokens: b.totalTokens,
        callCount: b.callCount,
        costUsd: usd,
        costEur: usd * GeminiPricing.usdToEur,
      );
    }).toList()
      ..sort((a, b) => b.costUsd.compareTo(a.costUsd));

    final totals = rows.fold<_AggBucket>(
      _AggBucket(uid: '', feature: '', model: ''),
      (acc, r) {
        acc.inputTokens += r.inputTokens;
        acc.outputTokens += r.outputTokens;
        acc.totalTokens += r.totalTokens;
        acc.callCount += r.callCount;
        return acc;
      },
    );
    final totalUsd = rows.fold<double>(0, (s, r) => s + r.costUsd);

    return BillingReport(
      period: period,
      rows: rows,
      totals: BillingTotals(
        inputTokens: totals.inputTokens,
        outputTokens: totals.outputTokens,
        totalTokens: totals.totalTokens,
        callCount: totals.callCount,
        costUsd: totalUsd,
        costEur: totalUsd * GeminiPricing.usdToEur,
        userCount: users.length,
      ),
    );
  }
}

class _AggBucket {
  final String uid;
  final String feature;
  final String model;
  int inputTokens = 0;
  int outputTokens = 0;
  int totalTokens = 0;
  int callCount = 0;

  _AggBucket({required this.uid, required this.feature, required this.model});
}
