import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/ai_reconciliation_report.dart';

/// Lecture des rapports de réconciliation des coûts IA.
///
/// L'écriture appartient au backend — la tâche planifiée mensuelle et le
/// déclenchement manuel passent tous deux par `runAiReconciliation` côté
/// Functions, et les règles Firestore interdisent l'écriture au client.
class AiReconciliationRepository {
  final FirebaseFirestore _firestore;

  AiReconciliationRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('ai_reconciliation_monthly');

  /// Identifiant de période (`YYYY-MM`) pour une date donnée.
  static String periodId(DateTime date) {
    final utc = date.toUtc();
    return '${utc.year}-${utc.month.toString().padLeft(2, '0')}';
  }

  /// Rapport d'une période, `null` s'il n'a pas encore été produit.
  Stream<AiReconciliationReport?> watch(String period) {
    return _col.doc(period).snapshots().map((doc) {
      final data = doc.data();
      if (data == null) return null;
      return AiReconciliationReport.fromMap(doc.id, data);
    });
  }

  /// Les [limit] rapports les plus récents, du plus récent au plus ancien.
  ///
  /// L'identifiant de document étant `YYYY-MM`, l'ordre lexicographique est
  /// l'ordre chronologique : pas besoin d'index sur un champ de date.
  Future<List<AiReconciliationReport>> recent({int limit = 12}) async {
    final snap = await _col
        .orderBy(FieldPath.documentId, descending: true)
        .limit(limit)
        .get();
    return snap.docs
        .map((d) => AiReconciliationReport.fromMap(d.id, d.data()))
        .toList(growable: false);
  }
}
