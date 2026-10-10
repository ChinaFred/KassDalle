import 'package:cloud_firestore/cloud_firestore.dart';

import 'meal_choice_source.dart';
import 'meal_component.dart';

/// Repas planifié, stocké dans Firestore sous `planned_meals/{id}`.
class PlannedMeal {
  final String id;
  final String uid;
  final String? recipeId;
  final String recipeTitre;
  final DateTime plannedAt;

  /// Durée totale en minutes (prépa + cuisson).
  final int durationMinutes;

  /// Durée de préparation en minutes (optionnel).
  final int? prepMinutes;

  /// Durée de cuisson en minutes (optionnel).
  final int? cookMinutes;

  /// Portions de base de la recette au moment de la planification.
  final int? basePortions;

  /// Portions souhaitées pour ce repas planifié.
  final int? targetPortions;

  /// Jour où le plat est préparé, quand ce n'est pas le jour du repas.
  ///
  /// Porte toute la question de la conservation : c'est l'écart entre cette
  /// date et [plannedAt] qui décide du réfrigérateur ou du congélateur.
  /// Calculée à la planification, elle se perdait jusqu'ici à l'enregistrement.
  final DateTime? prepDate;

  /// Pourquoi ce plat, ce jour-là.
  ///
  /// La justification appartient au REPAS et non à la recette : elle parle de
  /// cette date, de la contrainte de ce jour et de la variété du cycle. Écrite
  /// sur la recette, elle aurait menti au prochain qui la planifie.
  ///
  /// Elle était produite à chaque génération, affichée dans l'écran de
  /// planification, puis perdue à la validation — l'écran du planning, celui
  /// qu'on relit ensuite, n'en gardait rien.
  final String? justification;

  /// Recettes écartées de ce repas — par « Changer la recette », « Vider le
  /// créneau » ou une nouvelle suggestion. L'IA ne les repropose pas ici.
  ///
  /// Elles appartiennent au repas, pas au profil : écarter un plat un mardi
  /// ne dit rien du samedi suivant.
  final List<String> dismissedRecipeIds;

  /// Ce qui accompagne le plat : une garniture ou une recette
  /// d'accompagnement, plus tard une entrée ou un dessert.
  ///
  /// Le plat lui-même n'y figure pas : il reste dans [recipeId], et les
  /// écrans qui ne connaissent pas les composants continuent de le voir.
  /// Choisis par le programme depuis ce que le plat n'apporte pas — jamais
  /// par le modèle au moment du planning.
  final List<MealComponent> components;

  /// Qui a choisi la recette : l'IA, les règles de Kass'Dalle, une
  /// conception IA, ou l'utilisateur. `null` sur un repas antérieur à ce
  /// champ : l'écran n'affiche alors pas de ligne d'origine.
  final MealChoiceSource? choiceSource;

  final DateTime createdAt;

  const PlannedMeal({
    required this.id,
    required this.uid,
    this.recipeId,
    required this.recipeTitre,
    required this.plannedAt,
    required this.durationMinutes,
    this.prepMinutes,
    this.cookMinutes,
    this.basePortions,
    this.targetPortions,
    this.prepDate,
    this.justification,
    this.dismissedRecipeIds = const [],
    this.components = const [],
    this.choiceSource,
    required this.createdAt,
  });

  /// Nombre de parts qui compte pour les garnitures : celles visées, sinon
  /// celles de la recette.
  int? get portionsForComponents =>
      (targetPortions ?? 0) > 0 ? targetPortions : basePortions;

  factory PlannedMeal.fromFirestore(String id, Map<String, dynamic> data) {
    return PlannedMeal(
      id: id,
      uid: data['uid'] as String,
      recipeId: data['recipe_id'] as String?,
      recipeTitre: data['recipe_titre'] as String? ?? '',
      plannedAt: (data['planned_at'] as Timestamp).toDate(),
      durationMinutes: data['duration_minutes'] as int? ?? 0,
      prepMinutes: data['prep_minutes'] as int?,
      cookMinutes: data['cook_minutes'] as int?,
      basePortions: data['base_portions'] as int?,
      targetPortions: data['target_portions'] as int?,
      prepDate: (data['prep_date'] as Timestamp?)?.toDate(),
      justification: data['justification'] as String?,
      dismissedRecipeIds: List<String>.from(
        data['dismissed_recipe_ids'] as List? ?? const [],
      ),
      components: MealComponent.listFromFirestore(data['components']),
      choiceSource: MealChoiceSource.fromValue(data['choice_source']),
      createdAt: (data['created_at'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'uid': uid,
    'recipe_id': recipeId,
    'recipe_titre': recipeTitre,
    'planned_at': Timestamp.fromDate(plannedAt),
    'duration_minutes': durationMinutes,
    if (prepMinutes != null) 'prep_minutes': prepMinutes,
    if (cookMinutes != null) 'cook_minutes': cookMinutes,
    if (basePortions != null) 'base_portions': basePortions,
    if (targetPortions != null) 'target_portions': targetPortions,
    if (prepDate != null) 'prep_date': Timestamp.fromDate(prepDate!),
    if (justification != null && justification!.trim().isNotEmpty)
      'justification': justification!.trim(),
    if (dismissedRecipeIds.isNotEmpty)
      'dismissed_recipe_ids': dismissedRecipeIds,
    if (components.isNotEmpty)
      'components': [for (final c in components) c.toMap()],
    if (choiceSource != null) 'choice_source': choiceSource!.value,
    'created_at': Timestamp.fromDate(createdAt),
  };
}
