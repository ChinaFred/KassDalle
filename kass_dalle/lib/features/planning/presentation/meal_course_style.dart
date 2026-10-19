import 'package:flutter/material.dart';

import '../domain/meal_component.dart';

/// L'icône d'un service de menu, d'après son rôle : un service « à choisir »
/// porte celle de son type, pas le bol des garnitures.
IconData courseRoleIcon(MealComponentRole role) => switch (role) {
  MealComponentRole.entree => Icons.soup_kitchen_outlined,
  MealComponentRole.plat => Icons.restaurant_outlined,
  MealComponentRole.sorbet => Icons.icecream_outlined,
  MealComponentRole.dessert => Icons.cake_outlined,
  MealComponentRole.accompagnement => Icons.rice_bowl_outlined,
  MealComponentRole.fromage ||
  MealComponentRole.autre => Icons.room_service_outlined,
};

/// Ce que le lecteur d'écran annonce pour [Choisir] : « Choisir le fromage »,
/// « Choisir l'entrée », « Choisir : Trou normand » pour un service « Autre ».
String chooseCourseSemanticLabel(MealComponentRole role, String typeLabel) =>
    switch (role) {
      MealComponentRole.entree => 'Choisir l\'entrée',
      MealComponentRole.plat => 'Choisir le plat',
      MealComponentRole.sorbet => 'Choisir le sorbet',
      MealComponentRole.fromage => 'Choisir le fromage',
      MealComponentRole.dessert => 'Choisir le dessert',
      MealComponentRole.accompagnement => 'Choisir l\'accompagnement',
      MealComponentRole.autre => 'Choisir : $typeLabel',
    };

/// Le bouton [Choisir] d'un service vide, avec son libellé pour le lecteur
/// d'écran.
class ChooseCourseButton extends StatelessWidget {
  final MealComponentRole role;
  final String typeLabel;
  final VoidCallback? onPressed;
  final bool compact;

  const ChooseCourseButton({
    super.key,
    required this.role,
    required this.typeLabel,
    required this.onPressed,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: compact
        ? TextButton.styleFrom(visualDensity: VisualDensity.compact)
        : null,
    child: Text(
      'Choisir',
      semanticsLabel: chooseCourseSemanticLabel(role, typeLabel),
    ),
  );
}
