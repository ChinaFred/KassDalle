/// Reprendre dans un cycle en composition les repas déjà au planning.
///
/// Un jour déjà planifié n'est pas un créneau vide. Le proposer comme tel
/// demande à l'IA un repas pour une date prise, puis oblige l'utilisateur à
/// choisir entre remplacer et doubler ce qui existait.
library;

import 'dart:convert';

import 'planned_meal.dart';

/// Le repas déjà au planning de chaque créneau de [slotDates], par index.
///
/// Un créneau porte un repas par jour : le premier de la journée. Un second
/// repas le même jour n'a pas de créneau et n'apparaît pas ici ; il reste tel
/// quel dans le planning.
Map<int, PlannedMeal> registeredMealsBySlot({
  required List<DateTime> slotDates,
  required Iterable<PlannedMeal> meals,
}) {
  final firstOfDay = <DateTime, PlannedMeal>{};
  for (final meal in meals) {
    final day = _dayOf(meal.plannedAt);
    final current = firstOfDay[day];
    if (current == null || _comesBefore(meal, current)) firstOfDay[day] = meal;
  }
  final bySlot = <int, PlannedMeal>{};
  for (var i = 0; i < slotDates.length; i++) {
    final meal = firstOfDay[_dayOf(slotDates[i])];
    if (meal != null) bySlot[i] = meal;
  }
  return bySlot;
}

/// L'empreinte de ce que « Valider » écrirait pour [meal].
///
/// Prise juste après la reprise d'un repas sur l'écran, puis comparée à la
/// validation : tant qu'elle n'a pas bougé, le repas n'a pas été touché ici.
/// Le réécrire depuis un écran qui ne connaît qu'une entrée, un
/// accompagnement et un dessert lui ferait perdre ce que l'écran ne montre pas.
///
/// L'identifiant, le propriétaire et la date de création n'y entrent pas : ils
/// ne changent pas avec ce que l'utilisateur fait sur l'écran.
String plannedMealContentKey(PlannedMeal meal) => jsonEncode([
  meal.recipeId,
  meal.recipeTitre,
  meal.plannedAt.toIso8601String(),
  meal.targetPortions,
  meal.prepDate?.toIso8601String(),
  meal.justification,
  meal.dismissedRecipeIds,
  [for (final c in meal.components) c.toMap()],
  meal.mealKind?.key,
  meal.choiceSource?.value,
  meal.relaxedCriteria,
  // Un champ inconnu d'une version plus récente peut porter une date : il
  // entre dans la clé sous sa forme texte, sans faire échouer l'encodage.
], toEncodable: (o) => o.toString());

DateTime _dayOf(DateTime d) => DateTime(d.year, d.month, d.day);

bool _comesBefore(PlannedMeal a, PlannedMeal b) {
  final byTime = a.plannedAt.compareTo(b.plannedAt);
  return byTime != 0 ? byTime < 0 : a.id.compareTo(b.id) < 0;
}
