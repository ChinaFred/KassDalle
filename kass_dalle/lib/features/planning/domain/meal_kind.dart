/// Un repas est un plat ou un menu (`planned_meals.meal_kind`, v0.24.16).
///
/// Un **plat** : la recette du repas et ses accompagnements. Un **menu** : une
/// suite ordonnée de services — entrée, plat, sorbet, fromage, dessert,
/// « Autre » —, dix au plus, dont le plat principal.
library;

import 'meal_component.dart';

enum MealKind {
  plat,
  menu;

  /// Valeur stockée : `plat` ou `menu`.
  String get key => name;

  String get label => switch (this) {
    MealKind.plat => 'Plat',
    MealKind.menu => 'Menu',
  };

  /// Depuis la valeur stockée ; `null` si absente ou inconnue.
  static MealKind? fromKey(Object? raw) {
    for (final k in MealKind.values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

/// La nature d'un repas, lue de ses composants quand `meal_kind` manque : un
/// composant d'un autre rôle qu'accompagnement en fait un menu.
///
/// [stored] ne l'emporte que pour dire « menu » : un repas noté `plat` qui
/// porte une entrée — posée par une version antérieure de Nouveau planning,
/// qui ne connaît pas `meal_kind` — se lit menu, pour que l'entrée reste
/// visible.
MealKind effectiveMealKind(
  Iterable<MealComponent> components, {
  MealKind? stored,
}) {
  if (stored == MealKind.menu) return MealKind.menu;
  return components.any((c) => c.role != MealComponentRole.accompagnement)
      ? MealKind.menu
      : MealKind.plat;
}
