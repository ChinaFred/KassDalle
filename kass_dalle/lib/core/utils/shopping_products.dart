/// Regroupement des lignes de courses — jumeau Dart de
/// `functions/src/nutrition/shoppingDerivation.ts`.
///
/// Le serveur regroupe les ingrédients d'une recette à son écriture. Le client
/// regroupe à son tour, entre recettes : la liste du planning additionne les
/// produits de plusieurs recettes et de leurs garnitures, et la feuille de
/// courses fusionne une liste enregistrée avec une nouvelle. Les deux côtés
/// appliquent la même règle, verrouillée par
/// `test-fixtures/shopping_products.json`.
///
/// Clé de regroupement : identité singularisée du produit + famille d'unité.
/// Seules les conversions exactes s'additionnent — kilo et grammes, litre,
/// centilitre et millilitre. Un comptage et un poids restent deux lignes :
/// aucune densité, aucun poids moyen inventé.
library;

import '../../features/recipes/domain/recipe.dart';
import 'ingredient_name.dart';
import 'nutrition_quantity_converter.dart';

/// Famille d'unité d'une ligne, et facteur vers l'unité de base de la famille.
typedef ShoppingUnitFamily = ({String family, double factor});

/// Unités de masse, en grammes — clés : unité observée normalisée.
const Map<String, double> _massToGrams = {
  'g': 1,
  'gr': 1,
  'grs': 1,
  'gramme': 1,
  'grammes': 1,
  'gram': 1,
  'grams': 1,
  'kg': 1000,
  'kgs': 1000,
  'kilo': 1000,
  'kilos': 1000,
  'kilogramme': 1000,
  'kilogrammes': 1000,
  'mg': 0.001,
};

/// Unités de volume, en millilitres — conversions exactes seules.
const Map<String, double> _volumeToMl = {
  'ml': 1,
  'millilitre': 1,
  'millilitres': 1,
  'milliliter': 1,
  'milliliters': 1,
  'cl': 10,
  'centilitre': 10,
  'centilitres': 10,
  'dl': 100,
  'decilitre': 100,
  'decilitres': 100,
  'l': 1000,
  'litre': 1000,
  'litres': 1000,
  'liter': 1000,
  'liters': 1000,
};

/// Famille d'une unité telle qu'écrite dans une recette.
///
/// Une unité absente compte des pièces : « 6 pommes de terre ». Une cuillère à
/// soupe n'a pas de conversion exacte vers autre chose : elle forme sa propre
/// famille, et deux cuillères s'additionnent entre elles seulement.
ShoppingUnitFamily shoppingUnitFamily(String unit) {
  final normalized = NutritionQuantityConverter.normalizeObservedUnit(unit);
  if (normalized.isEmpty || normalized == 'piece') {
    return (family: 'piece', factor: 1);
  }
  final grams = _massToGrams[normalized];
  if (grams != null) return (family: 'g', factor: grams);
  final ml = _volumeToMl[normalized];
  if (ml != null) return (family: 'ml', factor: ml);
  return (family: normalized, factor: 1);
}

/// Identité d'un produit : nom singularisé, sans mot de préparation.
String shoppingProductKey(String name) {
  final id = normalizeIngredientSingularId(name);
  return id.isNotEmpty ? id : name.trim().toLowerCase();
}

/// Nombre sans décimale inutile, virgule décimale, deux décimales au plus.
String formatShoppingNumber(double value) {
  final rounded = (value * 100).round() / 100;
  if (rounded == rounded.truncateToDouble()) return rounded.toInt().toString();
  return rounded
      .toStringAsFixed(2)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '')
      .replaceAll('.', ',');
}

/// Quantité et unité d'un total additionné.
///
/// En grammes ou millilitres tant que le total tient sous mille ; au-delà, en
/// kilo ou litre seulement si rien n'est perdu — 1 234 g restent 1 234 g plutôt
/// que de devenir 1,23 kg. Pour les autres familles, l'unité rendue est `null` :
/// c'est celle de la ligne qui s'applique.
({String qty, String? unit}) formatShoppingTotal(double total, String family) {
  if (family == 'g' || family == 'ml') {
    final big = family == 'g' ? 'kg' : 'l';
    final tenths = total / 10;
    final exactInBig = total >= 1000 && (tenths - tenths.round()).abs() < 1e-6;
    if (exactInBig) {
      return (qty: formatShoppingNumber(total / 1000), unit: big);
    }
    return (qty: formatShoppingNumber(total), unit: family);
  }
  return (qty: formatShoppingNumber(total), unit: null);
}

class _Group {
  final String productKey;
  final ShoppingUnitFamily family;

  /// Unité de la première ligne, telle qu'écrite.
  final String unit;
  int numericCount = 0;

  /// Quantité de la première ligne chiffrée, telle qu'écrite.
  String firstQty = '';
  double total = 0;
  final List<String> textual = [];

  _Group({required this.productKey, required this.family, required this.unit});
}

/// Regroupe des lignes (nom, quantité, unité) en lignes de courses.
///
/// Toutes les lignes d'un même produit portent le même nom, celui de la
/// première lue. Une ligne seule dans sa famille garde sa quantité et son
/// unité telles qu'écrites — « 0,5 kg », « 1/2 ». Dès qu'on additionne, le
/// total s'écrit dans l'unité de base de la famille, ou en kilo/litre quand
/// c'est exact. Une quantité non chiffrable — « qsp », « à volonté » — est
/// conservée telle quelle : l'ingrédient ne disparaît pas de la liste.
List<RecipeShoppingProduct> mergeShoppingProducts(
  Iterable<RecipeShoppingProduct> entries,
) {
  final order = <String>[];
  final groups = <String, _Group>{};
  final displayName = <String, String>{};

  for (final entry in entries) {
    final name = entry.name.trim();
    if (name.isEmpty) continue;
    final productKey = shoppingProductKey(name);
    displayName.putIfAbsent(productKey, () => name);

    final unit = entry.unit.trim();
    final family = shoppingUnitFamily(unit);
    final key = '$productKey|${family.family}';
    final group = groups.putIfAbsent(key, () {
      order.add(key);
      return _Group(productKey: productKey, family: family, unit: unit);
    });

    final rawQty = entry.qty.trim();
    final value = NutritionQuantityConverter.parseQuantity(rawQty);
    if (value == null) {
      if (rawQty.isNotEmpty) group.textual.add(rawQty);
      continue;
    }
    if (group.numericCount == 0) group.firstQty = rawQty;
    group.numericCount += 1;
    group.total += value * family.factor;
  }

  return [
    for (final key in order)
      () {
        final group = groups[key]!;
        var qtyText = '';
        var unit = group.unit;
        if (group.numericCount == 1) {
          qtyText = group.firstQty;
        } else if (group.numericCount > 1) {
          final formatted = formatShoppingTotal(
            group.total,
            group.family.family,
          );
          qtyText = formatted.qty;
          if (formatted.unit != null) unit = formatted.unit!;
        }
        final parts = qtyText.isNotEmpty
            ? [qtyText, ...group.textual]
            : group.textual;
        return RecipeShoppingProduct(
          name: displayName[group.productKey] ?? '',
          qty: parts.join(' + '),
          unit: unit,
        );
      }(),
  ];
}
