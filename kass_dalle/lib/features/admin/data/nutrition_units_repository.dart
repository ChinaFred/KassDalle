import 'package:cloud_firestore/cloud_firestore.dart';

class NutritionUnitDoc {
  final String id;
  final String normalizedUnit;
  final String displayLabel;
  final List<String> aliases;
  final String measurementType;
  final double? gramsPerUnit;
  final double? volumeMlPerUnit;
  final String status;
  final String source;
  final int seenCount;

  const NutritionUnitDoc({
    required this.id,
    required this.normalizedUnit,
    required this.displayLabel,
    required this.aliases,
    required this.measurementType,
    required this.gramsPerUnit,
    required this.volumeMlPerUnit,
    required this.status,
    required this.source,
    required this.seenCount,
  });

  factory NutritionUnitDoc.fromFirestore(String id, Map<String, dynamic> data) {
    return NutritionUnitDoc(
      id: id,
      normalizedUnit: data['normalized_unit'] as String? ?? id,
      displayLabel: data['display_label'] as String? ?? '',
      aliases: List<String>.from(data['aliases'] as List? ?? const []),
      measurementType: data['measurement_type'] as String? ?? 'unknown',
      gramsPerUnit: (data['grams_per_unit'] as num?)?.toDouble(),
      volumeMlPerUnit: (data['volume_ml_per_unit'] as num?)?.toDouble(),
      status: data['status'] as String? ?? 'pending_review',
      source: data['source'] as String? ?? 'fallback_auto',
      seenCount: (data['seen_count'] as num?)?.round() ?? 0,
    );
  }
}

class NutritionUnitUpsertInput {
  final String normalizedUnit;
  final String displayLabel;
  final List<String> aliases;
  final String measurementType;
  final double? gramsPerUnit;
  final double? volumeMlPerUnit;
  final String status;
  final String source;

  const NutritionUnitUpsertInput({
    required this.normalizedUnit,
    required this.displayLabel,
    required this.aliases,
    required this.measurementType,
    required this.gramsPerUnit,
    required this.volumeMlPerUnit,
    required this.status,
    required this.source,
  });
}

class NutritionUnitsRepository {
  final FirebaseFirestore _firestore;

  NutritionUnitsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('nutrition_units');

  Stream<List<NutritionUnitDoc>> watchAll({int limit = 1000}) {
    final size = limit < 1 ? 1 : (limit > 4000 ? 4000 : limit);
    return _col
        .orderBy(FieldPath.documentId)
        .limit(size)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => NutritionUnitDoc.fromFirestore(d.id, d.data()))
              .toList(growable: false),
        );
  }

  Future<void> create(NutritionUnitUpsertInput input) async {
    final now = FieldValue.serverTimestamp();
    await _col.doc(input.normalizedUnit).set({
      'normalized_unit': input.normalizedUnit,
      'display_label': input.displayLabel,
      'aliases': input.aliases,
      'measurement_type': input.measurementType,
      'grams_per_unit': input.gramsPerUnit,
      'volume_ml_per_unit': input.volumeMlPerUnit,
      'status': input.status,
      'source': input.source,
      'seen_count': 0,
      'first_seen_at': now,
      'last_seen_at': now,
      'updated_at': now,
      'created_at': now,
    });
  }

  Future<void> update(String docId, NutritionUnitUpsertInput input) async {
    await _col.doc(docId).update({
      'display_label': input.displayLabel,
      'aliases': input.aliases,
      'measurement_type': input.measurementType,
      'grams_per_unit': input.gramsPerUnit,
      'volume_ml_per_unit': input.volumeMlPerUnit,
      'status': input.status,
      'source': input.source,
      'updated_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> delete(String docId) async {
    await _col.doc(docId).delete();
  }

  // Le semis des unités standard (`seedDefaultUnits`) a quitté le client le
  // 21/10/2026, en v0.24.40 : il écrivait en masse dans `nutrition_units`
  // depuis l'application. Il est passé dans Admin › Backfills (« Semer les
  // unités standard », `backfillDefaultUnitsFn`), retiré le 22/10/2026 en
  // v0.24.52 une fois les unités semées en production.
}
