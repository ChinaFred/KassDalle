import 'meal_prep_context.dart';
import 'planned_meal.dart';

/// Route interne de la fiche recette, avec le contexte du repas en paramètres.
///
/// Le contexte voyage dans l'adresse, sans jamais être écrit sur la recette :
/// les parts, pour préparer la quantité prévue au planning et non celle du
/// texte, et le couple de dates quand le plat se cuisine à l'avance, pour que
/// la fiche parle de conservation et de réchauffage.
///
/// Les parts ne sont ajoutées que si elles diffèrent de celles de la recette :
/// une adresse sans paramètre ouvre la fiche telle qu'elle est écrite.
///
/// La même route sert deux usages : l'écran du planning la pousse dans le
/// routeur, et la description d'un événement Google Calendar la colle derrière
/// l'origine du client web — voir `appWebLink`.
String recipeLocationFor({
  required String recipeId,
  int? targetPortions,
  int? basePortions,
  DateTime? prepDate,
  DateTime? mealDate,
}) {
  final params = <String, String>{};

  if (targetPortions != null &&
      targetPortions > 0 &&
      targetPortions != basePortions) {
    params['portions'] = '$targetPortions';
  }

  if (prepDate != null && mealDate != null) {
    params.addAll(
      MealPrepContext(
        prepDate: prepDate,
        mealDate: mealDate,
      ).toQueryParameters(),
    );
  }

  return Uri(
    path: '/recipes/$recipeId',
    queryParameters: params.isEmpty ? null : params,
  ).toString();
}

/// Route interne de la fiche recette d'un repas planifié, ou null s'il n'a
/// pas de recette — un créneau vide, ou un repas saisi en texte libre.
String? mealRecipeLocation(PlannedMeal meal) {
  final recipeId = meal.recipeId;
  if (recipeId == null || recipeId.isEmpty) return null;
  return recipeLocationFor(
    recipeId: recipeId,
    targetPortions: meal.targetPortions,
    basePortions: meal.basePortions,
    prepDate: meal.prepDate,
    mealDate: meal.plannedAt,
  );
}
