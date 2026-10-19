/// Un composant d'un repas planifié, en plus du plat principal.
///
/// Un repas n'est pas une recette : la blanquette se sert avec du riz, et le
/// riz n'a pas de recette. Un composant est soit une **garniture** du
/// référentiel (riz, salade verte, yaourt), soit une **recette**, soit un
/// **texte libre** saisi à la main. Le plat principal reste dans `recipe_id` :
/// les écrans qui ne connaissent pas les composants continuent de le voir.
///
/// Une garniture est **figée** au moment du choix — nom, part par personne,
/// produit de courses — : le repas dit ce qu'on a décidé ce jour-là, même si
/// le référentiel change ensuite.
library;

import '../../recipes/domain/recipe.dart';
import 'meal_staple.dart';

/// Rôle d'un composant dans le repas.
///
/// Le plat principal reste porté par le repas lui-même (`recipe_id`). Les
/// rôles [plat], [sorbet], [fromage] et [autre] servent aux services d'un
/// menu. Un rôle que cette version ne connaît pas se lit [autre], et sa
/// valeur d'origine est réécrite telle quelle (voir [MealComponent.roleKey]).
enum MealComponentRole {
  accompagnement,
  entree,
  plat,
  sorbet,
  fromage,
  dessert,
  autre;

  String get label => switch (this) {
    MealComponentRole.accompagnement => 'Accompagnement',
    MealComponentRole.entree => 'Entrée',
    MealComponentRole.plat => 'Plat',
    MealComponentRole.sorbet => 'Sorbet',
    MealComponentRole.fromage => 'Fromage',
    MealComponentRole.dessert => 'Dessert',
    MealComponentRole.autre => 'Autre',
  };

  /// Sans rôle : un accompagnement, seul composant des premiers repas. Un
  /// rôle inconnu se lit [autre], jamais accompagnement : un accompagnement
  /// serait remplacé au prochain changement de plat.
  static MealComponentRole fromKey(String? key) {
    if (key == null || key.isEmpty) return MealComponentRole.accompagnement;
    for (final r in MealComponentRole.values) {
      if (r.name == key) return r;
    }
    return MealComponentRole.autre;
  }

  /// Servi après le plat : sorbet, fromage, dessert.
  bool get isAfterMain =>
      this == MealComponentRole.sorbet ||
      this == MealComponentRole.fromage ||
      this == MealComponentRole.dessert;
}

class MealComponent {
  final MealComponentRole role;

  /// Valeur de `role` lue en base quand cette version ne la connaît pas.
  /// Elle est réécrite telle quelle : une version plus ancienne de
  /// l'application ne change pas le service posé par une version plus récente.
  final String? roleKey;

  /// Le plat qu'accompagne ce composant, dans un menu à plusieurs plats.
  /// `null` : le plat principal du repas (`recipe_id`).
  final String? sideOf;

  /// Champs lus en base que cette version ne connaît pas, réécrits tels
  /// quels. Un téléphone qui n'a pas encore la mise à jour retire ou ajoute
  /// un accompagnement sans effacer ce qu'une version récente a posé.
  final Map<String, dynamic> extra;

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

  /// Ce qu'apporte un texte libre, coché à la main : `feculent`, `legume`
  /// (`provides`). Vide : « apport inconnu ». Une garniture dit son apport
  /// par sa famille, une recette par son `contains` : le champ ne sert qu'au
  /// texte libre. Une valeur inconnue est gardée telle quelle.
  final List<String> provides;

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
    this.provides = const [],
    this.roleKey,
    this.sideOf,
    this.extra = const {},
  });

  /// Accompagnement du plat principal, celui de `recipe_id`.
  bool get isMainSide =>
      role == MealComponentRole.accompagnement &&
      (sideOf == null || sideOf!.isEmpty);

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
    List<String> provides = const [],
  }) => MealComponent(
    role: role,
    label: label,
    justification: justification,
    provides: provides,
  );

  /// Le même composant, avec un autre apport ([provides]) : « Modifier
  /// l'apport » d'un texte libre.
  MealComponent withProvides(List<String> provides) => MealComponent(
    role: role,
    roleKey: roleKey,
    recipeId: recipeId,
    stapleId: stapleId,
    label: label,
    quantityPerPortion: quantityPerPortion,
    unit: unit,
    shoppingProduct: shoppingProduct,
    note: note,
    justification: justification,
    provides: provides,
    sideOf: sideOf,
    extra: extra,
  );

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

  static const _knownKeys = {
    'role',
    'recipe_id',
    'staple_id',
    'label',
    'quantity_per_portion',
    'unit',
    'shopping_product',
    'note',
    'justification',
    'provides',
    'side_of',
  };

  factory MealComponent.fromMap(Map<String, dynamic> data) {
    final rawRole = data['role'] as String?;
    final role = MealComponentRole.fromKey(rawRole);
    return MealComponent(
      role: role,
      roleKey: rawRole != null && rawRole.isNotEmpty && rawRole != role.name
          ? rawRole
          : null,
      recipeId: data['recipe_id'] as String?,
      stapleId: data['staple_id'] as String?,
      label: data['label'] as String? ?? '',
      quantityPerPortion: (data['quantity_per_portion'] as num?)?.toDouble(),
      unit: data['unit'] as String?,
      shoppingProduct: data['shopping_product'] as String?,
      note: data['note'] as String?,
      justification: data['justification'] as String?,
      provides: [
        if (data['provides'] is List)
          for (final p in data['provides'] as List)
            if (p is String && p.isNotEmpty) p,
      ],
      sideOf: data['side_of'] as String?,
      extra: {
        for (final e in data.entries)
          if (!_knownKeys.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, dynamic> toMap() => {
    ...extra,
    'role': roleKey ?? role.name,
    if (isRecipe) 'recipe_id': recipeId,
    if (isStaple) 'staple_id': stapleId,
    'label': label,
    if (quantityPerPortion != null) 'quantity_per_portion': quantityPerPortion,
    if (unit != null) 'unit': unit,
    if (shoppingProduct != null) 'shopping_product': shoppingProduct,
    if (note != null) 'note': note,
    if (justification != null && justification!.trim().isNotEmpty)
      'justification': justification!.trim(),
    if (provides.isNotEmpty) 'provides': provides,
    if (sideOf != null && sideOf!.isNotEmpty) 'side_of': sideOf,
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

/// [components] où [sides] remplacent les accompagnements du plat principal.
///
/// Changer de plat recompose son accompagnement, et rien d'autre : l'entrée,
/// le dessert et les autres services d'un menu restent en place, dans leur
/// ordre. Les nouveaux accompagnements prennent la place du premier retiré,
/// sinon celle que leur donne [insertMainSide].
///
/// Un premier accompagnement rangé après un sorbet, un fromage ou un dessert
/// — repas anciens `[entrée, dessert, salade]` — ne donne pas sa place : les
/// nouveaux passent alors par [insertMainSide], avant le dessert.
List<MealComponent> replaceMainSides(
  List<MealComponent> components,
  List<MealComponent> sides,
) {
  final at = components.indexWhere((c) => c.isMainSide);
  final kept = [
    for (final c in components)
      if (!c.isMainSide) c,
  ];
  final afterCourseFirst =
      at >= 0 && components.take(at).any((c) => c.role.isAfterMain);
  if (at >= 0 && !afterCourseFirst) {
    return [...kept.take(at), ...sides, ...kept.skip(at)];
  }
  var result = kept;
  for (final s in sides) {
    result = insertMainSide(result, s);
  }
  return result;
}

/// [components] avec [side] ajouté à sa place : avant le premier service qui
/// suit le plat (sorbet, fromage, dessert), sinon après le dernier
/// accompagnement du plat principal, sinon à la fin.
///
/// Le premier service d'après le plat passe avant le dernier accompagnement :
/// les versions antérieures ajoutaient l'accompagnement en fin de liste, et
/// des repas `[entrée, riz, dessert, salade]` existent.
List<MealComponent> insertMainSide(
  List<MealComponent> components,
  MealComponent side,
) {
  var at = components.indexWhere((c) => c.role.isAfterMain);
  if (at < 0) {
    final lastSide = components.lastIndexWhere((c) => c.isMainSide);
    if (lastSide < 0) return [...components, side];
    at = lastSide + 1;
  }
  return [...components.take(at), side, ...components.skip(at)];
}

/// Composants d'un repas déjà enregistré, réécrits par Nouveau planning, qui
/// en montre la première entrée, tous les accompagnements du plat principal
/// et le premier dessert.
///
/// L'entrée et le dessert sont remplacés à leur place par la valeur du
/// créneau, ou retirés quand elle est `null`. Les accompagnements du plat
/// principal sont remplacés par [sides] ([replaceMainSides]) : le créneau
/// porte la liste complète, qu'il ait gardé ceux du repas ou que le plat ait
/// changé. Tout le reste est gardé, dans l'ordre : deuxième entrée, sorbet,
/// fromage, accompagnements d'un autre plat.
List<MealComponent> mergeSlotComponents(
  List<MealComponent> original, {
  MealComponent? starter,
  List<MealComponent> sides = const [],
  MealComponent? dessert,
}) {
  final result = <MealComponent>[];
  var starterDone = false;
  var dessertDone = false;
  for (final c in original) {
    if (!starterDone && c.role == MealComponentRole.entree) {
      starterDone = true;
      if (starter != null) result.add(starter);
    } else if (!dessertDone && c.role == MealComponentRole.dessert) {
      dessertDone = true;
      if (dessert != null) result.add(dessert);
    } else {
      result.add(c);
    }
  }
  var merged = replaceMainSides(result, sides);
  if (!starterDone && starter != null) merged = [starter, ...merged];
  if (!dessertDone && dessert != null) merged = [...merged, dessert];
  return merged;
}
