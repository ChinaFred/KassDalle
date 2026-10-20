import 'package:flutter/material.dart';

/// Fond et texte d'une pastille de note, tirés du thème.
///
/// Trois paliers, qui suivent le thème clair comme le sombre :
/// - 8 à 10 : `primaryContainer` / `onPrimaryContainer` ;
/// - 5 à 7 : `secondaryContainer` / `onSecondaryContainer` ;
/// - 0 à 4 : `errorContainer` / `onErrorContainer`.
///
/// Les paires `container` / `onContainer` de Material 3 garantissent un
/// contraste d'au moins 4,5:1 (test `recipe_pills_test.dart`).
({Color background, Color foreground}) ratingColors(
  int rating,
  ColorScheme cs,
) {
  if (rating >= 8) {
    return (background: cs.primaryContainer, foreground: cs.onPrimaryContainer);
  }
  if (rating >= 5) {
    return (
      background: cs.secondaryContainer,
      foreground: cs.onSecondaryContainer,
    );
  }
  return (background: cs.errorContainer, foreground: cs.onErrorContainer);
}

/// Libellé de la pastille de note, pour l'infobulle et le lecteur d'écran.
///
/// [editable] ajoute l'action : « Modifier » ou « Noter cette recette ».
/// Sans action (liste, recherche), la pastille ne fait que décrire.
String ratingBadgeLabel(int? rating, {required bool editable}) {
  if (rating == null) {
    return editable
        ? 'Pas encore notée. Noter cette recette'
        : 'Pas encore notée';
  }
  final base = 'Ma note : $rating sur 10';
  return editable ? '$base. Modifier' : base;
}
