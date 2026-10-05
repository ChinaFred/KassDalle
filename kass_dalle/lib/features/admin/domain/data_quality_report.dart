/// Rapport du dashboard de qualité des données (Admin → Monitoring).
///
/// Diagnostic en lecture seule, rendu par `getDataQualityReportFn` : quatre
/// anomalies détectées sur les référentiels nutrition. Aucune écriture — à la
/// différence d'un backfill, ce rapport ne corrige rien, il montre.
library;

/// Un élément concret derrière une anomalie — un ingrédient, une unité.
class DataQualityExample {
  final String id;
  final String label;
  final String detail;

  const DataQualityExample({
    required this.id,
    required this.label,
    required this.detail,
  });

  factory DataQualityExample.fromMap(Map<String, dynamic> map) {
    return DataQualityExample(
      id: map['id'] as String? ?? '',
      label: map['label'] as String? ?? '',
      detail: map['detail'] as String? ?? '',
    );
  }
}

/// Une catégorie d'anomalie : un total exhaustif, un échantillon affichable.
///
/// Le total compte TOUS les documents rencontrés pendant le scan ; seul
/// l'échantillon (`examples`) est plafonné. Un compte qui serait, lui aussi,
/// tronqué ferait croire à une amélioration qui n'a pas eu lieu — c'est
/// exactement le défaut déjà rencontré sur le référentiel nutrition.
class DataQualityCheck {
  final int count;
  final List<DataQualityExample> examples;
  final bool truncatedExamples;

  const DataQualityCheck({
    required this.count,
    required this.examples,
    required this.truncatedExamples,
  });

  static const empty = DataQualityCheck(
    count: 0,
    examples: [],
    truncatedExamples: false,
  );

  factory DataQualityCheck.fromMap(Map<String, dynamic>? map) {
    if (map == null) return empty;
    final rawExamples = map['examples'] as List? ?? const [];
    return DataQualityCheck(
      count: (map['count'] as num?)?.toInt() ?? 0,
      examples: rawExamples
          .map(
            (e) =>
                DataQualityExample.fromMap(Map<String, dynamic>.from(e as Map)),
          )
          .toList(growable: false),
      truncatedExamples: map['truncatedExamples'] == true,
    );
  }
}

class DataQualityReport {
  /// Faux si le scan a été interrompu par le délai de sécurité côté serveur :
  /// les comptes sont alors des minimums, pas des totaux, et l'écran le dit.
  final bool scanComplete;
  final DataQualityCheck missingShoppingProduct;
  final DataQualityCheck incompleteNutrition;
  final DataQualityCheck implausibleSalt;
  final DataQualityCheck unconfirmedUnits;

  const DataQualityReport({
    required this.scanComplete,
    required this.missingShoppingProduct,
    required this.incompleteNutrition,
    required this.implausibleSalt,
    required this.unconfirmedUnits,
  });

  factory DataQualityReport.fromMap(Map<String, dynamic> map) {
    return DataQualityReport(
      scanComplete: map['scanComplete'] == true,
      missingShoppingProduct: DataQualityCheck.fromMap(
        map['missingShoppingProduct'] as Map<String, dynamic>?,
      ),
      incompleteNutrition: DataQualityCheck.fromMap(
        map['incompleteNutrition'] as Map<String, dynamic>?,
      ),
      implausibleSalt: DataQualityCheck.fromMap(
        map['implausibleSalt'] as Map<String, dynamic>?,
      ),
      unconfirmedUnits: DataQualityCheck.fromMap(
        map['unconfirmedUnits'] as Map<String, dynamic>?,
      ),
    );
  }
}
