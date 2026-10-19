import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/calendar_event_description.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_composition.dart';
import 'package:kass_dalle/features/planning/domain/meal_format.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Palier « Menu » : un repas est un plat ou un menu de services ordonnés.
/// Lecture des repas anciens, écriture, opérations et bornes.
void main() {
  MealComponent c(String role, String label, {String? id, String? sideOf}) =>
      MealComponent.fromMap({
        'role': role,
        'label': label,
        'id': ?id,
        'side_of': ?sideOf,
      });

  PlannedMeal meal(
    List<MealComponent> components, {
    MealKind? kind,
    String titre = 'Veau sauté',
    String? recipeId = 'veau',
  }) => PlannedMeal(
    id: 'm1',
    uid: 'u1',
    recipeId: recipeId,
    recipeTitre: titre,
    plannedAt: DateTime(2026, 10, 25, 12),
    durationMinutes: 60,
    components: components,
    mealKind: kind,
    createdAt: DateTime(2026, 10, 1),
  );

  List<String> describe(MealComposition m) => [
    for (final course in m.courses)
      [
        course.isMain
            ? 'MAIN'
            : '${course.role.name}:${course.component.label}',
        for (final s in course.sides) '+${s.label}',
      ].join(' '),
  ];

  List<Map<String, dynamic>> written(MealComposition m, {String t = 'Veau'}) =>
      [for (final x in m.toComponents(mainTitle: t)) x.toMap()];

  group('champs id et course_label', () {
    test('lus, réécrits, absents quand vides', () {
      final data = {
        'role': 'autre',
        'label': 'Calvados',
        'id': 'x',
        'course_label': 'Trou normand',
      };
      final m = MealComponent.fromMap(data);
      expect(m.id, 'x');
      expect(m.courseLabel, 'Trou normand');
      expect(m.courseTypeLabel, 'Trou normand');
      expect(m.extra, isEmpty);
      expect(m.toMap(), data);
      expect(
        const MealComponent(
          role: MealComponentRole.entree,
          label: 'Velouté',
        ).toMap().containsKey('id'),
        isFalse,
      );
    });

    test('marqueur du plat principal et service vide', () {
      final marker = c('plat', 'Veau', id: kMainCourseId);
      expect(marker.isMainMarker, isTrue);
      expect(marker.isEmptyCourse, isFalse);
      expect(c('fromage', '').isEmptyCourse, isTrue);
      expect(c('accompagnement', '').isEmptyCourse, isFalse);
      // Une recette ne peut pas être le marqueur.
      expect(
        MealComponent.fromMap({
          'role': 'plat',
          'id': 'main',
          'recipe_id': 'r',
          'label': 'Veau',
        }).isMainMarker,
        isFalse,
      );
    });

    test('copyWith : changer de rôle efface un rôle inconnu', () {
      final m = MealComponent.fromMap({'role': 'trou_normand', 'label': 'X'});
      expect(m.toMap()['role'], 'trou_normand');
      final changed = m.copyWith(role: MealComponentRole.fromage);
      expect(changed.toMap()['role'], 'fromage');
      expect(m.copyWith(label: 'Y').toMap()['role'], 'trou_normand');
    });
  });

  group('meal_kind', () {
    final now = DateTime(2026, 10, 1);
    Map<String, dynamic> doc(Object? kind) => {
      'uid': 'u1',
      'recipe_titre': 'Veau',
      'planned_at': Timestamp.fromDate(now),
      'created_at': Timestamp.fromDate(now),
      'meal_kind': ?kind,
    };

    test('lu, réécrit', () {
      final m = PlannedMeal.fromFirestore('m', doc('menu'));
      expect(m.mealKind, MealKind.menu);
      expect(m.extra, isEmpty);
      expect(m.toFirestore()['meal_kind'], 'menu');
    });

    test('valeur inconnue : gardée telle quelle', () {
      final m = PlannedMeal.fromFirestore('m', doc('brunch'));
      expect(m.mealKind, isNull);
      expect(m.toFirestore()['meal_kind'], 'brunch');
    });

    test('absent : déduit des composants', () {
      expect(meal([c('accompagnement', 'Riz')]).kind, MealKind.plat);
      expect(meal(const []).kind, MealKind.plat);
      expect(
        meal([c('entree', 'Velouté'), c('accompagnement', 'Riz')]).kind,
        MealKind.menu,
      );
      expect(meal([c('trou_normand', 'X')]).kind, MealKind.menu);
    });

    test(
      'noté plat avec une entrée posée par une version antérieure : menu',
      () {
        expect(
          meal([c('entree', 'Velouté')], kind: MealKind.plat).kind,
          MealKind.menu,
        );
        expect(meal(const [], kind: MealKind.menu).kind, MealKind.menu);
      },
    );
  });

  group('lecture', () {
    test('plat : ses accompagnements, un seul service', () {
      final m = MealComposition.ofMeal(
        meal([c('accompagnement', 'Riz'), c('accompagnement', 'Haricots')]),
      );
      expect(m.isMenu, isFalse);
      expect(describe(m), ['MAIN +Riz +Haricots']);
      expect(m.mainSides.map((s) => s.label), ['Riz', 'Haricots']);
    });

    test('repas ancien entrée + accompagnement + dessert : entrée, plat, '
        'dessert', () {
      final m = MealComposition.ofMeal(
        meal([
          c('entree', 'Velouté'),
          c('accompagnement', 'Riz'),
          c('dessert', 'Tarte'),
        ]),
      );
      expect(m.isMenu, isTrue);
      expect(describe(m), ['entree:Velouté', 'MAIN +Riz', 'dessert:Tarte']);
    });

    test('repas P1 avec un accompagnement après le dessert', () {
      final m = MealComposition.ofMeal(
        meal([
          c('entree', 'Velouté'),
          c('accompagnement', 'Riz'),
          c('dessert', 'Tarte'),
          c('accompagnement', 'Salade verte'),
        ]),
      );
      expect(describe(m), [
        'entree:Velouté',
        'MAIN +Riz +Salade verte',
        'dessert:Tarte',
      ]);
      // Réécrit : les accompagnements suivent leur plat.
      expect(m.toComponents(mainTitle: 'Veau').map((x) => x.label), [
        'Velouté',
        'Veau',
        'Riz',
        'Salade verte',
        'Tarte',
      ]);
    });

    test('sans marqueur, deux entrées de tête puis un fromage', () {
      final m = MealComposition.fromComponents([
        c('entree', 'Huîtres'),
        c('entree', 'Velouté'),
        c('fromage', 'Comté'),
      ]);
      expect(describe(m), [
        'entree:Huîtres',
        'entree:Velouté',
        'MAIN',
        'fromage:Comté',
      ]);
    });

    test('le marqueur dit où se sert le plat principal', () {
      final m = MealComposition.fromComponents([
        c('entree', 'Velouté'),
        c('sorbet', 'Citron'),
        c('plat', 'Veau', id: 'main'),
        c('accompagnement', 'Riz'),
        c('dessert', 'Tarte'),
      ]);
      expect(describe(m), [
        'entree:Velouté',
        'sorbet:Citron',
        'MAIN +Riz',
        'dessert:Tarte',
      ]);
      expect(m.mainIndex, 2);
    });

    test('plat secondaire et ses accompagnements', () {
      final m = MealComposition.fromComponents([
        c('plat', 'Veau', id: 'main'),
        c('accompagnement', 'Riz'),
        c('plat', 'Gratin', id: 'p2'),
        c('accompagnement', 'Salade', sideOf: 'p2'),
      ]);
      expect(describe(m), ['MAIN +Riz', 'plat:Gratin +Salade']);
      expect(written(m), [
        {'role': 'plat', 'label': 'Veau', 'id': 'main'},
        {'role': 'accompagnement', 'label': 'Riz'},
        {'role': 'plat', 'label': 'Gratin', 'id': 'p2'},
        {'role': 'accompagnement', 'label': 'Salade', 'side_of': 'p2'},
      ]);
    });

    test('accompagnement d\'un plat introuvable : gardé, à la fin', () {
      final m = MealComposition.fromComponents([
        c('entree', 'Velouté'),
        c('accompagnement', 'Frites', sideOf: 'p9'),
      ]);
      expect(m.detached.map((x) => x.label), ['Frites']);
      expect(written(m).last, {
        'role': 'accompagnement',
        'label': 'Frites',
        'side_of': 'p9',
      });
    });

    test('plat secondaire sans identifiant : il en reçoit un', () {
      final m = MealComposition.fromComponents([
        c('plat', 'Gratin'),
        c('plat', 'Quiche', id: 'p2'),
      ]);
      final ids = [
        for (final x in m.courses)
          if (!x.isMain) x.component.id,
      ];
      expect(ids.toSet(), hasLength(2));
      expect(ids, everyElement(isNotNull));
    });

    test('second marqueur écarté', () {
      final m = MealComposition.fromComponents([
        c('plat', 'Veau', id: 'main'),
        c('plat', 'Veau', id: 'main'),
        c('dessert', 'Tarte'),
      ]);
      expect(describe(m), ['MAIN', 'dessert:Tarte']);
    });
  });

  group('écriture', () {
    test('un plat s\'écrit comme avant : ses accompagnements seuls', () {
      final m = MealComposition.dish(sides: [c('accompagnement', 'Riz')]);
      expect(written(m), [
        {'role': 'accompagnement', 'label': 'Riz'},
      ]);
    });

    test('le marqueur recopie le titre du plat', () {
      final m = MealComposition.dish().toMenu();
      expect(written(m, t: 'Blanquette'), [
        {'role': 'entree', 'label': ''},
        {'role': 'plat', 'label': 'Blanquette', 'id': 'main'},
        {'role': 'dessert', 'label': ''},
      ]);
    });

    test('aller-retour sans perte', () {
      final source = [
        c('entree', 'Velouté'),
        c('plat', 'Veau', id: 'main'),
        c('accompagnement', 'Riz'),
        c('plat', 'Gratin', id: 'p2'),
        c('accompagnement', 'Salade', sideOf: 'p2'),
        c('fromage', ''),
        c('dessert', 'Tarte'),
      ];
      final once = MealComposition.fromComponents(
        source,
      ).toComponents(mainTitle: 'Veau');
      expect(
        [for (final x in once) x.toMap()],
        [for (final x in source) x.toMap()],
      );
    });

    test('withMainMarkerTitle : seul le marqueur change', () {
      final out = withMainMarkerTitle([
        c('entree', 'Velouté'),
        c('plat', 'Veau', id: 'main'),
      ], 'Poulet');
      expect(out.map((x) => x.label), ['Velouté', 'Poulet']);
    });
  });

  group('plat ↔ menu', () {
    test('plat → menu : entrée, plat, dessert d\'office, à choisir', () {
      final m = MealComposition.dish(
        sides: [c('accompagnement', 'Riz')],
      ).toMenu();
      expect(m.isMenu, isTrue);
      expect(describe(m), ['entree:', 'MAIN +Riz', 'dessert:']);
      expect(m.template, MenuTemplate.entreePlatDessert);
      expect(m.onlyEmptyCourses, isTrue);
    });

    test('un autre modèle remplace les services vides', () {
      final m = MealComposition.dish().toMenu().applyTemplate(
        MenuTemplate.platDessert,
      );
      expect(describe(m), ['MAIN', 'dessert:']);
      expect(m.template, MenuTemplate.platDessert);
      final e = MealComposition.dish().toMenu().applyTemplate(
        MenuTemplate.entreePlat,
      );
      expect(describe(e), ['entree:', 'MAIN']);
    });

    test('un modèle ne remplace pas un service rempli', () {
      final m = MealComposition.dish().toMenu().setCourseContent(
        0,
        c('entree', 'Velouté'),
      );
      expect(m.template, isNull);
      expect(m.applyTemplate(MenuTemplate.platDessert), same(m));
    });

    test(
      'repasser en plat en mémoire, puis revenir : les services reviennent',
      () {
        final menu = MealComposition.fromComponents([
          c('entree', 'Velouté'),
          c('accompagnement', 'Riz'),
          c('fromage', ''),
        ]);
        final dish = menu.withKind(MealKind.plat);
        expect(dish.droppedAsDish.map((x) => x.role.name), [
          'entree',
          'fromage',
        ]);
        expect(dish.filledDroppedAsDish.map((x) => x.component.label), [
          'Velouté',
        ]);
        expect(written(dish), [
          {'role': 'accompagnement', 'label': 'Riz'},
        ]);
        expect(describe(dish.toMenu()), describe(menu));
      },
    );

    test('toDish retire les autres services et garde les accompagnements', () {
      final m = MealComposition.fromComponents([
        c('entree', 'Velouté'),
        c('accompagnement', 'Riz'),
        c('plat', 'Gratin', id: 'p2'),
        c('accompagnement', 'Salade', sideOf: 'p2'),
      ]).toDish();
      expect(m.kind, MealKind.plat);
      expect(describe(m), ['MAIN +Riz']);
    });

    test('componentsWithoutMain : « Remettre à blanc » d\'un menu', () {
      final m = meal([
        c('entree', 'Velouté'),
        c('plat', 'Veau', id: 'main'),
        c('accompagnement', 'Riz'),
        c('dessert', 'Tarte'),
      ]);
      expect(componentsWithoutMain(m).map((x) => x.label), [
        'Velouté',
        'Tarte',
      ]);
      expect(
        componentsWithoutMain(meal([c('accompagnement', 'Riz')])),
        isEmpty,
      );
      final cleared = meal(
        componentsWithoutMain(m),
        kind: MealKind.menu,
        titre: kFreeMealTitle,
        recipeId: null,
      );
      expect(mealMainIsEmpty(cleared), isTrue);
      expect(describe(MealComposition.ofMeal(cleared)), [
        'entree:Velouté',
        'MAIN',
        'dessert:Tarte',
      ]);
    });
  });

  group('opérations sur les services', () {
    final base = MealComposition.dish().toMenu();

    test('ajouter : à sa place, à choisir', () {
      final m = base
          .addCourse(MealComponentRole.fromage)
          .addCourse(MealComponentRole.sorbet)
          .addCourse(MealComponentRole.entree);
      // Le rang : entrées, plat, sorbet, fromage, dessert.
      expect(describe(m), [
        'entree:',
        'entree:',
        'MAIN',
        'sorbet:',
        'fromage:',
        'dessert:',
      ]);
      expect(m.courses.every((x) => x.isMain || x.isEmpty), isTrue);
    });

    test('un plat ajouté reçoit un identifiant unique', () {
      final m = base
          .addCourse(MealComponentRole.plat)
          .addCourse(MealComponentRole.plat);
      final ids = [
        for (final x in m.courses)
          if (x.isDish && !x.isMain) x.component.id,
      ];
      expect(ids, ['p2', 'p3']);
    });

    test('« Autre… » garde son libellé', () {
      final m = base.addCourse(
        MealComponentRole.autre,
        courseLabel: 'Trou normand',
      );
      expect(m.courses.last.typeLabel, 'Trou normand');
      expect(written(m).last, {
        'role': 'autre',
        'label': '',
        'course_label': 'Trou normand',
      });
      expect(courseLabelFrom('  Trou   normand  '), 'Trou normand');
      expect(courseLabelFrom('   '), isNull);
      expect(courseLabelFrom('x' * 40), hasLength(kCourseLabelMaxChars));
    });

    test('dix services au plus', () {
      var m = base;
      for (var i = 0; i < 20; i++) {
        m = m.addCourse(MealComponentRole.autre);
      }
      expect(m.courses, hasLength(kMaxCoursesPerMenu));
      expect(m.canAddCourse, isFalse);
      expect(m.addCourse(MealComponentRole.fromage), same(m));
    });

    test('retirer : pas le plat principal', () {
      expect(describe(base.removeCourse(0)), ['MAIN', 'dessert:']);
      expect(base.removeCourse(base.mainIndex), same(base));
    });

    test('déplacer : monter, descendre, convention onReorderItem', () {
      final m = base.moveCourse(2, 0);
      expect(describe(m), ['dessert:', 'entree:', 'MAIN']);
      expect(describe(m.moveCourse(0, 2)), ['entree:', 'MAIN', 'dessert:']);
      expect(describe(base.moveCourse(0, 1)), ['MAIN', 'entree:', 'dessert:']);
    });

    test('changer le type : le plat principal reste un plat', () {
      final m = base.changeCourseType(0, MealComponentRole.sorbet);
      expect(m.courses.first.role, MealComponentRole.sorbet);
      expect(base.changeCourseType(1, MealComponentRole.dessert), same(base));
      final autre = base.changeCourseType(
        2,
        MealComponentRole.autre,
        courseLabel: 'Café',
      );
      expect(autre.courses.last.typeLabel, 'Café');
    });

    test('un plat secondaire qui change de type perd ses accompagnements', () {
      final m = base.addCourse(MealComponentRole.plat).setSides(2, [
        c('accompagnement', 'Salade'),
      ]);
      expect(m.courses[2].sides, hasLength(1));
      final changed = m.changeCourseType(2, MealComponentRole.entree);
      expect(changed.courses[2].sides, isEmpty);
      expect(changed.courses[2].component.id, isNull);
    });

    test('changer le contenu : rôle du service, vide = à choisir', () {
      final m = base.setCourseContent(
        2,
        MealComponent.free('Tarte aux pommes'),
      );
      expect(m.courses[2].component.role, MealComponentRole.dessert);
      expect(m.courses[2].component.label, 'Tarte aux pommes');
      expect(m.setCourseContent(2, null).courses[2].isEmpty, isTrue);
      expect(base.setCourseContent(1, c('plat', 'X')), same(base));
    });

    test(
      'un plat secondaire garde son identifiant au changement de contenu',
      () {
        final m = base.addCourse(MealComponentRole.plat);
        final id = m.courses[2].component.id;
        final filled = m.setCourseContent(
          2,
          MealComponent.free('Gratin', role: MealComponentRole.plat),
        );
        expect(filled.courses[2].component.id, id);
      },
    );

    test('six accompagnements au plus par plat', () {
      final m = base.withMainSides([
        for (var i = 0; i < 9; i++) c('accompagnement', 'Côté $i'),
      ]);
      expect(m.mainSides, hasLength(kMaxSidesPerDish));
      // Pas d'accompagnement sur un service qui n'est pas un plat.
      expect(base.setSides(0, [c('accompagnement', 'Riz')]), same(base));
    });
  });

  group('ordre des accompagnements dans un menu', () {
    test('insertMainSide : après ceux qui suivent le marqueur', () {
      final out = insertMainSide([
        c('entree', 'Velouté'),
        c('plat', 'Veau', id: 'main'),
        c('accompagnement', 'Riz'),
        c('plat', 'Gratin', id: 'p2'),
        c('dessert', 'Tarte'),
      ], c('accompagnement', 'Salade'));
      expect(out.map((x) => x.label), [
        'Velouté',
        'Veau',
        'Riz',
        'Salade',
        'Gratin',
        'Tarte',
      ]);
    });

    test('replaceMainSides : juste après le marqueur', () {
      final out = replaceMainSides(
        [
          c('plat', 'Veau', id: 'main'),
          c('plat', 'Gratin', id: 'p2'),
          c('accompagnement', 'Salade', sideOf: 'p2'),
          c('accompagnement', 'Riz'),
        ],
        [c('accompagnement', 'Pâtes')],
      );
      expect(out.map((x) => x.label), ['Veau', 'Pâtes', 'Gratin', 'Salade']);
    });
  });

  group('candidats par type de service', () {
    UserStaple staple(
      String id,
      StapleCategory category, {
      bool hidden = false,
    }) => UserStaple(
      staple: MealStaple(
        id: id,
        name: id,
        category: category,
        quantityPerPortion: 30,
      ),
      isOwn: false,
      isOverridden: false,
      hidden: hidden,
    );
    Recipe recipe(String id, String role) {
      final t = DateTime(2026);
      return Recipe(
        id: id,
        titre: id,
        langue: 'fr',
        rawCooklang: '',
        imageUrls: const [],
        reviewStatus: ReviewStatus.validated,
        tags: RecipeTags(mealRole: role),
        ingredientsIndex: const [],
        createdBy: 'u',
        createdAt: t,
        updatedAt: t,
      );
    }

    final staples = [
      staple('salade', StapleCategory.salade),
      staple('comte', StapleCategory.fromage),
      staple('pomme', StapleCategory.fruit),
      staple('yaourt', StapleCategory.laitage),
      staple('riz', StapleCategory.feculent),
      staple('masque', StapleCategory.fromage, hidden: true),
    ];
    final recipes = [
      recipe('veloute', 'entree'),
      recipe('tarte', 'dessert'),
      recipe('veau', 'plat'),
    ];
    List<String> ids(MealComponentRole role) => [
      for (final x in courseCandidatesFor(
        role,
        staples: staples,
        recipes: recipes,
      ))
        x.id,
    ];

    test('entrée, sorbet, fromage, dessert, autre', () {
      expect(ids(MealComponentRole.entree), ['salade', 'veloute']);
      expect(ids(MealComponentRole.sorbet), ['pomme', 'tarte']);
      expect(ids(MealComponentRole.fromage), ['comte']);
      expect(ids(MealComponentRole.dessert), ['pomme', 'yaourt', 'tarte']);
      expect(ids(MealComponentRole.autre), [
        'salade',
        'comte',
        'pomme',
        'yaourt',
        'riz',
        'veloute',
        'tarte',
        'veau',
      ]);
      expect(ids(MealComponentRole.plat), isEmpty);
    });

    test('un candidat posé prend le rôle du service, et sa part', () {
      final x = courseCandidatesFor(
        MealComponentRole.fromage,
        staples: staples,
        recipes: recipes,
      ).single.toComponent(role: MealComponentRole.fromage);
      expect(x.role, MealComponentRole.fromage);
      expect(x.quantityLabel, '30 g par part');
    });
  });

  group('Nouveau planning : une composition éditée', () {
    final composed = MealComposition.fromComponents([
      c('entree', 'Velouté'),
      c('plat', 'Veau', id: 'main'),
      c('accompagnement', 'Riz'),
      c('fromage', ''),
      c('dessert', 'Tarte'),
    ]);

    test('reposée par le créneau, elle s\'écrit telle quelle', () {
      final base = composed.toComponents(mainTitle: 'Veau');
      final merged = withMainMarkerTitle(
        mergeSlotComponents(
          base,
          starter: composed.courses.first.component,
          sides: composed.mainSides,
          dessert: composed.courses.last.component,
        ),
        'Veau',
      );
      expect(
        [for (final x in merged) x.toMap()],
        [for (final x in base) x.toMap()],
      );
    });

    test('un dessert changé sur la carte prend sa place, le fromage reste', () {
      final merged = withMainMarkerTitle(
        mergeSlotComponents(
          composed.toComponents(mainTitle: 'Veau'),
          starter: composed.courses.first.component,
          sides: composed.mainSides,
          dessert: c('dessert', 'Crème brûlée'),
        ),
        'Poulet',
      );
      expect(merged.map((x) => x.label), [
        'Velouté',
        'Poulet',
        'Riz',
        '',
        'Crème brûlée',
      ]);
    });

    test('le format du créneau suit l\'entrée et le dessert', () {
      expect(
        mealFormatForComposition(composed, current: MealFormat.plat),
        MealFormat.entreePlatDessert,
      );
      expect(
        mealFormatForComposition(
          composed.removeCourse(3),
          current: MealFormat.plat,
        ),
        MealFormat.entreePlat,
      );
      expect(
        mealFormatForComposition(
          composed.removeCourse(0),
          current: MealFormat.plat,
        ),
        MealFormat.platDessert,
      );
      expect(
        mealFormatForComposition(
          composed.toDish(),
          current: MealFormat.entreePlat,
        ),
        MealFormat.plat,
      );
      expect(
        mealFormatForComposition(composed.toDish(), current: MealFormat.leger),
        MealFormat.leger,
      );
      // Un plat gardé en mémoire avec ses services ne compte que pour un plat.
      expect(
        mealFormatForComposition(
          composed.withKind(MealKind.plat),
          current: MealFormat.plat,
        ),
        MealFormat.plat,
      );
    });
  });

  group('export Calendar', () {
    test('les services dans l\'ordre, chaque plat suivi des siens', () {
      final lines = componentCalendarLines(
        MealComposition.ofMeal(
          meal([
            c('entree', 'Velouté'),
            c('dessert', 'Tarte'),
            c('accompagnement', 'Riz'),
            c('fromage', ''),
          ]),
        ).toComponents(mainTitle: 'Veau sauté'),
      );
      expect(lines, [
        'Entrée : Velouté',
        'Plat : Veau sauté',
        'Accompagnement : Riz',
        'Dessert : Tarte',
        'Fromage : à choisir',
      ]);
    });

    test('un plat garde sa description d\'avant', () {
      final text = mealCalendarDescription(meal([c('accompagnement', 'Riz')]));
      expect(text, contains('Accompagnement : Riz'));
      expect(text, isNot(contains('Plat :')));
    });
  });
}
