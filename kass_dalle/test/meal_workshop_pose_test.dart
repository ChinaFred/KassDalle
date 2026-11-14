import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_composition.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_target.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_freeze.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_pose.dart';

/// « Poser dans le planning » : le repas planifié bâti depuis le menu et
/// les lignes de figement (P2-4, P2-5, P2-6), ce qui empêche la pose
/// (P2-2), et les phrases de la boîte et du pied (P2-7, P2-10). Fonctions
/// pures.
void main() {
  Recipe recipe(
    String id,
    String titre, {
    int? portions,
    int? prep,
    int? cook,
    String? book,
  }) => Recipe(
    id: id,
    titre: titre,
    bookTitre: book,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(prepTime: prep, cookTime: cook),
    ingredientsIndex: const [],
    createdBy: 'moi',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    portions: portions,
  );

  WorkshopCourse course(
    String title, {
    String role = 'plat',
    String? courseLabel,
    String? recipeId,
    String? why,
    List<Map<String, Object?>> sides = const [],
  }) => WorkshopCourse.fromJson({
    'role': role,
    'course_label': courseLabel,
    'title': title,
    'recipe_id': recipeId,
    'why': why,
    'sides': sides,
  });

  WorkshopMenu menu(List<WorkshopCourse> courses, {int portions = 4}) =>
      WorkshopMenu(portions: portions, courses: courses);

  final riz = MealStaple(
    id: 'riz',
    name: 'Riz',
    category: StapleCategory.feculent,
    quantityPerPortion: 70,
    unit: 'g',
    shoppingProduct: 'Riz basmati',
  );
  MealStaple? stapleById(String id) => id == 'riz' ? riz : null;

  final day = DateTime(2026, 11, 12, 19, 30);
  final now = DateTime(2026, 11, 7, 10);

  PlannedMeal build({
    required WorkshopMenu m,
    required List<FreezeLineState> lines,
    Recipe? main,
    PlanningTarget target = const PlanningTarget.personal(),
    int? portions,
  }) => buildWorkshopMeal(
    menu: m,
    lines: lines,
    mainRecipe: main,
    stapleById: stapleById,
    target: target,
    uid: 'u1',
    plannedAt: day,
    now: now,
    portions: portions ?? m.portions,
  );

  group('ce que le menu porte', () {
    test('le plat principal est le premier service plat', () {
      final m = menu([
        course('Velouté', role: 'entree'),
        course('Blanquette'),
        course('Rôti'),
      ]);
      expect(workshopMainCourseIndex(m), 1);
      expect(
        workshopMainCourseIndex(menu([course('Tarte', role: 'dessert')])),
        -1,
      );
    });

    test('la recette d\'une ligne : brouillon ou recette liée, sinon rien', () {
      expect(freezeLineRecipeId(const FreezeDraftCreated('d1')), 'd1');
      expect(freezeLineRecipeId(const FreezeLinked('r1')), 'r1');
      expect(freezeLineRecipeId(const FreezeNoRecipe()), isNull);
      expect(freezeLineRecipeId(const FreezeBudgetStopped('')), isNull);
      expect(freezeLineRecipeId(const FreezeLinkedUnreadable()), isNull);
    });

    test('sans plat : « Un repas planifié a besoin d\'un plat. »', () {
      final m = menu([
        course('Velouté', role: 'entree'),
        course('Tarte', role: 'dessert'),
      ]);
      expect(
        workshopPoseBlocker(m, const [
          FreezeDraftCreated('d1'),
          FreezeDraftCreated('d2'),
        ]),
        'Un repas planifié a besoin d\'un plat.',
      );
    });

    test('recette plus accessible sans réponse : la ligne accordée', () {
      final m = menu([
        course('Blanquette', recipeId: 'r1'),
        course('Tarte', role: 'dessert', recipeId: 'r2'),
      ]);
      expect(
        workshopPoseBlocker(m, const [
          FreezeLinkedUnreadable(),
          FreezeLinked('r2'),
        ]),
        '1 recette plus accessible : rédigez à la place ou retirez-la du repas.',
      );
      expect(
        workshopPoseBlocker(m, const [
          FreezeLinkedUnreadable(),
          FreezeLinkedUnreadable(),
        ]),
        '2 recettes plus accessibles : rédigez à la place ou retirez-les du repas.',
      );
      expect(
        workshopPoseBlocker(m, const [FreezeLinked('r1'), FreezeLinked('r2')]),
        isNull,
      );
      // Rien à rédiger, avant toute relecture : seul le plat compte.
      expect(workshopPoseBlocker(m, const []), isNull);
    });

    test('les services sans recette, plat principal exclu', () {
      final m = menu([
        course('Velouté', role: 'entree'),
        course('Blanquette'),
        course('Comté', role: 'fromage'),
        course('Tarte', role: 'dessert'),
      ]);
      expect(
        workshopCoursesWithoutRecipe(m, const [
          FreezeDraftCreated('d1'),
          FreezeNoRecipe(),
          FreezeFailed('réseau'),
          FreezeBudgetStopped('plafond'),
        ]),
        ['Comté', 'Tarte'],
      );
      expect(
        workshopMainRecipeId(m, const [
          FreezeDraftCreated('d1'),
          FreezeNoRecipe(),
        ]),
        isNull,
      );
      expect(
        workshopMainRecipeId(m, const [
          FreezeDraftCreated('d1'),
          FreezeDraftCreated('d2'),
        ]),
        'd2',
      );
    });
  });

  group('le repas (P2-4)', () {
    test('plat principal brouillon, mode plat : la forme de « Planifier »', () {
      final m = menu([
        course(
          'Blanquette de veau',
          why: 'Un classique du dimanche.',
          sides: const [
            {'label': 'Riz', 'staple_id': 'riz'},
            {'label': 'Carottes glacées'},
            {'label': 'Gratin', 'recipe_id': 'r5'},
          ],
        ),
      ], portions: 6);
      final draft = recipe(
        'd1',
        'Blanquette de veau',
        portions: 6,
        prep: 20,
        cook: 90,
      );
      final meal = build(
        m: m,
        lines: const [FreezeDraftCreated('d1')],
        main: draft,
      );

      expect(meal.uid, 'u1');
      expect(meal.groupId, isNull);
      expect(meal.recipeId, 'd1');
      expect(meal.recipeTitre, 'Blanquette de veau');
      expect(meal.plannedAt, day);
      expect(meal.prepMinutes, 20);
      expect(meal.cookMinutes, 90);
      expect(meal.durationMinutes, 110);
      expect(meal.basePortions, 6);
      expect(meal.targetPortions, 6);
      expect(meal.justification, 'Un classique du dimanche.');
      expect(meal.choiceSource, MealChoiceSource.workshop);
      expect(meal.mealKind, MealKind.plat);
      expect(meal.prepDate, isNull);
      expect(meal.dismissedRecipeIds, isEmpty);
      expect(meal.relaxedCriteria, isEmpty);
      expect(meal.unmetCriteria, isEmpty);
      expect(meal.createdAt, now);

      // Les accompagnements seuls, comme un repas posé depuis « Planifier ».
      expect(meal.components.length, 3);
      final riz = meal.components[0];
      expect(riz.role, MealComponentRole.accompagnement);
      expect(riz.stapleId, 'riz');
      expect(riz.quantityPerPortion, 70);
      expect(riz.unit, 'g');
      expect(riz.shoppingProduct, 'Riz basmati');
      expect(meal.components[1].isFree, isTrue);
      expect(meal.components[1].label, 'Carottes glacées');
      expect(meal.components[2].recipeId, 'r5');
      expect(meal.components[2].label, 'Gratin');
      expect(meal.components.every((c) => c.sideOf == null), isTrue);

      // `group_id` est toujours écrit, `null` compris.
      final data = meal.toFirestore();
      expect(data.containsKey('group_id'), isTrue);
      expect(data['group_id'], isNull);
      expect(data['choice_source'], 'workshop');
    });

    test(
      'plat principal lié : ses parts, le menu en cible, titre de la recette',
      () {
        final m = menu([course('Blanquette', recipeId: 'r1')], portions: 4);
        final linked = recipe(
          'r1',
          'Blanquette de veau',
          portions: 6,
          prep: 15,
        );
        final meal = build(
          m: m,
          lines: const [FreezeLinked('r1')],
          main: linked,
        );
        expect(meal.recipeId, 'r1');
        expect(meal.recipeTitre, 'Blanquette de veau');
        expect(meal.basePortions, 6);
        expect(meal.targetPortions, 4);
        expect(meal.durationMinutes, 15);
        expect(meal.cookMinutes, isNull);
      },
    );

    test(
      'plat principal sans recette : posé par son titre, sans base_portions',
      () {
        final m = menu([
          course('Blanquette', why: 'Parce que.'),
          course('Tarte', role: 'dessert'),
        ]);
        final meal = build(
          m: m,
          lines: const [FreezeNoRecipe(), FreezeDraftCreated('d2')],
        );
        expect(meal.recipeId, isNull);
        expect(meal.recipeTitre, 'Blanquette');
        expect(meal.basePortions, isNull);
        expect(meal.targetPortions, 4);
        expect(meal.durationMinutes, 0);
        expect(meal.justification, 'Parce que.');
        expect(meal.toFirestore().containsKey('base_portions'), isFalse);
        expect(meal.mealKind, MealKind.menu);
      },
    );

    test('planning de groupe : group_id et les parts du menu', () {
      final m = menu([course('Blanquette')], portions: 3);
      final meal = build(
        m: m,
        lines: const [FreezeDraftCreated('d1')],
        main: recipe('d1', 'Blanquette', portions: 3),
        target: const PlanningTarget.group(
          groupId: 'g1',
          groupName: 'Famille',
          memberCount: 4,
        ),
      );
      expect(meal.groupId, 'g1');
      expect(meal.uid, 'u1');
      expect(meal.targetPortions, 3);
      expect(meal.toFirestore()['group_id'], 'g1');
    });

    test('parts choisies dans la boîte : target_portions, base_portions '
        'de la recette', () {
      final m = menu([course('Blanquette')], portions: 4);
      final meal = build(
        m: m,
        lines: const [FreezeLinked('r1')],
        main: recipe('r1', 'Blanquette', portions: 6),
        portions: 2,
      );
      expect(meal.basePortions, 6);
      expect(meal.targetPortions, 2);
      expect(meal.toFirestore()['target_portions'], 2);
    });

    test('sans plat : ArgumentError', () {
      expect(
        () => build(
          m: menu([course('Tarte', role: 'dessert')]),
          lines: const [FreezeDraftCreated('d1')],
        ),
        throwsArgumentError,
      );
    });
  });

  group('les composants (P2-5)', () {
    test('un menu complet, relu par MealComposition dans le même ordre', () {
      final m = menu([
        course(
          'Velouté',
          role: 'entree',
          recipeId: 'r1',
          why: 'Chaud d\'abord.',
        ),
        course(
          'Blanquette',
          why: 'Le plat.',
          sides: const [
            {'label': 'Riz', 'staple_id': 'riz'},
            {'label': 'Carottes glacées'},
          ],
        ),
        course(
          'Rôti',
          why: 'Un second plat.',
          sides: const [
            {'label': 'Pommes de terre', 'staple_id': 'inconnue'},
          ],
        ),
        course('Comté', role: 'fromage'),
        course('Tarte aux poires', role: 'dessert', why: 'Fruité.'),
        course('Trou normand', role: 'autre', courseLabel: 'Trou normand'),
      ]);
      final lines = <FreezeLineState>[
        const FreezeLinked('r1'),
        const FreezeDraftCreated('d2'),
        const FreezeDraftCreated('d3'),
        const FreezeFailed('réseau'),
        const FreezeDraftCreated('d5'),
        FreezeSaveFailed(recipe('x', 'X'), 'x'),
      ];
      final meal = build(
        m: m,
        lines: lines,
        main: recipe('d2', 'Blanquette', portions: 4),
      );
      expect(meal.mealKind, MealKind.menu);
      final c = meal.components;
      expect(c.map((e) => e.label).toList(), [
        'Velouté',
        'Blanquette',
        'Riz',
        'Carottes glacées',
        'Rôti',
        'Pommes de terre',
        'Comté',
        'Tarte aux poires',
        'Trou normand',
      ]);
      // L'entrée : recette liée, son rôle, son why.
      expect(c[0].role, MealComponentRole.entree);
      expect(c[0].recipeId, 'r1');
      expect(c[0].justification, 'Chaud d\'abord.');
      // Le plat principal : son marqueur, puis ses accompagnements sans side_of.
      expect(c[1].isMainMarker, isTrue);
      expect(c[1].label, 'Blanquette');
      expect(c[2].stapleId, 'riz');
      expect(c[2].sideOf, isNull);
      expect(c[3].isFree, isTrue);
      expect(c[3].sideOf, isNull);
      // Le plat secondaire : brouillon, id p2, son accompagnement en side_of.
      expect(c[4].role, MealComponentRole.plat);
      expect(c[4].id, 'p2');
      expect(c[4].recipeId, 'd3');
      expect(c[5].role, MealComponentRole.accompagnement);
      expect(c[5].sideOf, 'p2');
      // Garniture inconnue du contexte : texte libre, sans quantité.
      expect(c[5].isFree, isTrue);
      expect(c[5].quantityPerPortion, isNull);
      // Fromage non rédigé : texte libre sous son titre.
      expect(c[6].role, MealComponentRole.fromage);
      expect(c[6].isFree, isTrue);
      // Dessert brouillon.
      expect(c[7].recipeId, 'd5');
      expect(c[7].justification, 'Fruité.');
      // « Autre » avec son libellé, brouillon non enregistré : texte libre.
      expect(c[8].role, MealComponentRole.autre);
      expect(c[8].courseLabel, 'Trou normand');
      expect(c[8].isFree, isTrue);
      expect(c.length, lessThanOrEqualTo(70));

      // Relu par le planning : les mêmes services, dans le même ordre.
      final composition = MealComposition.ofMeal(meal);
      expect(composition.isMenu, isTrue);
      expect(composition.courses.map((s) => s.component.label).toList(), [
        'Velouté',
        'Blanquette',
        'Rôti',
        'Comté',
        'Tarte aux poires',
        'Trou normand',
      ]);
      expect(composition.main.sides.map((s) => s.label).toList(), [
        'Riz',
        'Carottes glacées',
      ]);
      expect(composition.courses[2].sides.map((s) => s.label).toList(), [
        'Pommes de terre',
      ]);
      expect(composition.detached, isEmpty);
      expect(composition.courses[5].typeLabel, 'Trou normand');
    });

    test(
      'entrée et dessert autour du plat : un menu, le plat seul en mode plat',
      () {
        final m = menu([
          course('Velouté', role: 'entree'),
          course('Blanquette'),
          course('Tarte', role: 'dessert'),
        ]);
        final meal = build(
          m: m,
          lines: const [
            FreezeDraftCreated('d1'),
            FreezeDraftCreated('d2'),
            FreezeDraftCreated('d3'),
          ],
          main: recipe('d2', 'Blanquette'),
        );
        expect(meal.mealKind, MealKind.menu);
        expect(meal.components.map((c) => c.label).toList(), [
          'Velouté',
          'Blanquette',
          'Tarte',
        ]);
        expect(meal.components[1].isMainMarker, isTrue);
      },
    );

    test('deux plats en mode plat : un menu, le second en p2', () {
      final m = menu([
        course('Blanquette'),
        course(
          'Gratin dauphinois',
          sides: const [
            {'label': 'Salade'},
          ],
        ),
      ]);
      final meal = build(
        m: m,
        lines: const [FreezeDraftCreated('d1'), FreezeDraftCreated('d2')],
        main: recipe('d1', 'Blanquette'),
      );
      expect(meal.mealKind, MealKind.menu);
      expect(meal.recipeId, 'd1');
      expect(meal.components.map((c) => c.label).toList(), [
        'Blanquette',
        'Gratin dauphinois',
        'Salade',
      ]);
      expect(meal.components[1].id, 'p2');
      expect(meal.components[2].sideOf, 'p2');
    });
  });

  group('les phrases', () {
    test('récapitulatif', () {
      expect(poseRecapTitle(menu([course('Blanquette')])), 'Plat · Blanquette');
      expect(
        poseRecapTitle(
          menu([
            course('A', role: 'entree'),
            course('B'),
            course('C', role: 'dessert'),
            course('D', role: 'fromage'),
          ]),
        ),
        'Menu · 4 services',
      );
      expect(poseRecapSuffix(const FreezeDraftCreated('d1')), '· brouillon');
      expect(
        poseRecapSuffix(const FreezeLinked('r1'), linkedBook: 'Le Grand Livre'),
        '· Le Grand Livre',
      );
      expect(poseRecapSuffix(const FreezeNoRecipe()), '· sans recette');
      expect(poseRecapSuffix(null), '· sans recette');
    });

    test('services sans recette, accordé', () {
      expect(noRecipeSentence(const []), isNull);
      expect(
        noRecipeSentence(const ['Comté']),
        '1 plat sans recette sera posé par son titre : Comté. Vous pourrez lui '
        'choisir une recette depuis le planning (« Composer le menu »).',
      );
      expect(
        noRecipeSentence(const ['Comté', 'Tarte aux poires']),
        '2 plats sans recette seront posés par leur titre : Comté, Tarte aux '
        'poires. Vous pourrez leur choisir une recette depuis le planning '
        '(« Composer le menu »).',
      );
    });

    test('parts', () {
      expect(usePortionsLabel(2), 'Utiliser 2');
      expect(
        groupUsualPortionsLine('Famille Dupont', 4),
        'Famille Dupont cuisine d\'habitude pour 4 ce jour-là.',
      );
      expect(
        linkedPortionsLine(4),
        'Recette pour 4 : les quantités seront recalculées pour ce repas, la recette ne change pas.',
      );
    });

    test('jour occupé : le premier repas par son heure, puis les autres', () {
      PlannedMeal meal(String titre, int hour) => PlannedMeal(
        id: titre,
        uid: 'u1',
        recipeTitre: titre,
        plannedAt: DateTime(2026, 11, 12, hour, hour == 19 ? 30 : 0),
        durationMinutes: 0,
        createdAt: now,
      );
      final d = DateTime(2026, 11, 12);
      expect(
        busyDayLine(d, [meal('Blanquette de veau', 19)]),
        'Jeu. 12 nov. a déjà un repas : Blanquette de veau, 19:30.',
      );
      expect(
        busyDayLine(d, [meal('Soupe', 20), meal('Blanquette de veau', 19)]),
        'Jeu. 12 nov. a déjà un repas : Blanquette de veau, 19:30 et 1 autre repas.',
      );
      expect(
        busyDayLine(d, [
          meal('Soupe', 20),
          meal('Blanquette de veau', 19),
          meal('Œufs', 12),
        ]),
        'Jeu. 12 nov. a déjà un repas : Œufs, 12:00 et 2 autres repas.',
      );
    });

    test('posé, et le message', () {
      const personal = PlanningTarget.personal();
      const group = PlanningTarget.group(
        groupId: 'g',
        groupName: 'Famille Dupont',
        memberCount: 4,
      );
      expect(
        posedLine(day, personal),
        'Posé le jeu. 12 nov. dans Mon planning',
      );
      expect(
        posedMessage(day, group),
        'Posé le jeu. 12 nov. dans Famille Dupont.',
      );
    });

    test('pose refusée', () {
      const personal = PlanningTarget.personal();
      const group = PlanningTarget.group(
        groupId: 'g',
        groupName: 'F',
        memberCount: 2,
      );
      expect(
        poseFailureMessage(permissionDenied: false, target: group),
        'Repas non posé. Réessayez.',
      );
      expect(
        poseFailureMessage(permissionDenied: true, target: personal),
        'Repas non posé. La planification est réservée aux éditeurs.',
      );
      expect(
        poseFailureMessage(permissionDenied: true, target: group),
        'Repas non posé. Ce groupe ne vous est plus accessible.',
      );
    });
  });
}
