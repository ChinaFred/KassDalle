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
/// Une unité du référentiel : sa conversion, et la façon dont on l'a obtenue.
///
/// La provenance compte autant que le chiffre. Le poids d'une « fine tranche »
/// n'est pas mesuré, il est estimé par l'IA à partir de l'ingrédient auquel
/// l'unité s'applique. Affiché sans le dire, ce chiffre a l'autorité d'une
/// donnée vérifiée ; c'est cette information que l'écran doit pouvoir montrer.
class NutritionUnitInfo {
  final ReferentialUnitOverride override;

  /// `known` (table intégrée), `ai_estimated` (poids deviné), `unknown`.
  final String status;

  /// `builtin` ou `ai_estimation`.
  final String conversionSource;

  const NutritionUnitInfo({
    required this.override,
    required this.status,
    required this.conversionSource,
  });

  bool get isAiEstimated =>
      status == 'ai_estimated' || conversionSource == 'ai_estimation';
}

class NutritionUnitsReference {
  final FirebaseFirestore _firestore;

  NutritionUnitsReference({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  Stream<Map<String, NutritionUnitInfo>> watch() {
    return _firestore.collection('nutrition_units').snapshots().map(toInfos);
  }

  /// Convertit un instantané Firestore en table d'unités indexée par identifiant
  /// normalisé (`c_a_s`, `brin`…).
  static Map<String, NutritionUnitInfo> toInfos(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final result = <String, NutritionUnitInfo>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      result[doc.id] = NutritionUnitInfo(
        override: ReferentialUnitOverride(
          measurementType: data['measurement_type'] as String?,
          gramsPerUnit: (data['grams_per_unit'] as num?)?.toDouble(),
          volumeMlPerUnit: (data['volume_ml_per_unit'] as num?)?.toDouble(),
        ),
        status: data['status'] as String? ?? '',
        conversionSource: data['conversion_source'] as String? ?? '',
      );
    }
    return result;
  }
}

final nutritionUnitsReferenceProvider = Provider<NutritionUnitsReference>((
  ref,
) {
  return NutritionUnitsReference();
});

/// Référentiel d'unités courant, rechargé à chaque modification.
///
/// Volontairement sans `autoDispose` : la collection est petite et lue par
/// plusieurs écrans ; on la garde en mémoire pour la durée de la session.
final nutritionUnitsProvider = StreamProvider<Map<String, NutritionUnitInfo>>((
  ref,
) {
  return ref.watch(nutritionUnitsReferenceProvider).watch();
});

/// Référentiel d'unités avec sa provenance, vide tant qu'il n'est pas chargé.
final nutritionUnitInfosProvider = Provider<Map<String, NutritionUnitInfo>>((
  ref,
) {
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

/// Table d'unités prête à l'emploi : vide tant que le référentiel n'est pas
/// chargé ou s'il est en erreur — le convertisseur retombe alors sur sa table
/// intégrée, ce qui dégrade la précision sans jamais bloquer l'affichage.
final nutritionUnitOverridesProvider =
    Provider<Map<String, ReferentialUnitOverride>>((ref) {
      final infos = ref.watch(nutritionUnitInfosProvider);
      return {
        for (final entry in infos.entries) entry.key: entry.value.override,
      };
    });

/// Vrai si le poids de cette unité vient d'une estimation IA, pas d'une mesure.
bool isUnitWeightEstimated({
  required Map<String, NutritionUnitInfo> infos,
  required String unit,
}) {
  final normalized = NutritionQuantityConverter.normalizeObservedUnit(unit);
  if (normalized.isEmpty) return false;
  return infos[normalized]?.isAiEstimated ?? false;
}

/// Poids en grammes d'un ingrédient, référentiel appliqué quand il est chargé.
///
/// Point d'entrée unique côté client : passer par ici garantit que l'affichage
/// utilise la même règle de conversion que le calcul serveur.
double? resolveIngredientWeightGrams({
  required Map<String, ReferentialUnitOverride> overrides,
  required String ingredientName,
  required String qty,
  required String unit,
  IngredientWeightOverride? ingredientOverride,
}) {
  // L'unité qui sert à chercher la surcharge est l'unité EFFECTIVE, pas celle
  // écrite dans la recette : « poivre » tout court se pèse à la pincée, et un
  // administrateur qui corrige le poids d'une pincée doit corriger ce cas-là
  // aussi.
  final weighing = NutritionQuantityConverter.resolveWeighingInput(
    ingredientName: ingredientName,
    qty: qty,
    unit: unit,
    usualPortionGrams: ingredientOverride?.usualPortionGrams,
  );
  if (weighing == null) return null;
  final normalized = NutritionQuantityConverter.normalizeObservedUnit(
    weighing.unit,
  );
  return NutritionQuantityConverter.toGrams(
    ingredientName: ingredientName,
    qty: qty,
    unit: unit,
    override: normalized.isEmpty ? null : overrides[normalized],
    ingredientOverride: ingredientOverride,
  );
}
