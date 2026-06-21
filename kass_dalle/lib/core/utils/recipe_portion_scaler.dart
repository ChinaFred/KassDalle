import '../../features/recipes/domain/recipe.dart';

const Map<String, double> _unicodeFractions = {
  '¼': 0.25,
  '½': 0.5,
  '¾': 0.75,
  '⅓': 1 / 3,
  '⅔': 2 / 3,
  '⅛': 0.125,
  '⅜': 0.375,
  '⅝': 0.625,
  '⅞': 0.875,
};

double portionScaleFactor({required int basePortions, required int targetPortions}) {
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

String scaleQuantityText(String qty, double factor) {
  final raw = qty.trim();
  if (raw.isEmpty || factor == 1.0) return qty;

  var out = raw;

  out = out.replaceAllMapped(RegExp(r'(\d+)\s+(\d+)/(\d+)'), (m) {
    final whole = int.parse(m.group(1)!);
    final num = int.parse(m.group(2)!);
    final den = int.parse(m.group(3)!);
    if (den == 0) return m.group(0)!;
    final value = (whole + (num / den)) * factor;
    return _formatScaledNumber(value);
  });

  out = out.replaceAllMapped(RegExp(r'(\d+)([¼½¾⅓⅔⅛⅜⅝⅞])'), (m) {
    final whole = int.parse(m.group(1)!);
    final frac = _unicodeFractions[m.group(2)!];
    if (frac == null) return m.group(0)!;
    final value = (whole + frac) * factor;
    return _formatScaledNumber(value);
  });

  out = out.replaceAllMapped(RegExp(r'\b(\d+)/(\d+)\b'), (m) {
    final num = int.parse(m.group(1)!);
    final den = int.parse(m.group(2)!);
    if (den == 0) return m.group(0)!;
    final value = (num / den) * factor;
    return _formatScaledNumber(value);
  });

  out = out.replaceAllMapped(RegExp(r'\b\d+(?:[.,]\d+)?\b'), (m) {
    final value = double.tryParse(m.group(0)!.replaceAll(',', '.'));
    if (value == null) return m.group(0)!;
    return _formatScaledNumber(value * factor);
  });

  return out;
}

String _formatScaledNumber(double value) {
  if ((value - value.round()).abs() < 1e-6) return value.round().toString();
  final fixed = value.toStringAsFixed(2);
  final compact = fixed
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
  return compact.replaceAll('.', ',');
}