import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';

/// Atelier repas : lecture du menu rendu, puce « Modifié » entre deux tours,
/// « Menu inchangé », compteur du jour, parts par défaut, identifiant de
/// conversation. Fonctions pures, sans Firebase.
void main() {
  Map<String, dynamic> course(
    String role,
    String title, {
    String? recipeId,
    String? label,
    List<Map<String, dynamic>> sides = const [],
    bool unknown = false,
    String? description,
    String? why,
  }) => {
    'role': role,
    'course_label': label,
    'title': title,
    'description': description,
    'recipe_id': recipeId,
    'why': why,
    'sides': sides,
    'unknown_recipe_id': unknown,
  };

  WorkshopMenu menu(List<Map<String, dynamic>> courses, {int portions = 4}) =>
      WorkshopMenu.fromJson({'portions': portions, 'courses': courses});

  group('lecture du menu rendu', () {
    test('rôles, libellé « Autre », recette liée et accompagnements', () {
      final m = menu([
        course('entree', 'Velouté', why: 'Ouvre sur du chaud.'),
        course(
          'plat',
          'Blanquette de veau',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz', 'recipe_id': null},
            {'label': 'Carottes glacées', 'staple_id': null, 'recipe_id': null},
          ],
        ),
        course('autre', 'Trou normand', label: 'Trou normand'),
        course('dessert', 'Tarte aux poires', unknown: true),
      ]);
      expect(m.portions, 4);
      expect(m.courses.length, 4);
      expect(m.courses[0].role, MealComponentRole.entree);
      expect(m.courses[0].typeLabel, 'Entrée');
      expect(m.courses[0].why, 'Ouvre sur du chaud.');
      expect(m.courses[1].isLinked, isTrue);
      expect(m.courses[1].isToWrite, isFalse);
      expect(m.courses[1].sides.map((s) => s.label), [
        'Riz',
        'Carottes glacées',
      ]);
      expect(m.courses[1].sides[0].stapleId, 'riz');
      expect(m.courses[2].typeLabel, 'Trou normand');
      expect(m.courses[3].unknownRecipeId, isTrue);
      expect(m.courses[3].isLinked, isFalse);
      expect(m.toWriteCount, 3);
      expect(m.linkedCount, 1);
      expect(m.canFreeze, isTrue);
    });

    test('un rôle inconnu se lit « Autre », un menu sans courses est vide', () {
      final m = menu([course('pizza', 'Quatre fromages')]);
      expect(m.courses.single.role, MealComponentRole.autre);
      expect(WorkshopMenu.fromJson(const {'portions': 6}).isEmpty, isTrue);
      expect(WorkshopMenu.fromJson(const {'portions': 6}).canFreeze, isFalse);
    });

    test('un menu de recettes liées seules n\'a rien à rédiger', () {
      final m = menu([course('plat', 'Rôti', recipeId: 'r1')]);
      expect(m.canFreeze, isFalse);
      expect(m.toWriteCount, 0);
    });

    test('toJson ne renvoie pas les marqueurs du contrôle', () {
      final m = menu([course('plat', 'Rôti', unknown: true)]);
      final json = m.toJson();
      expect(json['portions'], 4);
      final c = (json['courses'] as List).single as Map<String, dynamic>;
      expect(c.containsKey('unknown_recipe_id'), isFalse);
      expect(c['role'], 'plat');
      expect(c['title'], 'Rôti');
    });

    test('lier, délier, remplacer et retirer un service', () {
      final m = menu([
        course('entree', 'Velouté'),
        course('plat', 'Blanquette', recipeId: 'r1'),
      ]);
      final linked = m.withCourse(
        0,
        m.courses[0].linkedTo(recipeId: 'r9', title: 'Velouté de potimarron'),
      );
      expect(linked.courses[0].recipeId, 'r9');
      expect(linked.courses[0].title, 'Velouté de potimarron');
      expect(linked.courses[0].isLinked, isTrue);
      final unlinked = linked.withCourse(1, linked.courses[1].unlinked());
      expect(unlinked.courses[1].recipeId, isNull);
      expect(unlinked.courses[1].title, 'Blanquette');
      final removed = unlinked.withoutCourse(0);
      expect(removed.courses.map((c) => c.title), ['Blanquette']);
      expect(removed.portions, 4);
    });

    test('une réponse sans menu est refusée', () {
      expect(
        () => WorkshopTurnResult.fromJson(const {'reponse': 'x'}),
        throwsFormatException,
      );
    });

    test('la réponse complète est lue, avec le compteur du jour', () {
      final result = WorkshopTurnResult.fromJson({
        'reponse': ' Je vous propose… ',
        'reponseTruncated': true,
        'menu': {'portions': 4, 'courses': <Object>[]},
        'control': {'truncated': true, 'offKindCourses': 2},
        'turn': 3,
        'quota': {'limit': 30, 'remaining': 27},
      });
      expect(result.reponse, 'Je vous propose…');
      expect(result.reponseTruncated, isTrue);
      expect(result.control.truncated, isTrue);
      expect(result.control.offKindCourses, 2);
      expect(result.turn, 3);
      expect(result.quota?.limit, 30);
      expect(result.quota?.remaining, 27);
    });

    test('un contrôle ou un compteur absents ne cassent rien', () {
      final result = WorkshopTurnResult.fromJson({
        'menu': {'portions': 4, 'courses': <Object>[]},
      });
      expect(result.control.offKindCourses, 0);
      expect(result.control.truncated, isFalse);
      expect(result.quota, isNull);
      expect(result.turn, 1);
    });
  });

  group('puce « Modifié »', () {
    final previous = menu([
      course('entree', 'Velouté'),
      course(
        'plat',
        'Blanquette',
        recipeId: 'r1',
        sides: [
          {'label': 'Riz', 'staple_id': 'riz'},
        ],
      ),
      course('dessert', 'Tarte aux poires'),
    ]);

    test('sans menu précédent, tout est nouveau', () {
      expect(changedCourseIndexes(null, previous), {0, 1, 2});
    });

    test('un dessert remplacé marque le dessert seul', () {
      final next = menu([
        course('entree', 'Velouté'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz'},
          ],
        ),
        course('dessert', 'Mousse au chocolat'),
      ]);
      expect(changedCourseIndexes(previous, next), {2});
    });

    test('un accompagnement changé marque le plat', () {
      final next = menu([
        course('entree', 'Velouté'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Pommes vapeur', 'staple_id': null},
          ],
        ),
        course('dessert', 'Tarte aux poires'),
      ]);
      expect(changedCourseIndexes(previous, next), {1});
    });

    test('un service inséré ne marque pas ceux qui suivent', () {
      final next = menu([
        course('entree', 'Velouté'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz'},
          ],
        ),
        course('sorbet', 'Sorbet citron'),
        course('dessert', 'Tarte aux poires'),
      ]);
      expect(changedCourseIndexes(previous, next), {2});
    });

    test('description ou raison reformulées ne marquent rien', () {
      final next = menu([
        course('entree', 'Velouté', description: 'Doux et lisse.', why: 'x'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz'},
          ],
        ),
        course('dessert', 'Tarte aux poires'),
      ]);
      expect(changedCourseIndexes(previous, next), isEmpty);
    });
  });

  group('« Menu inchangé »', () {
    final a = menu([course('plat', 'Rôti', why: 'Simple.')]);

    test('un JSON identique est inchangé', () {
      expect(
        sameMenu(a, menu([course('plat', 'Rôti', why: 'Simple.')])),
        isTrue,
      );
    });

    test(
      'une raison reformulée, ou des parts changées, n\'est pas inchangé',
      () {
        expect(
          sameMenu(a, menu([course('plat', 'Rôti', why: 'Autre.')])),
          isFalse,
        );
        expect(
          sameMenu(
            a,
            menu([course('plat', 'Rôti', why: 'Simple.')], portions: 6),
          ),
          isFalse,
        );
      },
    );

    test('sans menu précédent, jamais inchangé', () {
      expect(sameMenu(null, a), isFalse);
    });
  });

  group('compteur du jour', () {
    test('rendu par le serveur : lu, borné à zéro', () {
      final q = WorkshopQuota.fromJson({'limit': 30, 'remaining': 27})!;
      expect(q.limit, 30);
      expect(q.remaining, 27);
      expect(q.exhausted, isFalse);
      expect(
        WorkshopQuota.fromJson({'limit': 30, 'remaining': -1})!.remaining,
        0,
      );
      expect(WorkshopQuota.fromJson({'limit': 30}), isNull);
      expect(WorkshopQuota.fromJson('x'), isNull);
    });

    test(
      'lu dans meal_workshop_daily : limit - count, ou 30 sans document',
      () {
        final absent = WorkshopQuota.fromDaily(null)!;
        expect(absent.limit, kWorkshopDailyLimit);
        expect(absent.remaining, kWorkshopDailyLimit);
        final some = WorkshopQuota.fromDaily({'count': 3, 'limit': 30})!;
        expect(some.remaining, 27);
        final founder = WorkshopQuota.fromDaily({'count': 10, 'limit': 3000})!;
        expect(founder.limit, 3000);
        expect(founder.remaining, 2990);
        final over = WorkshopQuota.fromDaily({'count': 31, 'limit': 30})!;
        expect(over.remaining, 0);
        expect(over.exhausted, isTrue);
        // Sans plafond écrit : le plafond par défaut.
        expect(WorkshopQuota.fromDaily({'count': 5})!.remaining, 25);
        // Un compteur mal formé : inconnu, jamais une valeur plausible.
        expect(WorkshopQuota.fromDaily({'count': 'trois'}), isNull);
      },
    );

    test('la clé du jour est la date UTC AAAA-MM-JJ, comme le serveur', () {
      expect(workshopDayKey(DateTime.utc(2026, 11, 6, 23, 59)), '2026-11-06');
      expect(workshopDayKey(DateTime.utc(2026, 1, 1)), '2026-01-01');
      // Un instant local est ramené au jour UTC, quel que soit le fuseau de
      // l'appareil : à 0 h 30 à Paris le 7, le serveur est encore le 6.
      expect(
        workshopDayKey(DateTime.utc(2026, 11, 6, 23, 30).toLocal()),
        '2026-11-06',
      );
      expect(
        workshopDayKey(DateTime.utc(2026, 11, 7, 0, 30).toLocal()),
        '2026-11-07',
      );
    });

    test('la phrase du compteur, accordée', () {
      expect(
        remainingTurnsLine(const WorkshopQuota(limit: 30, remaining: 27)),
        'Il vous reste 27 tours aujourd\'hui.',
      );
      expect(
        remainingTurnsLine(const WorkshopQuota(limit: 30, remaining: 1)),
        'Il vous reste 1 tour aujourd\'hui.',
      );
      expect(
        remainingTurnsLine(const WorkshopQuota(limit: 30, remaining: 0)),
        'Vous avez fait vos 30 tours d\'aujourd\'hui. Le compteur repart '
        'demain.',
      );
      expect(exhaustedTurnsLine(60), startsWith('Vous avez fait vos 60 tours'));
    });

    test('« 4 parts », « 1 part »', () {
      expect(workshopPortionsLabel(4), '4 parts');
      expect(workshopPortionsLabel(1), '1 part');
    });
  });

  group('parts par défaut', () {
    FamilyGroup group(
      String id, {
      required DateTime createdAt,
      List<String> members = const ['moi', 'a', 'b'],
    }) => FamilyGroup(
      id: id,
      name: 'Groupe $id',
      ownerId: 'moi',
      memberIds: members,
      createdAt: createdAt,
    );

    test('aucun groupe : 4', () {
      expect(
        defaultMealWorkshopPortions(
          groups: const [],
          pausedGroupIds: const {},
          groupPortions: const {},
        ),
        kWorkshopDefaultPortions,
      );
    });

    test('deux groupes : le plus ancien gagne, par son nombre de membres', () {
      final older = group(
        'g1',
        createdAt: DateTime(2025, 1, 1),
        members: const ['moi', 'a', 'b', 'c', 'd'],
      );
      final newer = group('g2', createdAt: DateTime(2026, 1, 1));
      expect(
        defaultMealWorkshopPortions(
          groups: [newer, older],
          pausedGroupIds: const {},
          groupPortions: const {},
        ),
        5,
      );
    });

    test('le plus ancien en pause : le suivant', () {
      final older = group(
        'g1',
        createdAt: DateTime(2025, 1, 1),
        members: const ['moi', 'a', 'b', 'c', 'd'],
      );
      final newer = group('g2', createdAt: DateTime(2026, 1, 1));
      expect(
        defaultMealWorkshopPortions(
          groups: [older, newer],
          pausedGroupIds: const {'g1'},
          groupPortions: const {},
        ),
        3,
      );
      // Tous en pause : 4.
      expect(
        defaultMealWorkshopPortions(
          groups: [older, newer],
          pausedGroupIds: const {'g1', 'g2'},
          groupPortions: const {},
        ),
        kWorkshopDefaultPortions,
      );
    });

    test('« Parts des groupes » prioritaire sur le nombre de membres', () {
      final g = group('g1', createdAt: DateTime(2025, 1, 1));
      expect(
        defaultMealWorkshopPortions(
          groups: [g],
          pausedGroupIds: const {},
          groupPortions: const {'g1': 8},
        ),
        8,
      );
    });
  });

  group('identifiant de conversation', () {
    test('24 caractères de [A-Za-z0-9_-], différents à chaque tirage', () {
      final a = newWorkshopConversationId(Random(1));
      final b = newWorkshopConversationId(Random(2));
      expect(a.length, kWorkshopConversationIdLength);
      expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(a), isTrue);
      expect(a, isNot(b));
      expect(newWorkshopConversationId().length, kWorkshopConversationIdLength);
    });
  });
}
