/// Politique de calcul nutritionnel — `app_config/nutrition_source_policy`.
///
/// Ces seuils décident de ce que l'utilisateur voit sur l'onglet Nutrition
/// d'une recette : au-dessous de [minCoverageForPer100g], les valeurs pour
/// 100 g sont masquées ; au-dessous de [minCoverageForPartial], un
/// avertissement remplace le détail ; et [kcalConsistencyWarnDeltaPct] déclenche
/// l'alerte d'incohérence entre calories annoncées et calories recalculées
/// depuis les macronutriments. Tous trois entrent aussi dans le score A/B/C.
///
/// Le document n'existe pas tant que personne ne l'a écrit : le backend
/// retombe alors sur ces mêmes valeurs par défaut.
class NutritionPolicy {
  /// Couverture minimale pour afficher un calcul partiel (0 à 1).
  final double minCoverageForPartial;

  /// Couverture minimale pour afficher les valeurs pour 100 g (0 à 1).
  /// Toujours supérieure ou égale à [minCoverageForPartial].
  final double minCoverageForPer100g;

  /// Écart toléré entre kcal annoncées et kcal recalculées (0 à 1).
  final double kcalConsistencyWarnDeltaPct;

  /// Comportement quand aucune donnée nutritionnelle n'est trouvée.
  final String fallbackPolicy;

  /// Ordre de confiance des sources, du plus fiable au moins fiable.
  /// Lecture seule dans l'écran d'administration : le modifier demande de
  /// comprendre la chaîne d'enrichissement, pas de bouger un curseur.
  final List<String> sourcePriority;

  final int version;

  const NutritionPolicy({
    required this.minCoverageForPartial,
    required this.minCoverageForPer100g,
    required this.kcalConsistencyWarnDeltaPct,
    required this.fallbackPolicy,
    required this.sourcePriority,
    required this.version,
  });

  /// Valeurs par défaut du backend (`DEFAULT_NUTRITION_POLICY`).
  static const defaults = NutritionPolicy(
    minCoverageForPartial: 0.7,
    minCoverageForPer100g: 0.9,
    kcalConsistencyWarnDeltaPct: 0.15,
    fallbackPolicy: 'strict',
    sourcePriority: [
      'user_validated',
      'internal_reference',
      'external_reference',
      'ai_estimated',
    ],
    version: 1,
  );

  static double _ratio(Object? value, double fallback) {
    if (value is num) {
      final d = value.toDouble();
      if (d.isFinite && d >= 0 && d <= 1) return d;
    }
    return fallback;
  }

  factory NutritionPolicy.fromMap(Map<String, dynamic> data) {
    final quality = data['quality_policy'];
    final qualityMap = quality is Map
        ? Map<String, dynamic>.from(quality)
        : const <String, dynamic>{};

    final priorityRaw = data['source_priority'];
    final priority = <String>[];
    if (priorityRaw is List) {
      final entries = priorityRaw.whereType<Map>().toList()
        ..sort((a, b) {
          final ra = (a['rank'] as num?)?.toInt() ?? 999;
          final rb = (b['rank'] as num?)?.toInt() ?? 999;
          return ra.compareTo(rb);
        });
      for (final e in entries) {
        final source = e['source'];
        if (source is String && e['enabled'] != false) priority.add(source);
      }
    }

    return NutritionPolicy(
      minCoverageForPartial: _ratio(
        qualityMap['minCoverageForPartial'],
        defaults.minCoverageForPartial,
      ),
      minCoverageForPer100g: _ratio(
        qualityMap['minCoverageForPer100g'],
        defaults.minCoverageForPer100g,
      ),
      kcalConsistencyWarnDeltaPct: _ratio(
        qualityMap['kcalConsistencyWarnDeltaPct'],
        defaults.kcalConsistencyWarnDeltaPct,
      ),
      fallbackPolicy: data['fallback_policy'] as String? ?? defaults.fallbackPolicy,
      sourcePriority: priority.isEmpty ? defaults.sourcePriority : priority,
      version: (data['version'] as num?)?.toInt() ?? defaults.version,
    );
  }

  /// Charge utile envoyée à `setNutritionSourcePolicyFn`.
  ///
  /// N'envoie que ce que l'écran permet de régler. Le backend refuse les
  /// valeurs hors bornes et complète le reste depuis ses propres défauts —
  /// `source_priority` et `nutrient_aliases` ne sont donc pas réécrits ici.
  Map<String, dynamic> toPayload() => {
    'fallback_policy': fallbackPolicy,
    'quality_policy': {
      'minCoverageForPartial': minCoverageForPartial,
      'minCoverageForPer100g': minCoverageForPer100g,
      'kcalConsistencyWarnDeltaPct': kcalConsistencyWarnDeltaPct,
    },
  };

  NutritionPolicy copyWith({
    double? minCoverageForPartial,
    double? minCoverageForPer100g,
    double? kcalConsistencyWarnDeltaPct,
    String? fallbackPolicy,
  }) {
    return NutritionPolicy(
      minCoverageForPartial: minCoverageForPartial ?? this.minCoverageForPartial,
      minCoverageForPer100g: minCoverageForPer100g ?? this.minCoverageForPer100g,
      kcalConsistencyWarnDeltaPct:
          kcalConsistencyWarnDeltaPct ?? this.kcalConsistencyWarnDeltaPct,
      fallbackPolicy: fallbackPolicy ?? this.fallbackPolicy,
      sourcePriority: sourcePriority,
      version: version,
    );
  }

  /// Vrai si l'invariant du backend est respecté : afficher le « pour 100 g »
  /// ne peut pas être moins exigeant que présenter un calcul partiel.
  bool get isConsistent => minCoverageForPer100g >= minCoverageForPartial;

  bool sameSettingsAs(NutritionPolicy other) =>
      minCoverageForPartial == other.minCoverageForPartial &&
      minCoverageForPer100g == other.minCoverageForPer100g &&
      kcalConsistencyWarnDeltaPct == other.kcalConsistencyWarnDeltaPct &&
      fallbackPolicy == other.fallbackPolicy;
}
