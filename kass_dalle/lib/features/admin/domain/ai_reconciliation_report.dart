/// Rapport de réconciliation des coûts IA pour un mois — `ai_reconciliation_monthly/{period}`.
///
/// Confronte ce que le suivi interne a estimé, appel Gemini par appel Gemini, à
/// ce que Google a réellement facturé. C'est la seule chose qui empêche le
/// reporting de coûts de mentir sans qu'on s'en aperçoive : une erreur de
/// tarification produit un chiffre plausible, jamais une erreur.
class AiReconciliationReport {
  /// Mois au format `YYYY-MM`.
  final String period;

  /// Somme des coûts estimés par le suivi interne (collection `ai_usage`).
  final double estimatedTraceableUsd;

  /// Coût réellement facturé par Google sur la période (export BigQuery),
  /// ramené en dollars par le taux de change de l'export — c'est la seule
  /// forme comparable à [estimatedTraceableUsd], que la grille tarifaire
  /// Gemini exprime en dollars.
  final double billedIaUsd;

  /// Le même montant tel qu'il figure sur la facture Google, dans
  /// [billingCurrency]. C'est ce chiffre-là, et lui seul, qu'on retrouve dans
  /// le Tableau des coûts de la console.
  final double billedIaNative;

  /// Devise du compte de facturation (`EUR` pour ce projet). `null` pour les
  /// rapports produits avant la prise en compte de la devise : leur montant
  /// « facturé » est en réalité libellé dans la devise du compte tout en étant
  /// nommé USD, et leur écart mélange donc deux monnaies. Le distinguer permet
  /// à l'écran de le dire au lieu d'afficher un chiffre faux.
  final String? billingCurrency;

  /// `billedIaUsd - estimatedTraceableUsd`. Positif = on facture plus que ce
  /// qu'on trace.
  final double deltaUsd;

  /// Part facturée que le suivi n'explique pas (l'écart, borné à zéro).
  final double unattributedUsd;

  /// Vrai si l'export de facturation n'a pas pu être lu. [billedIaUsd] et
  /// [deltaUsd] ne veulent alors rien dire — un rapport qui l'ignore affirme
  /// que Google n'a rien facturé.
  final bool billingQueryFailed;

  /// Coût estimé ventilé par fonctionnalité.
  final Map<String, double> byFeature;

  /// Anomalies détectées, en français, prêtes à afficher.
  final List<String> anomalies;

  final DateTime? generatedAt;

  /// UID de l'admin qui a lancé le rapport, `null` si c'est la planification.
  final String? generatedBy;

  /// `scheduler` ou `manual`.
  final String generatedSource;

  const AiReconciliationReport({
    required this.period,
    required this.estimatedTraceableUsd,
    required this.billedIaUsd,
    required this.billedIaNative,
    required this.billingCurrency,
    required this.deltaUsd,
    required this.unattributedUsd,
    required this.billingQueryFailed,
    required this.byFeature,
    required this.anomalies,
    required this.generatedAt,
    required this.generatedBy,
    required this.generatedSource,
  });

  /// Vrai si l'écart mérite qu'on s'y arrête.
  bool get hasAnomaly => anomalies.isNotEmpty;

  /// Vrai pour un rapport antérieur à la prise en compte de la devise : ses
  /// montants ne sont pas comparables entre eux. Un simple recalcul le corrige.
  bool get currencyUnknown => billingCurrency == null;

  static double _toDouble(Object? value) =>
      value is num ? value.toDouble() : 0.0;

  factory AiReconciliationReport.fromMap(
    String period,
    Map<String, dynamic> data,
  ) {
    final byFeatureRaw = data['by_feature'];
    final byFeature = <String, double>{};
    if (byFeatureRaw is Map) {
      byFeatureRaw.forEach((key, value) {
        if (key is String && value is num) byFeature[key] = value.toDouble();
      });
    }

    final generatedAtRaw = data['generated_at'];

    return AiReconciliationReport(
      period: data['period'] as String? ?? period,
      estimatedTraceableUsd: _toDouble(data['estimated_traceable_usd']),
      billedIaUsd: _toDouble(data['billed_ia_usd']),
      billedIaNative: _toDouble(data['billed_ia_native']),
      billingCurrency: data['billing_currency'] as String?,
      deltaUsd: _toDouble(data['delta_usd']),
      unattributedUsd: _toDouble(data['unattributed_usd']),
      billingQueryFailed: data['billing_query_failed'] == true,
      byFeature: byFeature,
      anomalies: List<String>.from(data['anomalies'] as List? ?? const []),
      generatedAt: generatedAtRaw == null
          ? null
          : (generatedAtRaw as dynamic).toDate() as DateTime,
      generatedBy: data['generated_by'] as String?,
      generatedSource: data['generated_source'] as String? ?? 'manual',
    );
  }
}
