import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/domain/planning_target.dart';
import 'package:kass_dalle/features/planning/domain/planning_visibility.dart';
import 'package:kass_dalle/features/planning/presentation/planning_target_sheet.dart';

/// Planning de groupe : un repas porte `group_id`, le propriétaire du groupe
/// y planifie, ses membres le lisent.
void main() {
  FamilyGroup familyGroup(
    String id,
    String name, {
    String owner = 'moi',
    List<String> members = const ['moi', 'marie'],
  }) => FamilyGroup(
    id: id,
    name: name,
    ownerId: owner,
    memberIds: members,
    createdAt: DateTime.utc(2026),
  );

  group('PlannedMeal.groupId', () {
    final at = DateTime(2026, 10, 16, 19);

    test('un repas de groupe écrit et relit group_id', () {
      final meal = PlannedMeal(
        id: '',
        uid: 'moi',
        groupId: 'gd',
        recipeTitre: 'Gratin',
        plannedAt: at,
        durationMinutes: 30,
        createdAt: at,
      );
      final data = meal.toFirestore();
      expect(data['group_id'], 'gd');
      final read = PlannedMeal.fromFirestore('m1', data);
      expect(read.groupId, 'gd');
      expect(read.isGroupMeal, isTrue);
    });

    test('un repas personnel n\'écrit pas group_id', () {
      final meal = PlannedMeal(
        id: '',
        uid: 'moi',
        recipeTitre: 'Gratin',
        plannedAt: at,
        durationMinutes: 30,
        createdAt: at,
      );
      expect(meal.toFirestore().containsKey('group_id'), isFalse);
    });

    test('un repas antérieur au champ est personnel', () {
      final read = PlannedMeal.fromFirestore('m1', {
        'uid': 'moi',
        'recipe_titre': 'Gratin',
        'planned_at': Timestamp.fromDate(at),
        'created_at': Timestamp.fromDate(at),
      });
      expect(read.groupId, isNull);
      expect(read.isGroupMeal, isFalse);
      expect(PlannedMeal.groupIdFrom(''), isNull);
      expect(PlannedMeal.groupIdFrom(42), isNull);
    });
  });

  group('PlanningReach', () {
    test('lit les trois listes, sans le titulaire', () {
      final reach = PlanningReach.fromMap({
        'uids': ['marie', 'moi', 3],
        'group_ids': ['gd'],
        'masked_group_ids': ['gm'],
      }, 'moi');
      expect(reach.uids, {'marie'});
      expect(reach.readsGroup('gd'), isTrue);
      expect(reach.masks('gm'), isTrue);
      expect(reach.isEmpty, isFalse);
    });

    test('document antérieur : groupes inconnus, rien de masqué', () {
      final reach = PlanningReach.fromMap({'uids': <String>[]}, 'moi');
      expect(reach.groupIds, isNull);
      expect(reach.readsGroup('gd'), isFalse);
      expect(reach.masks('gd'), isFalse);
      expect(reach.isEmpty, isTrue);
    });

    test('un groupe lisible suffit à ne pas être vide', () {
      final reach = PlanningReach.fromMap({
        'uids': <String>[],
        'group_ids': ['gd'],
      }, 'moi');
      expect(reach.isEmpty, isFalse);
    });

    test('sans document : vide', () {
      expect(PlanningReach.fromMap(null, 'moi'), PlanningReach.empty);
    });
  });

  group('visibilité des plannings de groupe', () {
    test('cochés par défaut, quel que soit le rôle', () {
      final key = groupPlanningKey('gd');
      for (final canPlan in [true, false]) {
        expect(
          displayedPlannings(
            available: ['moi', 'marie', key],
            myUid: 'moi',
            canPlan: canPlan,
            toggled: const {},
          ),
          contains(key),
        );
      }
    });

    test('la clé désigne le groupe, et rien d\'autre', () {
      expect(groupIdOfPlanningKey(groupPlanningKey('gd')), 'gd');
      expect(groupIdOfPlanningKey('marie'), isNull);
    });
  });

  group('cible du planning', () {
    test('les groupes possédés, non masqués, par nom', () {
      final groups = [
        familyGroup('g2', 'Zèbres'),
        familyGroup('g1', 'Amis'),
        familyGroup('g3', 'Cousins', owner: 'marie'),
        familyGroup('g4', 'Masqué'),
      ];
      final owned = ownedPlanningGroups(
        groups: groups,
        myUid: 'moi',
        canPlan: true,
        reach: const PlanningReach(maskedGroupIds: {'g4'}),
      );
      expect(owned.map((g) => g.id), ['g1', 'g2']);
    });

    test('un lecteur ne planifie pour aucun groupe', () {
      expect(
        ownedPlanningGroups(
          groups: [familyGroup('g1', 'Amis')],
          myUid: 'moi',
          canPlan: false,
        ),
        isEmpty,
      );
    });

    test('libellés de « Planifier pour… »', () {
      const mine = PlanningTarget.personal();
      expect(mine.title, 'Mon planning');
      expect(mine.subtitle, isNull);
      final dupont = PlanningTarget.ofGroup(
        familyGroup('gd', 'Famille Dupont', members: ['moi', 'marie', 'paul']),
      );
      expect(dupont.title, 'Famille Dupont');
      expect(dupont.subtitle, 'Planning du groupe · 3 membres');
    });

    test('parts par défaut : réglées, sinon le nombre de membres', () {
      final g = familyGroup('gd', 'Famille', members: ['moi', 'marie', 'paul']);
      expect(groupDefaultPortions(groupPortions: const {}, group: g), 3);
      expect(groupDefaultPortions(groupPortions: const {'gd': 6}, group: g), 6);
      expect(groupMemberCount(familyGroup('x', 'x', members: ['moi'])), 1);
    });

    test('group_portions : seuls les entiers positifs', () {
      expect(
        PlanningPreferences.groupPortionsFrom({
          'gd': 4,
          'g0': 0,
          'gx': '4',
          '': 2,
        }),
        {'gd': 4},
      );
      expect(PlanningPreferences.groupPortionsFrom('x'), isEmpty);
    });

    test('adresse de « Nouveau planning »', () {
      expect(batchPlanningLocation(), '/planning/batch');
      expect(batchPlanningLocation(groupId: 'gd'), '/planning/batch?group=gd');
    });
  });
}
