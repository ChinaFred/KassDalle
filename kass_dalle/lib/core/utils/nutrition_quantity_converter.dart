class NutritionQuantityConverter {
  static const Map<String, double> _weightUnitToGrams = {
    'g': 1,
    'gr': 1,
    'gram': 1,
    'grams': 1,
    'kg': 1000,
    'mg': 0.001,
  };

  static const Map<String, double> _volumeUnitToMl = {
    'ml': 1,
    'millilitre': 1,
    'millilitres': 1,
    'milliliter': 1,
    'milliliters': 1,
    'cl': 10,
    'dl': 100,
    'l': 1000,
    'litre': 1000,
    'litres': 1000,
    'liter': 1000,
    'liters': 1000,
    'cc': 5,
    'cac': 5,
    'cuillere_a_cafe': 5,
    'cuilleres_a_cafe': 5,
    'cuillere_a_the': 5,
    'cuilleres_a_the': 5,
    'teaspoon': 5,
    'teaspoons': 5,
    'tsp': 5,
    'cs': 15,
    'cas': 15,
    'cuillere_a_soupe': 15,
    'cuilleres_a_soupe': 15,
    'tablespoon': 15,
    'tablespoons': 15,
    'tbsp': 15,
    'tasse': 240,
    'tasses': 240,
    'cup': 240,
    'cups': 240,
    'verre': 200,
    'verres': 200,
    'bol': 350,
    'bols': 350,
  };

  static const List<({List<String> matchers, double densityGPerMl})>
      _densityProfiles = [
    (
      matchers: ['miel', 'melasse', 'sirop_d_erable', 'sirop_agave'],
      densityGPerMl: 1.35,
    ),
    (
      matchers: [
        'huile',
        'huile_d_olive',
        'huile_de_tournesol',
        'ghee',
        'beurre_fondu',
      ],
      densityGPerMl: 0.92,
    ),
    (
      matchers: ['farine', 'fecule', 'maizena', 'poudre_d_amande'],
      densityGPerMl: 0.55,
    ),
    (matchers: ['sucre_glace'], densityGPerMl: 0.5),
    (
      matchers: ['sucre', 'cassonade', 'sucre_roux', 'sucre_blanc'],
      densityGPerMl: 0.85,
    ),
    (matchers: ['cacao', 'chocolat_en_poudre'], densityGPerMl: 0.4),
    (matchers: ['sel', 'gros_sel', 'fleur_de_sel'], densityGPerMl: 1.2),
    (
      matchers: [
        'riz',
        'semoule',
        'polenta',
        'quinoa',
        'lentille',
        'pois_chiche',
        'haricot_sec',
      ],
      densityGPerMl: 0.8,
    ),
    (
      matchers: ['creme', 'creme_fraiche', 'yaourt', 'fromage_blanc'],
      densityGPerMl: 1,
    ),
    (
      matchers: ['lait', 'eau', 'bouillon', 'vinaigre', 'vin', 'jus', 'cafe', 'the'],
      densityGPerMl: 1,
    ),
  ];

  static double? toGrams({
    required String ingredientName,
    required String qty,
    required String unit,
  }) {
    final quantity = double.tryParse(qty.replaceAll(',', '.'));
    if (quantity == null || quantity <= 0) return null;
    final normalizedUnit = _normalize(unit);
    if (normalizedUnit.isEmpty) return null;

    final weightFactor = _weightUnitToGrams[normalizedUnit];
    if (weightFactor != null) return quantity * weightFactor;

    final volumeMl = _volumeUnitToMl[normalizedUnit];
    if (volumeMl == null) return null;
    return quantity * volumeMl * _densityForIngredient(ingredientName);
  }

  static double _densityForIngredient(String ingredientName) {
    final normalized = _normalize(ingredientName);
    if (normalized.isEmpty) return 1;
    for (final profile in _densityProfiles) {
      if (profile.matchers.any(normalized.contains)) {
        return profile.densityGPerMl;
      }
    }
    return 1;
  }

  static String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('ë', 'e')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ï', 'i')
        .replaceAll('ô', 'o')
        .replaceAll('ö', 'o')
        .replaceAll('ù', 'u')
        .replaceAll('û', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }
}
