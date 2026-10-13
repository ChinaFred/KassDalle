import '../../../core/utils/ingredient_categorizer.dart';
import '../../../core/utils/ingredient_display.dart';
import '../../../core/utils/shopping_products.dart';
import 'recipe.dart';

/// Une quantité d'une ligne de courses : une famille d'unité, un total.
typedef ShoppingQuantity = ({String qty, String unit});

/// Le panier de courses d'un compte : `users/{uid}/shopping/current`.
///
/// Un seul document par compte, le même sur tous ses appareils. Personne
/// d'autre ne le lit ni ne l'écrit : les produits ajoutés depuis le planning
/// d'un autre membre vont dans le panier de celui qui ajoute. Rien n'est écrit
/// dans une recette ni dans un repas.
///
/// Forme :
/// `{ items: { clé_produit: { name, quantities: [ { qty, unit } ],
/// category, source, checked, pos } }, updated_at }`. Une carte plutôt
/// qu'une liste : cocher une case écrit le seul champ
/// `items.clé_produit.checked`,
/// une écriture qui part aussi hors ligne, dans le magasin, et qui n'écrase
/// pas ce qu'un autre appareil vient de cocher. `pos` garde l'ordre d'ajout.
///
/// Les règles Firestore bornent le nombre d'articles
/// ([kShoppingCartMaxItems]) ; elles ne savent pas parcourir une carte, donc
/// les longueurs de chaque champ sont bornées ici, à l'écriture.
class ShoppingCart {
  final List<ShoppingItem> items;

  const ShoppingCart(this.items);

  static const empty = ShoppingCart([]);

  bool get isEmpty => items.isEmpty;
  int get length => items.length;
  int get checkedCount => items.where((i) => i.checked).length;
  int get uncheckedCount => items.length - checkedCount;

  /// Lit le document. Un document absent, ou une entrée illisible, ne fait
  /// pas échouer la lecture : l'entrée est écartée, le reste s'affiche.
  factory ShoppingCart.fromFirestore(Map<String, dynamic>? data) {
    final raw = data?['items'];
    if (raw is! Map) return empty;
    final read = <({int pos, ShoppingItem item})>[];
    for (final e in raw.values) {
      if (e is! Map) continue;
      final entry = Map<String, dynamic>.from(e);
      final item = ShoppingItem.fromFirestore(entry);
      if (item == null) continue;
      final pos = entry['pos'];
      read.add((pos: pos is num ? pos.toInt() : 1 << 30, item: item));
    }
    read.sort((a, b) {
      final byPos = a.pos.compareTo(b.pos);
      return byPos != 0 ? byPos : a.item.name.compareTo(b.item.name);
    });
    return ShoppingCart([for (final r in read) r.item]);
  }

  /// La carte `items` du document : une entrée par produit, `pos` dans
  /// l'ordre de [items].
  static Map<String, dynamic> itemsToFirestore(List<ShoppingItem> items) => {
    for (var i = 0; i < items.length; i++)
      items[i].key: {...items[i].toFirestore(), 'pos': i},
  };
}

/// Nombre d'articles au plus dans un panier. Même borne dans
/// `firestore.rules` (`isShoppingCart`).
const kShoppingCartMaxItems = 300;

/// Longueurs au plus, à l'écriture. Les règles ne les vérifient pas (elles ne
/// parcourent pas une liste) : ce sont des bornes de bon sens, qui empêchent
/// une provenance de grossir sans fin au fil des fusions.
const kShoppingNameMax = 200;
const kShoppingSourceMax = 500;
const kShoppingQtyMax = 40;
const kShoppingCategoryMax = 60;
const kShoppingQuantitiesMax = 10;

/// Le panier compterait plus de [kShoppingCartMaxItems] articles.
class ShoppingCartFullException implements Exception {
  final int wanted;
  const ShoppingCartFullException(this.wanted);

  @override
  String toString() =>
      'ShoppingCartFullException: $wanted articles, '
      '$kShoppingCartMaxItems au plus';
}

/// Une ligne de la liste de courses : un produit, une quantité par famille
/// d'unité (« 400 ml + 250 g de lait de coco »), son rayon et d'où il vient.
class ShoppingItem {
  final String name;
  final List<ShoppingQuantity> quantities;
  final String category;
  final String? source;
  final bool checked;

  const ShoppingItem({
    required this.name,
    required this.quantities,
    required this.category,
    this.source,
    this.checked = false,
  });

  /// L'identité de la ligne : celle du produit, comme au regroupement. Elle
  /// sert de clé dans la carte `items` du document, bornée comme un nom.
  String get key => _cut(shoppingProductKey(name), kShoppingNameMax);

  /// « 3 cuillères à soupe de sauce soja », accordé comme sur la fiche.
  String get label => formatShoppingLine(quantities: quantities, name: name);

  ShoppingItem copyWith({bool? checked}) => ShoppingItem(
    name: name,
    quantities: quantities,
    category: category,
    source: source,
    checked: checked ?? this.checked,
  );

  Map<String, dynamic> toFirestore() => {
    'name': _cut(name, kShoppingNameMax),
    'quantities': [
      for (final q in quantities.take(kShoppingQuantitiesMax))
        {
          'qty': _cut(q.qty, kShoppingQtyMax),
          'unit': _cut(q.unit, kShoppingQtyMax),
        },
    ],
    'category': _cut(category, kShoppingCategoryMax),
    'source': source == null ? null : _cut(source!, kShoppingSourceMax),
    'checked': checked,
  };

  /// Lit une entrée du document ; null si elle n'a pas de nom.
  static ShoppingItem? fromFirestore(Map<String, dynamic> j) {
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final raw = j['quantities'];
    return ShoppingItem(
      name: name,
      quantities: [
        if (raw is List)
          for (final e in raw)
            if (e is Map)
              (
                qty: e['qty'] is String ? e['qty'] as String : '',
                unit: e['unit'] is String ? e['unit'] as String : '',
              ),
      ],
      category: j['category'] is String
          ? j['category'] as String
          : IngredientCategorizer.categorize(name),
      source: j['source'] is String ? j['source'] as String : null,
      checked: j['checked'] == true,
    );
  }

  /// Lit une ligne de l'ancienne liste locale (`sl_items_{uid}` dans
  /// `SharedPreferences`, avant le panier Firestore) : clés courtes, et une
  /// liste plus ancienne encore porte `q` et `u` à plat. Null sans nom.
  static ShoppingItem? fromLegacyJson(Map<String, dynamic> j) {
    final name = j['n'];
    if (name is! String || name.trim().isEmpty) return null;
    final raw = j['qs'];
    final quantities = raw is List
        ? <ShoppingQuantity>[
            for (final e in raw)
              if (e is Map)
                (qty: e['q'] as String? ?? '', unit: e['u'] as String? ?? ''),
          ]
        : <ShoppingQuantity>[
            (qty: j['q'] as String? ?? '', unit: j['u'] as String? ?? ''),
          ];
    return ShoppingItem(
      name: name,
      quantities: quantities,
      category: j['c'] as String? ?? 'Autres',
      source: j['s'] as String?,
      checked: j['x'] as bool? ?? false,
    );
  }
}

String _cut(String value, int max) =>
    value.length <= max ? value : value.substring(0, max);

/// Une ligne par produit.
///
/// `mergeShoppingProducts` rend une entrée par produit et famille d'unité,
/// toutes sous le même nom ; elles se rangent ici sur une seule ligne, avec
/// une quantité par famille. La provenance d'une ligne est celle que
/// [sourceOf] donne à son produit — les titres de recettes dans le planning,
/// le titre de la recette ouverte sinon.
List<ShoppingItem> shoppingItemsFromProducts(
  Iterable<RecipeShoppingProduct> products,
  String Function(RecipeShoppingProduct product) sourceOf,
) {
  final order = <String>[];
  final byKey =
      <
        String,
        ({String name, List<ShoppingQuantity> quantities, Set<String> sources})
      >{};
  for (final p in mergeShoppingProducts(products)) {
    if (p.name.trim().isEmpty) continue;
    final key = shoppingProductKey(p.name);
    final slot = byKey.putIfAbsent(key, () {
      order.add(key);
      return (name: p.name, quantities: <ShoppingQuantity>[], sources: {});
    });
    slot.quantities.add((qty: p.qty, unit: p.unit));
    final source = sourceOf(p).trim();
    if (source.isNotEmpty) slot.sources.add(source);
  }
  return [
    for (final key in order)
      ShoppingItem(
        name: byKey[key]!.name,
        quantities: byKey[key]!.quantities,
        category: IngredientCategorizer.categorize(byKey[key]!.name),
        source: byKey[key]!.sources.isEmpty
            ? null
            : byKey[key]!.sources.join(' · '),
      ),
  ];
}

/// Les lignes d'une recette ouverte : ses produits d'achat, ou à défaut ses
/// ingrédients bruts (recette dont les produits ne sont pas encore calculés).
List<ShoppingItem> shoppingItemsForRecipe({
  required List<RecipeShoppingProduct> products,
  required List<RecipeIngredient> fallbackIngredients,
  required String recipeTitre,
  Map<String, String>? ingredientSources,
}) {
  final source = products.isNotEmpty
      ? products
      : [
          for (final ing in fallbackIngredients)
            RecipeShoppingProduct(name: ing.name, qty: ing.qty, unit: ing.unit),
        ];
  return shoppingItemsFromProducts(
    source,
    (p) => ingredientSources?[p.name] ?? recipeTitre,
  );
}

/// « Ajouter » : fusionne [incoming] dans [existing]. Même produit → même
/// ligne, quantités additionnées famille par famille, provenances réunies.
///
/// Une ligne cochée qui reçoit une nouvelle quantité redevient à acheter :
/// ce qu'on a déjà dans le panier ne couvre pas ce qui vient d'arriver.
List<ShoppingItem> mergeShoppingItems(
  List<ShoppingItem> existing,
  List<ShoppingItem> incoming,
) {
  final merged = <ShoppingItem>[];
  final indexByKey = <String, int>{};

  for (final item in [...existing, ...incoming]) {
    final key = item.key;
    final existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = merged.length;
      merged.add(
        ShoppingItem(
          name: item.name,
          quantities: List.of(item.quantities),
          category: item.category,
          source: item.source,
          checked: item.checked,
        ),
      );
      continue;
    }

    final current = merged[existingIndex];
    final quantities = mergeShoppingProducts([
      for (final q in current.quantities)
        RecipeShoppingProduct(name: current.name, qty: q.qty, unit: q.unit),
      for (final q in item.quantities)
        RecipeShoppingProduct(name: item.name, qty: q.qty, unit: q.unit),
    ]).map((p) => (qty: p.qty, unit: p.unit)).toList();
    merged[existingIndex] = ShoppingItem(
      name: current.name,
      quantities: quantities,
      category: current.category,
      source: _mergeSources(current.source, item.source),
      checked: current.checked && item.checked,
    );
  }

  return merged;
}

String? _mergeSources(String? left, String? right) {
  final values = <String>{};
  for (final source in [left, right]) {
    if (source == null || source.trim().isEmpty) continue;
    for (final part in source.split(' · ')) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) values.add(trimmed);
    }
  }
  if (values.isEmpty) return null;
  return values.join(' · ');
}

/// « 1 article », « 9 articles ».
String shoppingArticles(int n) => '$n article${n > 1 ? 's' : ''}';
