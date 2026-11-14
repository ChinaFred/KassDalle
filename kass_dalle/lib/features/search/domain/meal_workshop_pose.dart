/// « Poser dans le planning » : le repas planifié bâti depuis le menu de
/// l'atelier repas et ses lignes de figement, ce qui empêche la pose, et les
/// phrases de la boîte et du pied du panneau.
///
/// Fonctions pures, sans Firebase, testées dans
/// `test/meal_workshop_pose_test.dart`. Aucun appel d'IA : une pose est une
/// écriture `planned_meals` par le dépôt du planning, précédée de deux
/// lectures (la recette du plat principal, les repas du jour visé).
library;

import '../../../core/utils/short_date_format.dart';
import '../../planning/domain/meal_choice_source.dart';
import '../../planning/domain/meal_component.dart';
import '../../planning/domain/meal_composition.dart';
import '../../planning/domain/meal_kind.dart';
import '../../planning/domain/meal_staple.dart';
import '../../planning/domain/planned_meal.dart';
import '../../planning/domain/planning_target.dart';
import '../../recipes/domain/recipe.dart';
import 'meal_workshop_freeze.dart';
import 'meal_workshop_menu.dart';

// ── Ce que le menu porte ─────────────────────────────────────────────────────

/// L'index du plat principal : le premier service `plat` du menu ; -1 sans
/// plat. C'est lui qui porte `recipe_id` du repas.
int workshopMainCourseIndex(WorkshopMenu menu) =>
    menu.courses.indexWhere((c) => c.role == MealComponentRole.plat);

/// La recette d'une ligne de figement : le brouillon créé ou la recette liée
/// relue ; `null` pour une ligne sans recette (non rédigée, plafond,
/// brouillon non enregistré, recette plus accessible).
String? freezeLineRecipeId(FreezeLineState state) => switch (state) {
  FreezeDraftCreated(:final draftId) => draftId,
  FreezeLinked(:final recipeId) => recipeId,
  _ => null,
};

/// Pourquoi « Poser » est inactif, ou `null` quand on peut poser : sans
/// service `plat`, « Un repas planifié a besoin d'un plat. » ; avec une
/// ligne « Recette plus accessible » sans réponse, la ligne accordée qui
/// demande de rédiger à la place ou de retirer du repas.
String? workshopPoseBlocker(WorkshopMenu menu, List<FreezeLineState> lines) {
  if (workshopMainCourseIndex(menu) < 0) {
    return 'Un repas planifié a besoin d\'un plat.';
  }
  final unreadable = lines.whereType<FreezeLinkedUnreadable>().length;
  if (unreadable == 1) {
    return '1 recette plus accessible : rédigez à la place ou retirez-la du '
        'repas.';
  }
  if (unreadable > 1) {
    return '$unreadable recettes plus accessibles : rédigez à la place ou '
        'retirez-les du repas.';
  }
  return null;
}

/// Les titres des services sans recette, plat principal exclu : ceux que la
/// pose écrit en texte libre.
List<String> workshopCoursesWithoutRecipe(
  WorkshopMenu menu,
  List<FreezeLineState> lines,
) {
  final main = workshopMainCourseIndex(menu);
  return [
    for (final (index, course) in menu.courses.indexed)
      if (index != main &&
          (index >= lines.length || freezeLineRecipeId(lines[index]) == null))
        course.title,
  ];
}

/// L'identifiant de la recette du plat principal à relire avant la pose ;
/// `null` sans plat, ou si le plat n'a pas de recette.
String? workshopMainRecipeId(WorkshopMenu menu, List<FreezeLineState> lines) {
  final main = workshopMainCourseIndex(menu);
  if (main < 0 || main >= lines.length) return null;
  return freezeLineRecipeId(lines[main]);
}

// ── Le repas ─────────────────────────────────────────────────────────────────

/// Le repas planifié à écrire (P2-4, P2-5).
///
/// - `recipe_id` : [mainRecipe], la recette du premier service `plat`
///   **relue** à la pose ; `null` si le plat n'a pas de recette ou si elle
///   est introuvable — le repas est alors posé par son titre, sans
///   `base_portions`.
/// - `prep_minutes`, `cook_minutes`, `duration_minutes` et `base_portions`
///   viennent de cette recette ; `target_portions` sont les parts choisies
///   dans la boîte ([portions]), planning personnel comme planning de
///   groupe. Ni la recette ni un brouillon ne sont réécrits : les quantités
///   se recalculent à l'affichage.
/// - `justification` : le `why` du plat principal ; `choice_source` :
///   [MealChoiceSource.workshop].
/// - `components` : écrits par [MealComposition.toComponents], les services
///   dans l'ordre du menu. Un service est une recette (brouillon créé ou
///   recette liée, par son identifiant et le titre du menu) ou un texte libre
///   sous son titre, avec son rôle, son `course_label` et son `why` en
///   `justification`. Un accompagnement est une garniture figée
///   ([stapleById]), une recette ou un texte libre. Un second `plat` devient
///   un plat secondaire (`p2`…) avec ses accompagnements (`side_of`).
/// - `meal_kind` : `plat` avec un seul service, `menu` dès qu'un autre
///   existe, second plat compris.
///
/// Jette [ArgumentError] sans service `plat` : [workshopPoseBlocker] le dit
/// avant.
PlannedMeal buildWorkshopMeal({
  required WorkshopMenu menu,
  required List<FreezeLineState> lines,
  required Recipe? mainRecipe,
  required MealStaple? Function(String id) stapleById,
  required PlanningTarget target,
  required String uid,
  required DateTime plannedAt,
  required DateTime now,
  required int portions,
}) {
  final mainIndex = workshopMainCourseIndex(menu);
  if (mainIndex < 0) {
    throw ArgumentError('Un repas planifié a besoin d\'un plat.');
  }
  final main = menu.courses[mainIndex];
  final title = mainRecipe?.titre ?? main.title;

  final MealComposition composition;
  if (menu.courses.length == 1) {
    composition = MealComposition.dish(
      sides: [for (final s in main.sides) _sideComponent(s, stapleById)],
    );
  } else {
    final raw = <MealComponent>[];
    var dishNumber = 2;
    for (final (index, course) in menu.courses.indexed) {
      if (index == mainIndex) {
        raw.add(
          MealComponent(
            role: MealComponentRole.plat,
            id: kMainCourseId,
            label: title,
          ),
        );
        for (final s in main.sides) {
          raw.add(_sideComponent(s, stapleById));
        }
        continue;
      }
      final isDish = course.role == MealComponentRole.plat;
      final id = isDish ? 'p${dishNumber++}' : null;
      final state = index < lines.length ? lines[index] : null;
      raw.add(_courseComponent(course, state, id: id));
      if (isDish) {
        for (final s in course.sides) {
          raw.add(_sideComponent(s, stapleById).copyWith(sideOf: id));
        }
      }
    }
    composition = MealComposition.fromComponents(raw, stored: MealKind.menu);
  }
  final components = composition.toComponents(mainTitle: title);

  final prep = mainRecipe?.tags.prepTime;
  final cook = mainRecipe?.tags.cookTime;
  return PlannedMeal(
    id: '',
    uid: uid,
    groupId: target.groupId,
    recipeId: mainRecipe?.id,
    recipeTitre: title,
    plannedAt: plannedAt,
    durationMinutes: (prep ?? 0) + (cook ?? 0),
    prepMinutes: prep,
    cookMinutes: cook,
    basePortions: mainRecipe?.portions,
    targetPortions: portions,
    justification: main.why,
    components: components,
    mealKind: effectiveMealKind(components),
    choiceSource: MealChoiceSource.workshop,
    createdAt: now,
  );
}

/// Un service autre que le plat principal : recette (brouillon ou liée) ou
/// texte libre, avec son rôle, son libellé d'« Autre » et son `why`.
MealComponent _courseComponent(
  WorkshopCourse course,
  FreezeLineState? state, {
  String? id,
}) => MealComponent(
  role: course.role,
  id: id,
  recipeId: state == null ? null : freezeLineRecipeId(state),
  label: course.title,
  justification: course.why,
  courseLabel: course.role == MealComponentRole.autre
      ? course.courseLabel
      : null,
);

/// Un accompagnement : la garniture figée quand le contexte la connaît
/// encore, sinon la recette, sinon le libellé en texte libre (sans quantité
/// ni produit de courses).
MealComponent _sideComponent(
  WorkshopSide side,
  MealStaple? Function(String id) stapleById,
) {
  final staple = side.stapleId == null ? null : stapleById(side.stapleId!);
  if (staple != null) return MealComponent.staple(staple);
  if (side.recipeId != null) {
    return MealComponent(
      role: MealComponentRole.accompagnement,
      recipeId: side.recipeId,
      label: side.label,
    );
  }
  return MealComponent.free(side.label);
}

// ── Les phrases ──────────────────────────────────────────────────────────────

/// « Menu · 4 services », ou « Plat · Blanquette de veau » pour un seul
/// service.
String poseRecapTitle(WorkshopMenu menu) {
  if (menu.courses.length == 1) return 'Plat · ${menu.courses.single.title}';
  final n = menu.courses.length;
  return 'Menu · $n ${n > 1 ? 'services' : 'service'}';
}

/// Ce qui suit le titre d'un service dans le récapitulatif : « · brouillon »,
/// « · Le Grand Livre » (le livre de la recette liée, [linkedBook]), ou
/// « · sans recette ».
String poseRecapSuffix(FreezeLineState? state, {String? linkedBook}) =>
    switch (state) {
      FreezeDraftCreated() => '· brouillon',
      FreezeLinked() => '· ${linkedBook ?? 'Sans livre'}',
      _ => '· sans recette',
    };

/// « 1 plat sans recette sera posé par son titre : Comté. Vous pourrez lui
/// choisir une recette depuis le planning (« Composer le menu »). »,
/// accordée ; vide sans service concerné.
String? noRecipeSentence(List<String> titles) {
  if (titles.isEmpty) return null;
  if (titles.length == 1) {
    return '1 plat sans recette sera posé par son titre : ${titles.single}. '
        'Vous pourrez lui choisir une recette depuis le planning '
        '(« Composer le menu »).';
  }
  return '${titles.length} plats sans recette seront posés par leur titre : '
      '${titles.join(', ')}. Vous pourrez leur choisir une recette depuis le '
      'planning (« Composer le menu »).';
}

/// Le plat principal n'a pas de recette : posé par son titre.
const String kMainNoRecipeSentence =
    'Le plat principal n\'a pas de recette : le repas sera posé par son '
    'titre, sans courses ni nutrition. Vous pourrez le concevoir depuis le '
    'planning (« Concevoir avec l\'IA »).';

/// Cible de groupe avec au moins un brouillon (P2-9).
const String kDraftsForMembersSentence =
    'Les brouillons ne s\'ouvrent pour les membres qu\'une fois validés.';

/// « Famille Dupont cuisine d'habitude pour 4 ce jour-là. » : quand les
/// parts du jour du groupe diffèrent des parts choisies dans la boîte.
String groupUsualPortionsLine(String groupName, int portions) =>
    '$groupName cuisine d\'habitude pour $portions ce jour-là.';

/// « Utiliser 2 » : le bouton qui applique les parts habituelles du groupe.
String usePortionsLabel(int portions) => 'Utiliser $portions';

/// « Recette pour 4 : les quantités seront recalculées pour ce repas, la
/// recette ne change pas. » : la recette du plat principal (liée ou
/// brouillon) n'a pas les parts choisies dans la boîte.
String linkedPortionsLine(int portions) =>
    'Recette pour $portions : les quantités seront recalculées pour ce repas, '
    'la recette ne change pas.';

/// « Mar. 12 nov. a déjà un repas : Blanquette de veau, 19:30. » ; deux
/// repas et plus : « … : Blanquette de veau, 19:30 et 1 autre repas. ». Le
/// premier repas du jour par son heure est nommé.
String busyDayLine(DateTime day, List<PlannedMeal> meals) {
  final sorted = [...meals]..sort((a, b) => a.plannedAt.compareTo(b.plannedAt));
  final first = sorted.first;
  final others = sorted.length - 1;
  final tail = others == 0
      ? '.'
      : ' et $others ${others > 1 ? 'autres repas' : 'autre repas'}.';
  return '${capitalizeFirst(formatShortDay(day))} a déjà un repas : '
      '${first.recipeTitre}, ${formatClockTime(first.plannedAt)}$tail';
}

/// « Posé le mar. 12 nov. dans Mon planning », le pied du panneau.
String posedLine(DateTime day, PlanningTarget target) =>
    'Posé le ${formatShortDay(day)} dans ${target.title}';

/// « Posé le mar. 12 nov. dans Mon planning. », le message de succès.
String posedMessage(DateTime day, PlanningTarget target) =>
    '${posedLine(day, target)}.';

/// « Rien à rédiger : les recettes seront liées telles quelles. » : sous
/// « Poser dans le planning » quand aucun figement n'a eu lieu.
const String kNothingToWritePoseLine =
    'Rien à rédiger : les recettes seront liées telles quelles.';

/// Le message d'une pose refusée : réseau ou écriture refusée, rôle retiré,
/// groupe plus accessible.
String poseFailureMessage({
  required bool permissionDenied,
  required PlanningTarget target,
}) {
  if (!permissionDenied) return 'Repas non posé. Réessayez.';
  return target.isGroup
      ? 'Repas non posé. Ce groupe ne vous est plus accessible.'
      : 'Repas non posé. La planification est réservée aux éditeurs.';
}
