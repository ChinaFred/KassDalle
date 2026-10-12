import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/planning/data/planning_visibility_store.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/domain/planning_visibility.dart';

/// Plannings partagés (v0.23.46) : le lecteur lit les plannings partagés, il
/// ne planifie plus ; l'éditeur choisit les groupes qui voient le sien.
void main() {
  group('plannings affichés par défaut', () {
    const me = 'moi';
    final available = [me, 'marie', 'paul'];

    test('éditeur : son planning seul', () {
      expect(
        displayedPlannings(
          available: available,
          myUid: me,
          canPlan: true,
          toggled: const {},
        ),
        [me],
      );
    });

    test('lecteur : tous les partagés, pas le sien', () {
      expect(
        displayedPlannings(
          available: available,
          myUid: me,
          canPlan: false,
          toggled: const {},
        ),
        ['marie', 'paul'],
      );
    });

    test('une bascule inverse le défaut, pour chaque rôle', () {
      expect(
        displayedPlannings(
          available: available,
          myUid: me,
          canPlan: true,
          toggled: const {'marie'},
        ),
        [me, 'marie'],
      );
      expect(
        displayedPlannings(
          available: available,
          myUid: me,
          canPlan: false,
          toggled: const {me, 'paul'},
        ),
        [me, 'marie'],
      );
    });

    test('un planning reçu après coup suit le défaut du rôle', () {
      expect(
        displayedPlannings(
          available: [...available, 'zoe'],
          myUid: me,
          canPlan: true,
          toggled: const {'marie'},
        ),
        [me, 'marie'],
      );
    });

    test('basculer deux fois revient au défaut', () {
      final once = togglePlanning(const {}, 'marie');
      expect(once, {'marie'});
      expect(togglePlanning(once, 'marie'), isEmpty);
    });
  });

  group('libellé du bouton-puce', () {
    test('aucun, un, deux, au-delà', () {
      expect(planningSelectorLabel(const []), 'Plannings : aucun');
      expect(planningSelectorLabel(const ['Moi']), 'Plannings : Moi');
      expect(
        planningSelectorLabel(const ['Moi', 'Marie']),
        'Plannings : Moi, Marie',
      );
      expect(
        planningSelectorLabel(const ['Moi', 'Marie', 'Paul', 'Zoé']),
        'Plannings : Moi, Marie, +2',
      );
    });
  });

  group('mémoire des bascules', () {
    test('une clé par compte et par rôle', () async {
      final store = InMemoryPlanningVisibilityStore();
      await store.save({'marie'}, uid: 'u1', canPlan: true);
      expect(await store.load(uid: 'u1', canPlan: true), {'marie'});
      expect(await store.load(uid: 'u1', canPlan: false), isEmpty);
      expect(await store.load(uid: 'u2', canPlan: true), isEmpty);
    });
  });

  group('shared_group_ids', () {
    test('absent : rien n\'est partagé', () {
      expect(PlanningPreferences.fromFirestore(const {}).sharedGroupIds, []);
    });

    test('lu sans doublon ni valeur mal formée, réécrit tel quel', () {
      final prefs = PlanningPreferences.fromFirestore({
        'shared_group_ids': ['g1', 3, '', 'g2', 'g1', null],
      });
      expect(prefs.sharedGroupIds, ['g1', 'g2']);
      expect(prefs.toFirestore()['shared_group_ids'], ['g1', 'g2']);
    });

    test('mauvais type : liste vide', () {
      expect(
        PlanningPreferences.fromFirestore({
          'shared_group_ids': 'g1',
        }).sharedGroupIds,
        [],
      );
    });

    test('copyWith le garde, ou le remplace', () {
      const prefs = PlanningPreferences(sharedGroupIds: ['g1']);
      expect(prefs.copyWith(mealsPerCycle: 5).sharedGroupIds, ['g1']);
      expect(prefs.copyWith(sharedGroupIds: []).sharedGroupIds, isEmpty);
    });
  });

  group('écrans de planification réservés aux éditeurs', () {
    AppUser user(UserRole role) => AppUser(
      uid: 'uid-1',
      email: 'u@example.test',
      displayName: 'U',
      role: role,
      createdAt: DateTime.utc(2026, 8, 1),
      lastSeenAt: DateTime.utc(2026, 8, 1),
    );

    String? redirect(UserRole role, String location) =>
        resolveRedirect(user: user(role), isLoading: false, location: location);

    test('le lecteur est renvoyé au planning, avec le message', () {
      for (final route in [
        AppRoutes.batchPlanning,
        AppRoutes.planningConfig,
        AppRoutes.myStaples,
      ]) {
        expect(
          redirect(UserRole.reader, route),
          '${AppRoutes.planning}?$kPlanningReservedParam=1',
          reason: route,
        );
      }
    });

    test('le lecteur garde le planning lui-même', () {
      expect(redirect(UserRole.reader, AppRoutes.planning), isNull);
    });

    test('l\'éditeur et l\'administrateur passent', () {
      for (final role in [UserRole.editor, UserRole.admin]) {
        for (final route in kPlanningEditorRoutes) {
          expect(redirect(role, route), isNull, reason: '$role $route');
        }
      }
    });
  });
}
