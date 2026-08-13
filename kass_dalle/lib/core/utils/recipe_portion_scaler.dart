import '../../features/recipes/domain/recipe.dart';

/// Fractions Unicode courantes en cuisine → valeur décimale.
/// Même jeu de glyphes que [NutritionQuantityConverter] : une quantité lisible
/// par le calcul nutritionnel doit l'être aussi par le recalcul de portions.
const Map<String, double> _unicodeFractions = {
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

final String _fractionGlyphs = _unicodeFractions.keys.join();

/// Reconnaît, en UNE seule passe, toutes les formes de quantité que l'on peut
/// mettre à l'échelle. Les alternatives vont de la plus spécifique à la plus
/// générale : un nombre mixte doit gagner sur la fraction seule, qui doit
/// gagner sur le nombre simple.
///
/// Le passage en une seule passe n'est pas cosmétique : la version précédente
/// enchaînait quatre `replaceAllMapped` sur la même chaîne, si bien que la
/// dernière passe (« tout nombre ») remettait à l'échelle le résultat déjà
/// produit par les passes fractions. Toute quantité fractionnaire était donc
/// multipliée deux fois.
final RegExp _scalableQuantity = RegExp(
  // 1,2,3 : nombre mixte ASCII — « 1 1/2 »
  r'(\d+)\s+(\d+)\s*/\s*(\d+)'
  // 4,5 : nombre mixte Unicode — « 1½ », « 1 ½ »
  '|'
  r'(\d+)\s*(['
  '$_fractionGlyphs'
  r'])'
  // 6,7 : fraction ASCII seule — « 1/2 »
  r'|(\d+)\s*/\s*(\d+)'
  // 8 : fraction Unicode seule — « ½ »
  '|(['
  '$_fractionGlyphs'
  '])'
  // 9 : nombre simple, entier ou décimal — « 200 », « 1,5 »
  r'|(\d+(?:[.,]\d+)?)',
);

double portionScaleFactor({
  required int basePortions,
  required int targetPortions,
}) {
  if (basePortions <= 0 || targetPortions <= 0) return 1.0;
  return targetPortions / basePortions;
}

List<RecipeIngredient> scaleRecipeIngredients(
  List<RecipeIngredient> ingredients,
  double factor,
) {
  if (ingredients.isEmpty || factor == 1.0) return ingredients;
  return ingredients
      .map(
        (ing) => RecipeIngredient(
          name: ing.name,
          qty: scaleQuantityText(ing.qty, factor),
          unit: ing.unit,
          category: ing.category,
        ),
      )
      .toList(growable: false);
}

List<RecipeShoppingProduct> scaleShoppingProducts(
  List<RecipeShoppingProduct> products,
  double factor,
) {
  if (products.isEmpty || factor == 1.0) return products;
  return products
      .map(
        (p) => RecipeShoppingProduct(
          name: p.name,
          qty: scaleQuantityText(p.qty, factor),
          unit: p.unit,
        ),
      )
      .toList(growable: false);
}

String scaleQuantityText(String qty, double factor) {
  final raw = qty.trim();
  if (raw.isEmpty || factor == 1.0) return qty;

  // Une seule passe : chaque token reconnu est mis à l'échelle exactement une
  // fois, puis remplacé par sa valeur formatée. Le texte produit n'est jamais
  // relu par la suite du remplacement.
  return raw.replaceAllMapped(_scalableQuantity, (m) {
    final value = _tokenValue(m);
    if (value == null) return m.group(0)!;
    return _formatScaledNumber(value * factor);
  });
}

/// Valeur décimale du token reconnu par [_scalableQuantity], ou `null` si le
/// token n'est pas exploitable (dénominateur nul, glyphe inconnu).
double? _tokenValue(Match m) {
  // Nombre mixte ASCII — « 1 1/2 »
  if (m.group(1) != null) {
    final den = int.parse(m.group(3)!);
    if (den == 0) return null;
    return int.parse(m.group(1)!) + int.parse(m.group(2)!) / den;
  }
  // Nombre mixte Unicode — « 1½ »
  if (m.group(4) != null) {
    final frac = _unicodeFractions[m.group(5)!];
    if (frac == null) return null;
    return int.parse(m.group(4)!) + frac;
  }
  // Fraction ASCII seule — « 1/2 »
  if (m.group(6) != null) {
    final den = int.parse(m.group(7)!);
    if (den == 0) return null;
    return int.parse(m.group(6)!) / den;
  }
  // Fraction Unicode seule — « ½ »
  if (m.group(8) != null) {
    return _unicodeFractions[m.group(8)!];
  }
  // Nombre simple — « 200 », « 1,5 »
  if (m.group(9) != null) {
    return double.tryParse(m.group(9)!.replaceAll(',', '.'));
  }
  return null;
}

String _formatScaledNumber(double value) {
  if ((value - value.round()).abs() < 1e-6) return value.round().toString();
  final fixed = value.toStringAsFixed(2);
  final compact = fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return compact.replaceAll('.', ',');
}
