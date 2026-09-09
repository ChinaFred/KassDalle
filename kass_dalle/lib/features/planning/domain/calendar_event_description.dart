import '../../../core/app_links.dart';
import 'meal_recipe_location.dart';
import 'planned_meal.dart';

/// Dernière ligne de chaque description d'événement.
const kCalendarSignature = 'Repas planifié avec Kass\'Dalle';

/// Description d'un événement Google Calendar pour un repas.
///
/// Le lien vient en premier : c'est ce qu'on touche depuis la notification,
/// une heure avant de cuisiner. Il ouvre la fiche dans le client web, avec les
/// parts et les dates du repas en paramètres — voir [recipeLocationFor].
///
/// C'est une adresse nue, sans balise : Google Calendar la rend cliquable, et
/// les autres agendas qui synchronisent le même compte l'affichent telle
/// quelle au lieu d'une balise HTML brute.
///
/// [details] sont les lignes propres à l'écran appelant — temps de
/// préparation, ingrédients — placées entre le lien et la signature.
String buildCalendarDescription({
  String? recipeLocation,
  List<String> details = const [],
}) {
  final blocks = <String>[
    if (recipeLocation != null) '📖 Recette : ${appWebLink(recipeLocation)}',
    if (details.isNotEmpty) details.join('\n'),
    kCalendarSignature,
  ];
  return blocks.join('\n\n');
}

/// Description d'un repas planifié : le lien vers sa recette, ouvert pour ses
/// parts et son jour de préparation.
String mealCalendarDescription(PlannedMeal meal) =>
    buildCalendarDescription(recipeLocation: mealRecipeLocation(meal));
