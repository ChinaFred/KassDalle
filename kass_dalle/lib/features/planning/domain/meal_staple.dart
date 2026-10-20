/// Les garnitures simples : ce qui accompagne un plat sans avoir de recette.
///
/// Du riz, des pâtes, une salade verte, un yaourt. Personne n'écrit une
/// recette pour ça, et pourtant un repas en a besoin : pour dire « blanquette
/// et riz », pour compter le riz dans la liste de courses, pour en connaître
/// la part par personne.
///
/// Deux niveaux. Un **référentiel de base**, partagé par la famille et tenu
/// depuis Admin › Référentiels, dans `meal_staples/{id}`. Par-dessus, les
/// **retouches de chacun** — une quantité qui lui va mieux, une garniture
/// masquée, une garniture à lui — dans `users/{uid}/preferences/meal_staples`,
/// un seul document. Rien de personnel n'écrit dans le référentiel partagé.
library;

import '../../recipes/domain/allergens.dart';

/// Famille d'une garniture : sert au tri, à l'affichage, et plus tard à la
/// composition d'un repas (un plat sans féculent en reçoit un).
enum StapleCategory {
  feculent,
  legume,
  salade,
  pain,
  fromage,
  fruit,
  laitage,
  autre;

  String get label => switch (this) {
    StapleCategory.feculent => 'Féculent',
    StapleCategory.legume => 'Légume',
    StapleCategory.salade => 'Salade et crudités',
    StapleCategory.pain => 'Pain',
    StapleCategory.fromage => 'Fromage',
    StapleCategory.fruit => 'Fruit',
    StapleCategory.laitage => 'Laitage',
    StapleCategory.autre => 'Autre',
  };

  static StapleCategory fromKey(String? key) => StapleCategory.values
      .firstWhere((c) => c.name == key, orElse: () => StapleCategory.autre);
}

/// Unités admises pour une part de garniture.
const List<String> kStapleUnits = ['g', 'ml', 'pièce'];

/// Une garniture, telle qu'elle est stockée dans le référentiel.
class MealStaple {
  /// Identifiant stable, en minuscules sans accent : `riz`, `pates`.
  final String id;
  final String name;
  final StapleCategory category;

  /// Quantité pour une part, dans [unit].
  final double quantityPerPortion;

  /// `g`, `ml` ou `pièce`.
  final String unit;

  /// Précision utile à l'achat ou à la pesée : « poids sec ».
  final String note;

  /// Nom du produit sur la liste de courses ; vide = [name].
  final String shoppingProduct;

  final int sortOrder;

  /// Une garniture de base désactivée par un admin n'est proposée à personne.
  final bool active;

  /// `builtin` (semée), `admin` (créée depuis Admin) ou `user` (à quelqu'un).
  final String source;

  /// Allergènes majeurs de la garniture, clés de `allergens.dart`, saisis à
  /// la main (`allergens`, v0.24.18). `null` : non renseignés — une
  /// garniture ancienne, ou que personne n'a encore regardée. Une liste vide
  /// dit « aucun allergène majeur ». Lus par le planning pour écarter un
  /// accompagnement qui contient un allergène exclu.
  final List<String>? allergens;

  const MealStaple({
    required this.id,
    required this.name,
    required this.category,
    required this.quantityPerPortion,
    this.unit = 'g',
    this.note = '',
    this.shoppingProduct = '',
    this.sortOrder = 0,
    this.active = true,
    this.source = 'builtin',
    this.allergens,
  });

  String get effectiveShoppingProduct =>
      shoppingProduct.trim().isEmpty ? name : shoppingProduct.trim();

  /// « 125 g », « 1 pièce », « 2 pièces ».
  String get quantityLabel => formatStapleQuantity(quantityPerPortion, unit);

  factory MealStaple.fromFirestore(String id, Map<String, dynamic> data) =>
      MealStaple(
        id: id,
        name: data['name'] as String? ?? id,
        category: StapleCategory.fromKey(data['category'] as String?),
        quantityPerPortion:
            (data['quantity_per_portion'] as num?)?.toDouble() ?? 0,
        unit: data['unit'] as String? ?? 'g',
        note: data['note'] as String? ?? '',
        shoppingProduct: data['shopping_product'] as String? ?? '',
        sortOrder: (data['sort_order'] as num?)?.toInt() ?? 0,
        active: data['active'] as bool? ?? true,
        source: data['source'] as String? ?? 'builtin',
        allergens: stapleAllergensFrom(data['allergens']),
      );

  Map<String, dynamic> toFirestore() => {
    'name': name,
    'category': category.name,
    'quantity_per_portion': quantityPerPortion,
    'unit': unit,
    'note': note,
    'shopping_product': shoppingProduct,
    'sort_order': sortOrder,
    'active': active,
    'source': source,
    if (allergens != null) 'allergens': allergens,
  };

  MealStaple copyWith({
    String? name,
    StapleCategory? category,
    double? quantityPerPortion,
    String? unit,
    String? note,
    String? shoppingProduct,
    int? sortOrder,
    bool? active,
    String? source,
    List<String>? allergens,

    /// Rend la garniture à « allergènes non renseignés ».
    bool clearAllergens = false,
  }) => MealStaple(
    id: id,
    name: name ?? this.name,
    category: category ?? this.category,
    quantityPerPortion: quantityPerPortion ?? this.quantityPerPortion,
    unit: unit ?? this.unit,
    note: note ?? this.note,
    shoppingProduct: shoppingProduct ?? this.shoppingProduct,
    sortOrder: sortOrder ?? this.sortOrder,
    active: active ?? this.active,
    source: source ?? this.source,
    allergens: clearAllergens ? null : (allergens ?? this.allergens),
  );

  /// La garniture de base, retouchée par un utilisateur.
  MealStaple applying(StapleOverride o) => copyWith(
    name: o.name,
    category: o.category,
    quantityPerPortion: o.quantityPerPortion,
    unit: o.unit,
    note: o.note,
    shoppingProduct: o.shoppingProduct,
    allergens: o.allergens,
  );
}

/// Lit le champ `allergens` d'une garniture : les clés connues, dans l'ordre
/// du règlement ; `null` quand le champ manque ou n'est pas une liste.
List<String>? stapleAllergensFrom(Object? raw) {
  if (raw is! List) return null;
  final keys = raw.whereType<String>().toSet();
  return [
    for (final k in kAllergenKeys)
      if (keys.contains(k)) k,
  ];
}

/// Écrit une quantité comme on la lit : « 125 g », « 1 pièce », « 2 pièces ».
String formatStapleQuantity(double quantity, String unit) {
  final isWhole = quantity == quantity.truncateToDouble();
  final number = isWhole
      ? quantity.toInt().toString()
      : quantity.toStringAsFixed(1).replaceAll('.', ',');
  if (unit == 'pièce') return quantity > 1 ? '$number pièces' : '$number pièce';
  return '$number $unit';
}

/// Ce qu'un utilisateur a changé sur une garniture de base, ou une garniture
/// à lui.
///
/// Sur une garniture de base, seuls les champs non nuls comptent : les autres
/// gardent la valeur du référentiel, et suivent ses corrections. Une garniture
/// propre à l'utilisateur ([isOwn]) porte tous ses champs.
class StapleOverride {
  final String id;
  final bool isOwn;
  final bool hidden;
  final String? name;
  final StapleCategory? category;
  final double? quantityPerPortion;
  final String? unit;
  final String? note;
  final String? shoppingProduct;

  /// Allergènes retouchés, ou ceux d'une garniture à soi ; `null` : ceux du
  /// référentiel, ou non renseignés pour une garniture à soi.
  final List<String>? allergens;

  const StapleOverride({
    required this.id,
    this.isOwn = false,
    this.hidden = false,
    this.name,
    this.category,
    this.quantityPerPortion,
    this.unit,
    this.note,
    this.shoppingProduct,
    this.allergens,
  });

  /// Vrai si une valeur du référentiel est remplacée.
  bool get changesFields =>
      name != null ||
      category != null ||
      quantityPerPortion != null ||
      unit != null ||
      note != null ||
      shoppingProduct != null ||
      allergens != null;

  /// Vrai si l'entrée ne dit plus rien : à supprimer plutôt qu'à stocker.
  bool get isEmpty => !isOwn && !hidden && !changesFields;

  factory StapleOverride.fromMap(String id, Map<String, dynamic> data) =>
      StapleOverride(
        id: id,
        isOwn: data['own'] as bool? ?? false,
        hidden: data['hidden'] as bool? ?? false,
        name: data['name'] as String?,
        category: data['category'] is String
            ? StapleCategory.fromKey(data['category'] as String)
            : null,
        quantityPerPortion: (data['quantity_per_portion'] as num?)?.toDouble(),
        unit: data['unit'] as String?,
        note: data['note'] as String?,
        shoppingProduct: data['shopping_product'] as String?,
        allergens: stapleAllergensFrom(data['allergens']),
      );

  Map<String, dynamic> toMap() => {
    if (isOwn) 'own': true,
    if (hidden) 'hidden': true,
    if (name != null) 'name': name,
    if (category != null) 'category': category!.name,
    if (quantityPerPortion != null) 'quantity_per_portion': quantityPerPortion,
    if (unit != null) 'unit': unit,
    if (note != null) 'note': note,
    if (shoppingProduct != null) 'shopping_product': shoppingProduct,
    if (allergens != null) 'allergens': allergens,
  };

  StapleOverride copyWith({bool? hidden}) => StapleOverride(
    id: id,
    isOwn: isOwn,
    hidden: hidden ?? this.hidden,
    name: name,
    category: category,
    quantityPerPortion: quantityPerPortion,
    unit: unit,
    note: note,
    shoppingProduct: shoppingProduct,
    allergens: allergens,
  );

  /// Une garniture propre à l'utilisateur, ou `null` si les champs manquent.
  MealStaple? asOwnStaple() {
    if (!isOwn) return null;
    final n = name?.trim() ?? '';
    final q = quantityPerPortion;
    if (n.isEmpty || q == null || q <= 0) return null;
    return MealStaple(
      id: id,
      name: n,
      category: category ?? StapleCategory.autre,
      quantityPerPortion: q,
      unit: unit ?? 'g',
      note: note ?? '',
      shoppingProduct: shoppingProduct ?? '',
      source: 'user',
      allergens: allergens,
    );
  }
}

/// Une garniture telle qu'un utilisateur la voit : la base, ses retouches, ou
/// la sienne.
class UserStaple {
  final MealStaple staple;

  /// La garniture du référentiel avant retouche ; `null` pour une garniture
  /// propre à l'utilisateur. Sert à ne stocker que ce qui diffère.
  final MealStaple? base;

  /// Créée par l'utilisateur, absente du référentiel.
  final bool isOwn;

  /// Une garniture de base dont au moins une valeur a été changée.
  final bool isOverridden;

  /// Masquée par l'utilisateur : elle ne lui sera pas proposée.
  final bool hidden;

  const UserStaple({
    required this.staple,
    this.base,
    required this.isOwn,
    required this.isOverridden,
    required this.hidden,
  });
}

/// Lit la carte `entries` du document de retouches d'un utilisateur.
///
/// Une entrée qui n'est pas une carte est ignorée : un document abîmé à la
/// main ne doit pas rendre toutes les garnitures illisibles.
Map<String, StapleOverride> parseStapleOverrides(Map<String, dynamic>? data) {
  final entries = data?['entries'];
  if (entries is! Map) return const {};
  return {
    for (final e in entries.entries)
      if (e.value is Map)
        e.key.toString(): StapleOverride.fromMap(
          e.key.toString(),
          Map<String, dynamic>.from(e.value as Map),
        ),
  };
}

/// Le référentiel de base vu à travers les retouches d'un utilisateur.
///
/// Une garniture de base désactivée par l'admin disparaît pour tout le monde,
/// retouche ou non. Une retouche dont la garniture de base n'existe plus est
/// ignorée, sauf si elle est une garniture propre à l'utilisateur.
List<UserStaple> mergeStaples(
  Iterable<MealStaple> base,
  Map<String, StapleOverride> overrides,
) {
  final out = <UserStaple>[];
  final baseIds = <String>{};
  for (final b in base) {
    if (!b.active) continue;
    baseIds.add(b.id);
    final o = overrides[b.id];
    if (o == null) {
      out.add(
        UserStaple(
          staple: b,
          base: b,
          isOwn: false,
          isOverridden: false,
          hidden: false,
        ),
      );
      continue;
    }
    out.add(
      UserStaple(
        staple: b.applying(o),
        base: b,
        isOwn: false,
        isOverridden: o.changesFields,
        hidden: o.hidden,
      ),
    );
  }
  for (final e in overrides.entries) {
    if (baseIds.contains(e.key)) continue;
    final own = e.value.asOwnStaple();
    if (own == null) continue;
    out.add(
      UserStaple(
        staple: own,
        isOwn: true,
        isOverridden: false,
        hidden: e.value.hidden,
      ),
    );
  }
  out.sort(compareStaples);
  return out;
}

/// Par famille, puis par rang, puis par nom.
int compareStaples(UserStaple a, UserStaple b) {
  final byCategory = a.staple.category.index.compareTo(b.staple.category.index);
  if (byCategory != 0) return byCategory;
  final byOrder = a.staple.sortOrder.compareTo(b.staple.sortOrder);
  if (byOrder != 0) return byOrder;
  return a.staple.name.toLowerCase().compareTo(b.staple.name.toLowerCase());
}

/// Un identifiant depuis un nom : minuscules, sans accent, `_` entre les mots.
///
/// « Pâtes fraîches » → `pates_fraiches`. Vide si le nom ne contient aucune
/// lettre ni chiffre.
String stapleIdFromName(String name) {
  const accents = {
    'à': 'a',
    'â': 'a',
    'ä': 'a',
    'á': 'a',
    'ç': 'c',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'î': 'i',
    'ï': 'i',
    'í': 'i',
    'ô': 'o',
    'ö': 'o',
    'ó': 'o',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ú': 'u',
    'ÿ': 'y',
    'œ': 'oe',
    'æ': 'ae',
  };
  final buffer = StringBuffer();
  for (final rune in name.toLowerCase().runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(accents[ch] ?? ch);
  }
  return buffer
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}
