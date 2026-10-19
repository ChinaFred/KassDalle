import '../../../core/app_links.dart';
import 'meal_component.dart';
import 'meal_composition.dart';
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
/// [components] : ce qui accompagne le plat — une ligne chacun, avec la
/// quantité pour les parts prévues et, pour une recette, son lien.
/// [details] sont les lignes propres à l'écran appelant — temps de
/// préparation, ingrédients — placées entre le lien et la signature.
String buildCalendarDescription({
  String? recipeLocation,
  List<MealComponent> components = const [],
  int? portions,
  List<String> details = const [],
}) {
  final componentLines = componentCalendarLines(components, portions: portions);
  final blocks = <String>[
    if (recipeLocation != null) '📖 Recette : ${appWebLink(recipeLocation)}',
    if (componentLines.isNotEmpty) componentLines.join('\n'),
    if (details.isNotEmpty) details.join('\n'),
    kCalendarSignature,
  ];
  return blocks.join('\n\n');
}

/// Une ligne par composant : « Accompagnement : Riz · 280 g pour 4 parts »,
/// et le lien de la fiche quand c'est une recette. Un service de menu prend
/// son type (« Trou normand » pour un service « Autre » nommé) ; un service
/// vide se lit « Fromage : à choisir ».
List<String> componentCalendarLines(
  Iterable<MealComponent> components, {
  int? portions,
}) {
  final lines = <String>[];
  for (final c in components) {
    final label = c.isEmptyCourse ? 'à choisir' : c.label;
    final buffer = StringBuffer('${c.courseTypeLabel} : $label');
    final total = c.totalQuantityFor(portions);
    if (total != null) {
      final n = (portions ?? 0) > 0 ? portions! : 1;
      buffer.write(
        ' · ${formatComponentQuantity(total, c.unit ?? 'g')}'
        ' pour $n part${n > 1 ? 's' : ''}',
      );
      final note = c.note?.trim() ?? '';
      if (note.isNotEmpty) buffer.write(' ($note)');
    }
    if (c.isRecipe) {
      buffer.write(
        ' — 📖 ${appWebLink(recipeLocationFor(recipeId: c.recipeId!))}',
      );
    }
    lines.add(buffer.toString());
  }
  return lines;
}

/// « 280 g », « 4 pièces », « 0,5 g » — sans l'unité répétée.
String formatComponentQuantity(double quantity, String unit) {
  final isWhole = quantity == quantity.truncateToDouble();
  final number = isWhole
      ? quantity.toInt().toString()
      : quantity.toStringAsFixed(1).replaceAll('.', ',');
  if (unit == 'pièce') return quantity > 1 ? '$number pièces' : '$number pièce';
  return '$number $unit';
}

/// Description d'un repas planifié : le lien vers sa recette, ouvert pour ses
/// parts et son jour de préparation, et ses accompagnements — pour un menu,
/// ses services dans l'ordre, chaque plat suivi des siens.
String mealCalendarDescription(PlannedMeal meal) => buildCalendarDescription(
  recipeLocation: mealRecipeLocation(meal),
  components: MealComposition.ofMeal(
    meal,
  ).toComponents(mainTitle: meal.recipeTitre),
  portions: meal.portionsForComponents,
);
