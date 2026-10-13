import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/meal_suggestion.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';

/// Suggestions de repas : forme écrite, lecture tolérante, et ce que les
/// écrans en calculent (badge, « Au planning », groupes concernés).
void main() {
  MealSuggestion suggestion({
    String id = 's1',
    String groupId = 'gd',
    DateTime? day,
    String? recipeId,
    String? recipeTitre,
    String? freeTitle = 'Lasagnes',
    DateTime? createdAt,
  }) => MealSuggestion(
    id: id,
    groupId: groupId,
    groupOwnerId: 'marie',
    authorUid: 'leo',
    day: day ?? DateTime(2026, 10, 17),
    recipeId: recipeId,
    recipeTitre: recipeTitre,
    freeTitle: recipeId == null ? freeTitle : null,
    createdAt: createdAt,
  );

  group('jour AAAA-MM-JJ', () {
    test('écrit et relit le jour local', () {
      expect(mealSuggestionDayKey(DateTime(2026, 3, 7, 22, 30)), '2026-03-07');
      expect(parseMealSuggestionDay('2026-03-07'), DateTime(2026, 3, 7));
    });

    test('jour mal formé ou impossible : null', () {
      expect(parseMealSuggestionDay('2026-3-7'), isNull);
      expect(parseMealSuggestionDay('2026-02-30'), isNull);
      expect(parseMealSuggestionDay(20260307), isNull);
      expect(parseMealSuggestionDay(null), isNull);
    });
  });

  group('identifiant et bornes du jour', () {
    test('identifiant imposé par les règles', () {
      expect(
        mealSuggestionId(
          groupId: 'gd',
          authorUid: 'leo',
          dayKey: '2026-10-17',
          n: 4,
        ),
        'gd_leo_2026-10-17_4',
      );
    });

    test('dernier jour qu\'on peut viser : aujourd\'hui + 59', () {
      expect(
        lastSuggestionDay(DateTime(2026, 10, 13, 18)),
        DateTime(2026, 12, 11),
      );
    });
  });

  group('MealSuggestionDraft', () {
    final day = DateTime(2026, 10, 17, 15);

    test('une recette : identifiant et titre copié, sans nom libre', () {
      final s = MealSuggestionDraft(
        groupId: 'gd',
        groupOwnerId: 'marie',
        day: day,
        recipeId: 'r1',
        title: '  Lasagnes ',
        note: '  Pour l\'anniversaire de Léo ',
      ).toSuggestion('leo');
      final data = s.toFirestore();
      expect(data['recipe_id'], 'r1');
      expect(data['recipe_titre'], 'Lasagnes');
      expect(data.containsKey('free_title'), isFalse);
      expect(data['note'], 'Pour l\'anniversaire de Léo');
      expect(data['day'], '2026-10-17');
      expect(data['author_uid'], 'leo');
      expect(data['group_owner_id'], 'marie');
      expect(data['created_at'], isA<FieldValue>());
    });

    test(
      'un nom libre : ni recette ni titre copié ; sans mot, pas de note',
      () {
        final data = MealSuggestionDraft(
          groupId: 'gd',
          groupOwnerId: 'marie',
          day: day,
          recipeId: null,
          title: 'Raclette',
        ).toSuggestion('leo').toFirestore();
        expect(data['free_title'], 'Raclette');
        expect(data.containsKey('recipe_id'), isFalse);
        expect(data.containsKey('recipe_titre'), isFalse);
        expect(data.containsKey('note'), isFalse);
      },
    );

    test('bornes : mot tronqué à 200, titre de recette à 200', () {
      final s = MealSuggestionDraft(
        groupId: 'gd',
        groupOwnerId: 'marie',
        day: day,
        recipeId: 'r1',
        title: 'a' * 250,
        note: 'b' * 250,
      ).toSuggestion('leo');
      expect(s.recipeTitre!.length, kSuggestionRecipeTitleMax);
      expect(s.note!.length, kSuggestionNoteMax);
    });

    test('nom libre de plus de 60 caractères ou plat vide : refusé', () {
      final long = MealSuggestionDraft(
        groupId: 'gd',
        groupOwnerId: 'marie',
        day: day,
        recipeId: null,
        title: 'a' * 61,
      );
      expect(long.freeTitleTooLong, isTrue);
      expect(() => long.toSuggestion('leo'), throwsArgumentError);
      expect(
        () => MealSuggestionDraft(
          groupId: 'gd',
          groupOwnerId: 'marie',
          day: day,
          recipeId: null,
          title: '  ',
        ).toSuggestion('leo'),
        throwsArgumentError,
      );
    });
  });

  group('MealSuggestion.fromFirestore', () {
    test('relit une recette et un nom libre', () {
      final created = DateTime(2026, 10, 13, 9);
      final r = MealSuggestion.fromFirestore('s1', {
        'group_id': 'gd',
        'group_owner_id': 'marie',
        'author_uid': 'leo',
        'day': '2026-10-17',
        'recipe_id': 'r1',
        'recipe_titre': 'Lasagnes',
        'note': 'Miam',
        'created_at': Timestamp.fromDate(created),
      })!;
      expect(r.title, 'Lasagnes');
      expect(r.isFreeName, isFalse);
      expect(r.createdAt, created);
      final f = MealSuggestion.fromFirestore('s2', {
        'group_id': 'gd',
        'group_owner_id': 'marie',
        'author_uid': 'leo',
        'day': '2026-10-17',
        'free_title': 'Raclette',
      })!;
      expect(f.title, 'Raclette');
      expect(f.isFreeName, isTrue);
      expect(f.createdAt, isNull);
    });

    test('mal formé : null, jamais d\'exception', () {
      final base = {
        'group_id': 'gd',
        'group_owner_id': 'marie',
        'author_uid': 'leo',
        'day': '2026-10-17',
      };
      expect(MealSuggestion.fromFirestore('x', base), isNull);
      expect(
        MealSuggestion.fromFirestore('x', {
          ...base,
          'day': 'demain',
          'free_title': 'Raclette',
        }),
        isNull,
      );
      expect(
        MealSuggestion.fromFirestore('x', {
          ...base,
          'group_id': 3,
          'free_title': 'Raclette',
        }),
        isNull,
      );
      // Recette sans titre copié : illisible comme recette, rien d'autre.
      expect(
        MealSuggestion.fromFirestore('x', {...base, 'recipe_id': 'r1'}),
        isNull,
      );
    });
  });

  group('calculs d\'affichage', () {
    final today = DateTime(2026, 10, 13, 18);

    test('le badge compte les suggestions d\'aujourd\'hui et après', () {
      final list = [
        suggestion(id: 'a', day: DateTime(2026, 10, 12)),
        suggestion(id: 'b', day: DateTime(2026, 10, 13)),
        suggestion(id: 'c', day: DateTime(2026, 10, 20)),
      ];
      expect(upcomingSuggestionCount(list, today), 2);
      expect(upcomingSuggestionCount(const [], today), 0);
    });

    PlannedMeal meal({
      String? groupId = 'gd',
      String? recipeId,
      String title = 'Gratin',
      DateTime? at,
    }) => PlannedMeal(
      id: 'm',
      uid: 'marie',
      groupId: groupId,
      recipeId: recipeId,
      recipeTitre: title,
      plannedAt: at ?? DateTime(2026, 10, 17, 19),
      durationMinutes: 30,
      createdAt: today,
    );

    test('« Au planning » : même recette, ou même titre sans casse', () {
      final byRecipe = suggestion(recipeId: 'r1', recipeTitre: 'Lasagnes');
      expect(
        plannedMatchFor(byRecipe, [meal(recipeId: 'r1', title: 'Autre')]),
        isNotNull,
      );
      expect(
        plannedMatchFor(suggestion(), [meal(title: ' lasagnes ')]),
        isNotNull,
      );
    });

    test(
      '« Au planning » : autre jour, autre groupe ou repas personnel, non',
      () {
        final s = suggestion();
        expect(
          plannedMatchFor(s, [
            meal(title: 'Lasagnes', at: DateTime(2026, 10, 18, 19)),
          ]),
          isNull,
        );
        expect(
          plannedMatchFor(s, [meal(title: 'Lasagnes', groupId: 'autre')]),
          isNull,
        );
        expect(
          plannedMatchFor(s, [meal(title: 'Lasagnes', groupId: null)]),
          isNull,
        );
        expect(plannedMatchFor(s, [meal()]), isNull);
      },
    );

    test('rangées par jour croissant, puis par ordre d\'arrivée', () {
      final grouped = suggestionsByDay([
        suggestion(
          id: 'tard',
          day: DateTime(2026, 10, 17),
          createdAt: DateTime(2026, 10, 13, 12),
        ),
        suggestion(id: 'attente', day: DateTime(2026, 10, 17)),
        suggestion(
          id: 'tot',
          day: DateTime(2026, 10, 17),
          createdAt: DateTime(2026, 10, 13, 8),
        ),
        suggestion(id: 'avant', day: DateTime(2026, 10, 15)),
      ]);
      expect(grouped.keys, [DateTime(2026, 10, 15), DateTime(2026, 10, 17)]);
      expect(grouped[DateTime(2026, 10, 17)]!.map((s) => s.id), [
        'tot',
        'tard',
        'attente',
      ]);
    });

    test('âge d\'une suggestion', () {
      expect(
        suggestionAgeLabel(DateTime(2026, 10, 13, 1), today),
        'aujourd\'hui',
      );
      expect(suggestionAgeLabel(DateTime(2026, 10, 12, 23), today), 'hier');
      expect(
        suggestionAgeLabel(DateTime(2026, 10, 11, 9), today),
        'il y a 2 jours',
      );
      expect(suggestionAgeLabel(null, today), 'à l\'instant');
      expect(suggestionCountLabel(1), '1 suggestion');
      expect(suggestionCountLabel(2), '2 suggestions');
    });
  });

  group('groupes concernés', () {
    FamilyGroup g(String id, String name, String owner, List<String> members) =>
        FamilyGroup(
          id: id,
          name: name,
          ownerId: owner,
          memberIds: members,
          createdAt: DateTime.utc(2026),
        );

    final groups = [
      g('dupont', 'Famille Dupont', 'marie', ['marie', 'leo']),
      g('cousins', 'Cousins', 'leo', ['leo', 'paul']),
      g('seul', 'Seul', 'leo', ['leo']),
      g('pause', 'En pause', 'jean', ['jean', 'leo']),
    ];
    const reach = PlanningReach(
      groupIds: {'dupont', 'cousins', 'seul'},
      maskedGroupIds: {'pause'},
    );

    test('suggère dans les groupes actifs d\'un autre propriétaire', () {
      expect(
        suggestableGroups(
          groups: groups,
          myUid: 'leo',
          reach: reach,
        ).map((g) => g.id),
        ['dupont'],
      );
    });

    test('reçoit dans ses groupes actifs qui comptent un autre membre', () {
      expect(
        suggestionOwnerGroups(
          groups: groups,
          myUid: 'leo',
          reach: reach,
        ).map((g) => g.id),
        ['cousins'],
      );
    });

    test('portée inconnue : aucun groupe', () {
      expect(
        suggestableGroups(groups: groups, myUid: 'leo', reach: null),
        isEmpty,
      );
      expect(
        suggestionOwnerGroups(groups: groups, myUid: 'leo', reach: null),
        isEmpty,
      );
    });
  });
}
