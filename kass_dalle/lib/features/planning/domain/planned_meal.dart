import 'package:cloud_firestore/cloud_firestore.dart';

import 'meal_choice_source.dart';
import 'meal_component.dart';
import 'meal_kind.dart';
import 'planning_criteria.dart';
import 'relaxed_criteria.dart';

/// Repas planifié, stocké dans Firestore sous `planned_meals/{id}`.
class PlannedMeal {
  final String id;

  /// Le cuisinier : le titulaire du planning personnel, ou le propriétaire du
  /// groupe pour un repas de groupe. Figé à la création.
  final String uid;

  /// Le groupe familial dont ce repas fait partie du planning, ou `null` pour
  /// un repas du planning personnel de [uid] (`group_id`). Absent sur les
  /// repas antérieurs au planning de groupe : ils sont personnels. Figé à la
  /// création, comme [uid] : un repas ne change pas de planning.
  final String? groupId;
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

  /// Ce qui accompagne le plat — garnitures, recettes d'accompagnement,
  /// textes libres —, et pour un menu la suite ordonnée de ses services,
  /// accompagnements compris (voir `MealComposition`).
  ///
  /// Le plat lui-même reste dans [recipeId], et les écrans qui ne
  /// connaissent pas les composants continuent de le voir. Dans un menu, sa
  /// place est marquée par un composant `{role: plat, id: 'main'}` sans
  /// recette. Les accompagnements sont choisis par le programme depuis ce que
  /// le plat n'apporte pas — jamais par le modèle au moment du planning.
  final List<MealComponent> components;

  /// Plat ou menu (`meal_kind`, v0.24.16). `null` sur un repas antérieur :
  /// la nature se déduit alors des composants ([kind]).
  final MealKind? mealKind;

  /// Qui a choisi la recette : l'IA, les règles de Kass'Dalle, une
  /// conception IA, ou l'utilisateur. `null` sur un repas antérieur à ce
  /// champ : l'écran n'affiche alors pas de ligne d'origine.
  final MealChoiceSource? choiceSource;

  /// Critères que le serveur a relâchés pour choisir ce plat
  /// (`relaxed_criteria` : `in_cycle`, `variety_window`, `rating`), posés par
  /// Nouveau planning et « Autre suggestion ». Affichés dans la ligne
  /// d'origine : « déjà servi dans ce cycle, faute d'autre choix ». Retirés
  /// quand le plat change à la main. Une clé inconnue est gardée telle quelle.
  final List<String> relaxedCriteria;

  /// Critères que le repas ne tient pas, ou n'a pas pu vérifier
  /// (`unmet_criteria`, v0.24.18) : préférence relâchée (« 1 h 10, au-delà
  /// des 45 min demandées »), exclusion sans candidat (« Aucun dessert sans
  /// fruits à coque. »), allergènes non vérifiés. Phrases du serveur, posées
  /// par Nouveau planning et « Autre suggestion », retirées avec le plat
  /// changé à la main. Une entrée illisible est ignorée.
  final List<UnmetCriterion> unmetCriteria;

  final DateTime createdAt;

  /// Champs lus en base que cette version ne connaît pas. Une valeur de
  /// `meal_kind` inconnue y reste aussi, réécrite telle quelle. Nouveau
  /// planning réécrit le
  /// document entier : sans eux, un téléphone pas encore à jour effacerait
  /// ce qu'une version récente a posé.
  final Map<String, dynamic> extra;

  const PlannedMeal({
    required this.id,
    required this.uid,
    this.groupId,
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
    this.mealKind,
    this.choiceSource,
    this.relaxedCriteria = const [],
    this.unmetCriteria = const [],
    required this.createdAt,
    this.extra = const {},
  });

  static const _knownKeys = {
    'uid',
    'group_id',
    'recipe_id',
    'recipe_titre',
    'planned_at',
    'duration_minutes',
    'prep_minutes',
    'cook_minutes',
    'base_portions',
    'target_portions',
    'prep_date',
    'justification',
    'dismissed_recipe_ids',
    'components',
    'meal_kind',
    'choice_source',
    'relaxed_criteria',
    'unmet_criteria',
    'created_at',
  };

  /// Un repas du planning d'un groupe, et non du planning personnel.
  bool get isGroupMeal => groupId != null;

  /// Plat ou menu : [mealKind], ou déduit des composants
  /// ([effectiveMealKind]).
  MealKind get kind => effectiveMealKind(components, stored: mealKind);

  /// Nombre de parts qui compte pour les garnitures : celles visées, sinon
  /// celles de la recette.
  int? get portionsForComponents =>
      (targetPortions ?? 0) > 0 ? targetPortions : basePortions;

  factory PlannedMeal.fromFirestore(String id, Map<String, dynamic> data) {
    return PlannedMeal(
      id: id,
      uid: data['uid'] as String,
      groupId: groupIdFrom(data['group_id']),
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
      mealKind: MealKind.fromKey(data['meal_kind']),
      choiceSource: MealChoiceSource.fromValue(data['choice_source']),
      relaxedCriteria: relaxedKeysFrom(data['relaxed_criteria']),
      unmetCriteria: UnmetCriterion.listFrom(data['unmet_criteria']),
      createdAt: (data['created_at'] as Timestamp).toDate(),
      extra: {
        for (final e in data.entries)
          if (!_knownKeys.contains(e.key) ||
              (e.key == 'meal_kind' && MealKind.fromKey(e.value) == null))
            e.key: e.value,
      },
    );
  }

  /// Lit `group_id` : une chaîne non vide, sinon `null` (repas personnel).
  static String? groupIdFrom(Object? raw) =>
      raw is String && raw.isNotEmpty ? raw : null;

  /// `group_id` est toujours écrit, `null` pour un repas personnel : un
  /// planning personnel partagé se lit par `uid == propriétaire` et
  /// `group_id == null`, et une égalité à `null` ne trouve pas un document
  /// sans le champ. Réécrire un repas le repose à l'identique, ce que les
  /// règles exigent (`group_id` figé).
  Map<String, dynamic> toFirestore() => {
    ...extra,
    'uid': uid,
    'group_id': groupId,
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
    if (mealKind != null) 'meal_kind': mealKind!.key,
    if (choiceSource != null) 'choice_source': choiceSource!.value,
    if (relaxedCriteria.isNotEmpty) 'relaxed_criteria': relaxedCriteria,
    if (unmetCriteria.isNotEmpty)
      'unmet_criteria': [for (final u in unmetCriteria) u.toMap()],
    'created_at': Timestamp.fromDate(createdAt),
  };
}
