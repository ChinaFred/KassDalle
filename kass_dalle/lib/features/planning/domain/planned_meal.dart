import 'package:cloud_firestore/cloud_firestore.dart';

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
    required this.createdAt,
  });

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
    'created_at': Timestamp.fromDate(createdAt),
  };
}
