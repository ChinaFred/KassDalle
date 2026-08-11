import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/nutrition_quantity_converter.dart';
import 'error_reporting.dart';

/// Accès en lecture au référentiel d'unités `nutrition_units`.
///
/// Ce référentiel est **la** source de vérité des conversions d'unités, partagée
/// avec le backend. La table intégrée à [NutritionQuantityConverter] n'est qu'un
/// repli d'amorçage : elle sert au tout premier lancement, et si Firestore est
/// injoignable sans cache local.
///
/// La lecture passe par un flux `snapshots()` : le référentiel est chargé une
/// fois, mis à jour automatiquement à chaque modification faite depuis l'écran
/// d'administration, et conservé hors ligne par le cache du SDK Firestore.
class NutritionUnitsReference {
  final FirebaseFirestore _firestore;

  NutritionUnitsReference({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  Stream<Map<String, ReferentialUnitOverride>> watch() {
    return _firestore
        .collection('nutrition_units')
        .snapshots()
        .map(toOverrides);
  }

  /// Convertit un instantané Firestore en table d'unités indexée par identifiant
  /// normalisé (`c_a_s`, `brin`…).
  static Map<String, ReferentialUnitOverride> toOverrides(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final result = <String, ReferentialUnitOverride>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      result[doc.id] = ReferentialUnitOverride(
        measurementType: data['measurement_type'] as String?,
        gramsPerUnit: (data['grams_per_unit'] as num?)?.toDouble(),
        volumeMlPerUnit: (data['volume_ml_per_unit'] as num?)?.toDouble(),
      );
    }
    return result;
  }
}

final nutritionUnitsReferenceProvider = Provider<NutritionUnitsReference>((ref) {
  return NutritionUnitsReference();
});

/// Référentiel d'unités courant, rechargé à chaque modification.
///
/// Volontairement sans `autoDispose` : la collection est petite et lue par
/// plusieurs écrans ; on la garde en mémoire pour la durée de la session.
final nutritionUnitsProvider =
    StreamProvider<Map<String, ReferentialUnitOverride>>((ref) {
      return ref.watch(nutritionUnitsReferenceProvider).watch();
    });

/// Table d'unités prête à l'emploi : vide tant que le référentiel n'est pas
/// chargé ou s'il est en erreur — le convertisseur retombe alors sur sa table
/// intégrée, ce qui dégrade la précision sans jamais bloquer l'affichage.
final nutritionUnitOverridesProvider =
    Provider<Map<String, ReferentialUnitOverride>>((ref) {
      final async = ref.watch(nutritionUnitsProvider);
      return async.when(
        data: (units) => units,
        loading: () => const {},
        error: (error, stackTrace) {
          reportUnexpectedError(
            feature: 'nutritionUnitsReference.watch',
            error: error,
            stackTrace: stackTrace,
          );
          return const {};
        },
      );
    });

/// Poids en grammes d'un ingrédient, référentiel appliqué quand il est chargé.
///
/// Point d'entrée unique côté client : passer par ici garantit que l'affichage
/// utilise la même règle de conversion que le calcul serveur.
double? resolveIngredientWeightGrams({
  required Map<String, ReferentialUnitOverride> overrides,
  required String ingredientName,
  required String qty,
  required String unit,
}) {
  final normalized = NutritionQuantityConverter.normalizeObservedUnit(unit);
  return NutritionQuantityConverter.toGrams(
    ingredientName: ingredientName,
    qty: qty,
    unit: unit,
    override: normalized.isEmpty ? null : overrides[normalized],
  );
}
