import 'package:cloud_firestore/cloud_firestore.dart';

class NutritionIngredientDoc {
  final String id;
  final String source;

  /// `estimated_ai`, `estimation_failed`, `verified`, `pending`…
  final String qualityStatus;
  final Map<String, double> per100g;

  const NutritionIngredientDoc({
    required this.id,
    required this.source,
    required this.qualityStatus,
    required this.per100g,
  });

  /// Vrai quand les valeurs viennent d'une estimation IA plutôt que d'une
  /// source vérifiée.
  ///
  /// L'estimation est délibérée : sans elle, l'ingrédient sortirait du calcul
  /// nutritionnel sans laisser de trace. Elle doit en revanche s'annoncer — un
  /// chiffre estimé affiché comme un chiffre mesuré est un mensonge par
  /// omission.
  bool get isAiEstimated =>
      qualityStatus == 'estimated_ai' ||
      source == 'gemini_estimated' ||
      source == 'ai_estimation';

  factory NutritionIngredientDoc.fromFirestore(
    String id,
    Map<String, dynamic> data,
  ) {
    final rawPer100g = data['per100g'];
    final per100g = <String, double>{};
    if (rawPer100g is Map) {
      rawPer100g.forEach((key, value) {
        if (key is String && value is num) {
          per100g[key] = value.toDouble();
        }
      });
    }

    return NutritionIngredientDoc(
      id: id,
      source: data['source'] as String? ?? '',
      qualityStatus: data['quality_status'] as String? ?? '',
      per100g: per100g,
    );
  }
}

class NutritionIngredientsRepository {
  final FirebaseFirestore _firestore;

  NutritionIngredientsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  Stream<List<NutritionIngredientDoc>> watchAll({int limit = 1000}) {
    final size = limit < 1 ? 1 : (limit > 3000 ? 3000 : limit);
    return _firestore
        .collection('nutrition_ingredients')
        .orderBy(FieldPath.documentId)
        .limit(size)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => NutritionIngredientDoc.fromFirestore(d.id, d.data()))
              .toList(growable: false),
        );
  }
}
