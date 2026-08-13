import 'ingredient_name.dart';

/// Nature d'une unité de mesure.
enum UnitMeasurementType { weight, volume, count }

/// Métadonnées d'une unité connue de la table intégrée.
class KnownUnit {
  final String normalizedUnit;
  final UnitMeasurementType measurementType;

  /// Poids d'une unité, densité de l'ingrédient déjà appliquée pour un volume.
  final double gramsPerUnit;

  /// Volume d'une unité en millilitres — seulement pour un volume.
  final double? mlPerUnit;

  const KnownUnit({
    required this.normalizedUnit,
    required this.measurementType,
    required this.gramsPerUnit,
    this.mlPerUnit,
  });
}

/// Valeurs issues d'un document du référentiel Firestore `nutrition_units`.
///
/// Le référentiel est la source de vérité modifiable sans redéploiement ; la
/// table intégrée du convertisseur n'est qu'un repli d'amorçage, utilisé au
/// premier lancement et hors ligne.
class ReferentialUnitOverride {
  final String? measurementType;
  final double? gramsPerUnit;
  final double? volumeMlPerUnit;

  const ReferentialUnitOverride({
    this.measurementType,
    this.gramsPerUnit,
    this.volumeMlPerUnit,
  });
}

/// Conversion d'une quantité culinaire en grammes.
///
/// Jumeau Dart de `functions/src/nutrition/quantityConversion.ts`. Les deux
/// implémentations sont vérifiées par les mêmes cas dans
/// `test-fixtures/unit_to_grams.json` : toute unité ajoutée d'un côté doit
/// l'être de l'autre, sinon la CI le signale.
class NutritionQuantityConverter {
  static const Set<String> _countUnits = {
    'piece',
    'pieces',
    'unite',
    'unites',
    'pc',
    'pcs',
  };

  /// Formes rencontrées dans les recettes → unité canonique.
  /// Miroir de `CANONICAL_UNIT_ALIASES` côté TypeScript.
  static const Map<String, String> _canonicalUnitAliases = {
    // Cuillère à café
    'cac': 'c_a_c',
    'c_a_c': 'c_a_c',
    'c_c': 'c_a_c',
    'cc': 'c_a_c',
    'c_a_cafe': 'c_a_c',
    'cuillere_cafe': 'c_a_c',
    'cuilleres_cafe': 'c_a_c',
    'cuillere_a_cafe': 'c_a_c',
    'cuilleres_a_cafe': 'c_a_c',
    // « cuillerée » (le contenu de la cuillère) est aussi courant que
    // « cuillère » (l'ustensile) dans les recettes, et « cuiller » reste une
    // orthographe valide. Sans ces graphies, l'unité était déclarée inconnue et
    // l'ingrédient sortait du calcul nutritionnel.
    'cuilleree_cafe': 'c_a_c',
    'cuillerees_cafe': 'c_a_c',
    'cuilleree_a_cafe': 'c_a_c',
    'cuillerees_a_cafe': 'c_a_c',
    'cuiller_a_cafe': 'c_a_c',
    'cuillers_a_cafe': 'c_a_c',
    'cuil_a_cafe': 'c_a_c',
    'cuil_cafe': 'c_a_c',
    'teaspoon': 'c_a_c',
    'teaspoons': 'c_a_c',
    'tsp': 'c_a_c',

    // Cuillère à soupe
    'cas': 'c_a_s',
    'c_a_s': 'c_a_s',
    'c_s': 'c_a_s',
    'cs': 'c_a_s',
    'c_a_soupe': 'c_a_s',
    'cuillere_soupe': 'c_a_s',
    'cuilleres_soupe': 'c_a_s',
    'cuillere_a_soupe': 'c_a_s',
    'cuilleres_a_soupe': 'c_a_s',
    'cuilleree_soupe': 'c_a_s',
    'cuillerees_soupe': 'c_a_s',
    'cuilleree_a_soupe': 'c_a_s',
    'cuillerees_a_soupe': 'c_a_s',
    'cuiller_a_soupe': 'c_a_s',
    'cuillers_a_soupe': 'c_a_s',
    'cuil_a_soupe': 'c_a_s',
    'cuil_soupe': 'c_a_s',
    'tablespoon': 'c_a_s',
    'tablespoons': 'c_a_s',
    'tbsp': 'c_a_s',

    // Cuillère à thé
    'c_a_the': 'c_a_the',
    'cuillere_the': 'c_a_the',
    'cuilleres_the': 'c_a_the',
    'cuillere_a_the': 'c_a_the',
    'cuilleres_a_the': 'c_a_the',
    'cuilleree_a_the': 'c_a_the',
    'cuillerees_a_the': 'c_a_the',
    'cuiller_a_the': 'c_a_the',

    // Cuillère à dessert
    'c_a_d': 'c_a_d',
    'cad': 'c_a_d',
    'cuillere_a_dessert': 'c_a_d',
    'cuilleres_a_dessert': 'c_a_d',
    'cuilleree_a_dessert': 'c_a_d',
    'cuillerees_a_dessert': 'c_a_d',
    'cuiller_a_dessert': 'c_a_d',

    // Onces liquides
    'fl_oz': 'fl_oz',
    'once_liquide_americaine': 'fl_oz',
    'uk_fl_oz': 'uk_fl_oz',
    'once_liquide_imperiale': 'uk_fl_oz',

    // Contenants
    'tasse_a_cafe': 'tasse_a_cafe',
    'tasses_a_cafe': 'tasse_a_cafe',
    'verre_a_vin': 'verre_vin',
    'verre_vin': 'verre_vin',
    'grand_verre': 'grand_verre',
    'grand_verre_a_moutarde': 'grand_verre',
    'tasse_metrique': 'tasse_metrique',
    'tasses_metriques': 'tasse_metrique',
    'quart_de_litre': 'quart_de_litre',
    'demi_litre': 'demi_litre',
    'chopine': 'chopine',
    'choppe': 'chopine',
    'pinte_americaine': 'pinte_americaine',
    'pt_us': 'pinte_americaine',
    'pinte_imperiale': 'pinte_imperiale',
    'pt_uk': 'pinte_imperiale',
    'quart_americain': 'quart_americain',
    'qt_us': 'quart_americain',
    'gallon_americain': 'gallon_americain',
    'gal_us': 'gallon_americain',

    // Petites mesures à poids fixe
    'pincee': 'pincee',
    'pincees': 'pincee',
    'pinch': 'pincee',
    'pointe_de_couteau': 'pointe_de_couteau',
    'pointe': 'pointe_de_couteau',
    'larme': 'larme',
    'larmes': 'larme',
    'goutte': 'goutte',
    'gouttes': 'goutte',

    // Compteurs / pièces
    'piece': 'piece',
    'pieces': 'piece',
    'unite': 'piece',
    'unites': 'piece',
    'pc': 'piece',
    'pcs': 'piece',

    // Unités botaniques — pluriel → singulier canonique
    'brins': 'brin',
    'filets': 'filet',
    'tiges': 'tige',
    'noisettes': 'noisette',
    'zestes': 'zeste',
    'bouquets': 'bouquet',
    'feuilles': 'feuille',
    'branches': 'branche',
  };

  static const Map<String, double> _weightUnitToGrams = {
    'g': 1,
    'gr': 1,
    'gram': 1,
    'grams': 1,
    'kg': 1000,
    'mg': 0.001,
    // Petites mesures fixes (poids indépendant du volume)
    'pincee': 0.5,
    'pointe_de_couteau': 1,
    // Unités botaniques — valeurs par défaut alignées sur le référentiel
    // serveur, qui peut les surcharger depuis Firestore (nutrition_units).
    'brin': 2,
    'filet': 5,
    'bouquet': 30,
    'feuille': 1,
    'branche': 15,
    'tige': 3,
    'noisette': 5,
    'zeste': 3,
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
    'c_a_c': 5,
    'c_a_the': 5,
    'c_a_s': 15,
    'c_a_d': 10,
    'tasse': 240,
    'tasses': 240,
    'cup': 240,
    'cups': 240,
    'verre': 200,
    'verres': 200,
    'verre_a_the': 200,
    'verres_a_the': 200,
    'bol': 350,
    'bols': 350,
    // Petits volumes
    'larme': 0.05,
    'goutte': 0.05,
    // Onces liquides
    'fl_oz': 29.5,
    'uk_fl_oz': 28.4,
    // Contenants
    'tasse_a_cafe': 70,
    'verre_vin': 120,
    'tasse_metrique': 250,
    'grand_verre': 200,
    'quart_de_litre': 250,
    'chopine': 480,
    'pinte_americaine': 473,
    'pinte_imperiale': 568,
    'demi_litre': 500,
    'quart_americain': 946,
    'gallon_americain': 3785,
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
      matchers: [
        'farine',
        'fecule',
        'maizena',
        'poudre_d_amande',
        'amande_en_poudre',
      ],
      densityGPerMl: 0.55,
    ),
    (matchers: ['sucre_glace', 'sucre_iced'], densityGPerMl: 0.5),
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
      matchers: [
        'lait',
        'eau',
        'bouillon',
        'vinaigre',
        'vin',
        'jus',
        'cafe',
        'the',
      ],
      densityGPerMl: 1,
    ),
  ];

  static const List<({List<String> matchers, double gramsPerPiece})>
  _pieceWeightProfiles = [
    // Œufs — l'ORDRE compte : la recherche se fait par `contains`, donc les
    // formes les plus spécifiques doivent précéder « oeuf », sinon un jaune
    // hériterait du poids d'un œuf entier. Poids sans coquille, calibre moyen.
    // Les pluriels sont listés explicitement : « jaunes d'œufs » se normalise
    // en `jaunes_d_oeufs`, que « jaune_d_oeuf » ne peut pas atteindre.
    (
      matchers: ['jaune_d_oeuf', 'jaunes_d_oeuf', 'jaune_oeuf'],
      gramsPerPiece: 18,
    ),
    (
      matchers: ['blanc_d_oeuf', 'blancs_d_oeuf', 'blanc_oeuf'],
      gramsPerPiece: 30,
    ),
    (matchers: ['oeuf'], gramsPerPiece: 50),
    (matchers: ['aubergine'], gramsPerPiece: 300),
    (matchers: ['concombre'], gramsPerPiece: 300),
    (matchers: ['courgette'], gramsPerPiece: 200),
    (matchers: ['poivron'], gramsPerPiece: 150),
    (matchers: ['tomate'], gramsPerPiece: 120),
    (matchers: ['oignon'], gramsPerPiece: 110),
    (matchers: ['echalote'], gramsPerPiece: 30),
    (matchers: ['carotte'], gramsPerPiece: 80),
    (matchers: ['pomme_de_terre'], gramsPerPiece: 170),
    (matchers: ['ail'], gramsPerPiece: 5),
    (matchers: ['steak', 'steack'], gramsPerPiece: 150),
    (matchers: ['escalope'], gramsPerPiece: 150),
    (matchers: ['blanc_de_poulet', 'filet_de_poulet'], gramsPerPiece: 180),
    (
      matchers: ['haut_de_cuisse_de_poulet', 'haut_de_cuisse'],
      gramsPerPiece: 130,
    ),
    (matchers: ['cuisse_de_poulet'], gramsPerPiece: 180),
    (matchers: ['saucisse'], gramsPerPiece: 100),
    (matchers: ['cotelette'], gramsPerPiece: 140),
    (matchers: ['tranche_de_jambon', 'jambon'], gramsPerPiece: 40),
    (matchers: ['boulette'], gramsPerPiece: 30),
  ];

  /// Fractions Unicode courantes en cuisine → valeur décimale.
  static const Map<String, double> _unicodeFractions = {
    '½': 0.5,
    '⅓': 1 / 3,
    '⅔': 2 / 3,
    '¼': 0.25,
    '¾': 0.75,
    '⅕': 0.2,
    '⅖': 0.4,
    '⅗': 0.6,
    '⅘': 0.8,
    '⅙': 1 / 6,
    '⅚': 5 / 6,
    '⅐': 1 / 7,
    '⅛': 0.125,
    '⅜': 0.375,
    '⅝': 0.625,
    '⅞': 0.875,
    '⅑': 1 / 9,
    '⅒': 0.1,
  };

  /// Parse une quantité culinaire en nombre positif.
  /// Gère : entiers, décimaux (`,` ou `.`), fractions ASCII (`1/2`),
  /// fractions Unicode (`½`) et nombres mixtes (`1 ½`, `1 1/2`).
  /// Retourne `null` si non parsable ou si le résultat est <= 0.
  static double? parseQuantity(String raw) {
    var s = raw.trim().replaceAll(',', '.');
    if (s.isEmpty) return null;

    var total = 0.0;
    var matchedUnicode = false;
    _unicodeFractions.forEach((glyph, dec) {
      if (s.contains(glyph)) {
        total += dec;
        s = s.replaceAll(glyph, ' ').trim();
        matchedUnicode = true;
      }
    });

    if (s.isNotEmpty) {
      final mixed = RegExp(r'^(?:(\d+)\s+)?(\d+)\s*/\s*(\d+)$').firstMatch(s);
      if (mixed != null) {
        final whole = mixed.group(1) != null
            ? double.parse(mixed.group(1)!)
            : 0.0;
        final num = double.parse(mixed.group(2)!);
        final den = double.parse(mixed.group(3)!);
        if (den > 0) {
          total += whole + num / den;
          return total > 0 ? total : null;
        }
      }
      final parsed = double.tryParse(s);
      if (parsed != null) {
        total += parsed;
        return total > 0 ? total : null;
      }
      if (!matchedUnicode) return null;
    }

    return total > 0 ? total : null;
  }

  /// Unité normalisée en minuscules sans accents, alias résolu.
  /// Miroir de `normalizeObservedUnit()` côté TypeScript.
  static String normalizeObservedUnit(String unit) =>
      _canonicalUnit(_normalize(unit));

  /// Métadonnées de la table intégrée pour une unité, ou `null` si inconnue.
  /// Miroir de `getKnownUnitMetadata()` côté TypeScript.
  static KnownUnit? knownUnitMetadata(String unit, String ingredientName) {
    final normalizedUnit = normalizeObservedUnit(unit);

    if (normalizedUnit.isEmpty) {
      final matchedPieceWeight = _matchedPieceWeightForIngredient(
        ingredientName,
      );
      if (matchedPieceWeight == null) return null;
      return KnownUnit(
        normalizedUnit: 'piece',
        measurementType: UnitMeasurementType.count,
        gramsPerUnit: matchedPieceWeight,
      );
    }

    final weightFactor = _weightUnitToGrams[normalizedUnit];
    if (weightFactor != null) {
      return KnownUnit(
        normalizedUnit: normalizedUnit,
        measurementType: UnitMeasurementType.weight,
        gramsPerUnit: weightFactor,
      );
    }

    final volumeMl = _volumeUnitToMl[normalizedUnit];
    if (volumeMl != null) {
      return KnownUnit(
        normalizedUnit: normalizedUnit,
        measurementType: UnitMeasurementType.volume,
        mlPerUnit: volumeMl,
        gramsPerUnit: volumeMl * densityForIngredient(ingredientName),
      );
    }

    if (normalizedUnit == 'piece') {
      return KnownUnit(
        normalizedUnit: normalizedUnit,
        measurementType: UnitMeasurementType.count,
        gramsPerUnit: _pieceWeightForIngredient(ingredientName),
      );
    }

    return null;
  }

  /// Poids en grammes d'UNE unité selon la seule table intégrée.
  static double? unitFactorToGrams(String unit, String ingredientName) =>
      knownUnitMetadata(unit, ingredientName)?.gramsPerUnit;

  /// Poids en grammes d'UNE unité, en combinant le référentiel Firestore
  /// `nutrition_units` et la table intégrée.
  ///
  /// Règle identique au backend (`resolveUnitFactorToGrams` en TypeScript) :
  /// sur une unité de VOLUME seul le volume est intrinsèque, les grammes
  /// restent `ml × densité(ingrédient)` — un `grams_per_unit` stocké sur une
  /// unité de volume est le poids d'un seul ingrédient et est ignoré.
  ///
  /// Même règle pour une unité de COMPTAGE — « pièce » n'a pas de poids
  /// intrinsèque, elle prend celui de l'ingrédient compté. Sur une unité de
  /// POIDS, le référentiel prime au contraire sur la table intégrée.
  static double? resolveUnitFactorToGrams(
    String unit,
    String ingredientName,
    ReferentialUnitOverride? override,
  ) {
    final builtin = knownUnitMetadata(unit, ingredientName);
    final isVolume =
        override?.measurementType == 'volume' ||
        builtin?.measurementType == UnitMeasurementType.volume;

    if (isVolume) {
      final overrideMl = override?.volumeMlPerUnit;
      final ml = (overrideMl != null && overrideMl > 0)
          ? overrideMl
          : builtin?.mlPerUnit;
      if (ml != null && ml > 0) {
        return ml * densityForIngredient(ingredientName);
      }
    }

    // La table seule décide qu'une unité est un comptage : un document du
    // référentiel ne peut pas transformer une unité qu'elle ignore — donc
    // corrigeable à la main — en comptage dont on jetterait la correction.
    final isCount = builtin?.measurementType == UnitMeasurementType.count;

    final overrideGrams = override?.gramsPerUnit;
    if (!isVolume && !isCount && overrideGrams != null && overrideGrams > 0) {
      return overrideGrams;
    }

    return builtin?.gramsPerUnit;
  }

  /// Convertit une quantité en grammes.
  ///
  /// [override] provient du référentiel Firestore quand il est disponible ;
  /// sans lui, seule la table intégrée s'applique.
  static double? toGrams({
    required String ingredientName,
    required String qty,
    required String unit,
    ReferentialUnitOverride? override,
  }) {
    final quantity = parseQuantity(qty);
    if (quantity == null || quantity <= 0) return null;
    final factor = resolveUnitFactorToGrams(unit, ingredientName, override);
    if (factor == null) return null;
    return quantity * factor;
  }

  static double? _matchedPieceWeightForIngredient(String ingredientName) {
    final normalized = _normalize(ingredientName);
    if (normalized.isEmpty) return null;
    for (final profile in _pieceWeightProfiles) {
      if (profile.matchers.any(normalized.contains)) {
        return profile.gramsPerPiece;
      }
    }
    return null;
  }

  static double _pieceWeightForIngredient(String ingredientName) {
    final matched = _matchedPieceWeightForIngredient(ingredientName);
    if (matched != null) return matched;
    return 100;
  }

  /// Densité en g/ml de l'ingrédient, 1 par défaut (eau).
  ///
  /// C'est la densité — pas un poids figé par unité — qui fait foi pour
  /// convertir un volume en grammes : une cuillère à soupe d'huile, de miel et
  /// de farine ne pèsent pas la même chose.
  static double densityForIngredient(String ingredientName) {
    final normalized = _normalize(ingredientName);
    if (normalized.isEmpty) return 1;
    for (final profile in _densityProfiles) {
      if (profile.matchers.any(normalized.contains)) {
        return profile.densityGPerMl;
      }
    }
    return 1;
  }

  static String _canonicalUnit(String normalizedUnit) {
    if (normalizedUnit.isEmpty) return '';
    final alias = _canonicalUnitAliases[normalizedUnit];
    if (alias != null) return alias;
    if (_countUnits.contains(normalizedUnit)) return 'piece';
    return normalizedUnit;
  }

  /// Délègue au normaliseur partagé : la même règle identifie ingrédients
  /// et unités, elle doit rester unique. Voir core/utils/ingredient_name.dart.
  static String _normalize(String value) => normalizeBase(value);
}
