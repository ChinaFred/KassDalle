/// Un composant d'un repas planifié, en plus du plat.
///
/// Un repas n'est pas une recette : la blanquette se sert avec du riz, et le
/// riz n'a pas de recette. Un composant est soit une **garniture** du
/// référentiel (riz, salade verte, yaourt), soit une **recette** de rôle
/// accompagnement, entrée ou dessert, soit un **texte libre** saisi à la main. Le plat, lui, reste dans `recipe_id` :
/// les écrans qui ne connaissent pas les composants continuent de le voir.
///
/// Une garniture est **figée** au moment du choix — nom, part par personne,
/// produit de courses — : le repas dit ce qu'on a décidé ce jour-là, même si
/// le référentiel change ensuite.
library;

import '../../recipes/domain/recipe.dart';
import 'meal_staple.dart';

/// Rôle d'un composant dans le repas. Le plat n'en est pas un : il est porté
/// par le repas lui-même.
enum MealComponentRole {
  accompagnement,
  entree,
  dessert;

  String get label => switch (this) {
    MealComponentRole.accompagnement => 'Accompagnement',
    MealComponentRole.entree => 'Entrée',
    MealComponentRole.dessert => 'Dessert',
  };

  static MealComponentRole fromKey(String? key) =>
      MealComponentRole.values.firstWhere(
        (r) => r.name == key,
        orElse: () => MealComponentRole.accompagnement,
      );
}

class MealComponent {
  final MealComponentRole role;

  /// Une recette d'accompagnement, d'entrée ou de dessert.
  final String? recipeId;

  /// Une garniture du référentiel, ou propre à l'utilisateur.
  final String? stapleId;

  /// Nom affiché : « Riz », « Frites maison ».
  final String label;

  /// Pour une garniture : la part par personne, figée au choix.
  final double? quantityPerPortion;

  /// `g`, `ml` ou `pièce`, pour une garniture.
  final String? unit;

  /// Nom du produit sur la liste de courses ; vide = [label].
  final String? shoppingProduct;

  /// « poids sec », pour une garniture.
  final String? note;

  /// Pourquoi ce composant : « le plat n'apporte pas de féculent ».
  final String? justification;

  const MealComponent({
    required this.role,
    this.recipeId,
    this.stapleId,
    required this.label,
    this.quantityPerPortion,
    this.unit,
    this.shoppingProduct,
    this.note,
    this.justification,
  });

  bool get isRecipe => recipeId != null && recipeId!.isNotEmpty;
  bool get isStaple => stapleId != null && stapleId!.isNotEmpty;

  /// Identifiant de ce qui est posé, recette ou garniture, pour ne pas le
  /// reposer deux fois dans un cycle.
  String get sourceId => isRecipe ? recipeId! : (stapleId ?? label);

  String get effectiveShoppingProduct {
    final p = shoppingProduct?.trim() ?? '';
    return p.isEmpty ? label : p;
  }

  /// Une garniture figée telle qu'elle est dans le référentiel de l'utilisateur.
  factory MealComponent.staple(
    MealStaple staple, {
    MealComponentRole role = MealComponentRole.accompagnement,
    String? justification,
  }) => MealComponent(
    role: role,
    stapleId: staple.id,
    label: staple.name,
    quantityPerPortion: staple.quantityPerPortion,
    unit: staple.unit,
    shoppingProduct: staple.shoppingProduct.trim().isEmpty
        ? null
        : staple.shoppingProduct.trim(),
    note: staple.note.trim().isEmpty ? null : staple.note.trim(),
    justification: justification,
  );

  /// Une recette d'accompagnement, d'entrée ou de dessert.
  factory MealComponent.recipe(
    Recipe recipe, {
    MealComponentRole role = MealComponentRole.accompagnement,
    String? justification,
  }) => MealComponent(
    role: role,
    recipeId: recipe.id,
    label: recipe.titre,
    justification: justification,
  );

  /// Un texte libre saisi à la main : « Frites maison » quand ni garniture ni
  /// recette ne convient. Ni quantité, ni produit de courses : il s'affiche,
  /// il ne s'achète pas.
  factory MealComponent.free(
    String label, {
    MealComponentRole role = MealComponentRole.accompagnement,
    String? justification,
  }) => MealComponent(role: role, label: label, justification: justification);

  /// Ni recette ni garniture : un texte libre.
  bool get isFree => !isRecipe && !isStaple;

  /// « 70 g par part », « 1 pièce par part » ; rien pour une recette.
  String? get quantityLabel {
    final q = quantityPerPortion;
    if (q == null || q <= 0) return null;
    return '${formatStapleQuantity(q, unit ?? 'g')} par part';
  }

  /// Quantité totale pour [portions] parts, pour la liste de courses.
  ///
  /// Sans nombre de parts connu, une seule part : mieux vaut une ligne
  /// approximative qu'une garniture qui disparaît de la liste.
  double? totalQuantityFor(int? portions) {
    final q = quantityPerPortion;
    if (q == null || q <= 0) return null;
    final n = (portions ?? 0) > 0 ? portions! : 1;
    return q * n;
  }

  factory MealComponent.fromMap(Map<String, dynamic> data) => MealComponent(
    role: MealComponentRole.fromKey(data['role'] as String?),
    recipeId: data['recipe_id'] as String?,
    stapleId: data['staple_id'] as String?,
    label: data['label'] as String? ?? '',
    quantityPerPortion: (data['quantity_per_portion'] as num?)?.toDouble(),
    unit: data['unit'] as String?,
    shoppingProduct: data['shopping_product'] as String?,
    note: data['note'] as String?,
    justification: data['justification'] as String?,
  );

  Map<String, dynamic> toMap() => {
    'role': role.name,
    if (isRecipe) 'recipe_id': recipeId,
    if (isStaple) 'staple_id': stapleId,
    'label': label,
    if (quantityPerPortion != null) 'quantity_per_portion': quantityPerPortion,
    if (unit != null) 'unit': unit,
    if (shoppingProduct != null) 'shopping_product': shoppingProduct,
    if (note != null) 'note': note,
    if (justification != null && justification!.trim().isNotEmpty)
      'justification': justification!.trim(),
  };

  /// Lit une liste Firestore ; une entrée qui n'est pas une carte est ignorée.
  static List<MealComponent> listFromFirestore(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) MealComponent.fromMap(Map<String, dynamic>.from(e)),
    ];
  }
}

/// « Riz · Salade verte » — les composants en une ligne, pour la liste.
String componentsSummary(Iterable<MealComponent> components) =>
    components.map((c) => c.label).join(' · ');
