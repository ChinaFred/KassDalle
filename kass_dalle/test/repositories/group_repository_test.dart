import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/groups/data/group_repository.dart';

/// Invitations et portée des groupes, sur un Firestore en mémoire.
///
/// Les règles Firestore n'admettent qu'une forme d'écriture pour chaque
/// geste (voir `rules-tests`) : ces tests vérifient que le repository écrit
/// bien cette forme-là.
void main() {
  late FakeFirebaseFirestore firestore;
  late GroupRepository repo;

  setUp(() async {
    firestore = FakeFirebaseFirestore();
    repo = GroupRepository(firestore: firestore);
    await firestore.collection('groups').doc('g1').set({
      'name': 'Famille',
      'owner_id': 'owner',
      'member_ids': ['owner'],
      'created_at': DateTime.utc(2026, 10, 1),
    });
  });

  Future<Map<String, dynamic>> readGroup() async =>
      (await firestore.collection('groups').doc('g1').get()).data()!;

  test('inviter n\'ajoute pas aux membres', () async {
    await repo.inviteMember('g1', 'invite');

    final data = await readGroup();
    expect(data['member_ids'], ['owner']);
    expect(data['invited_ids'], ['invite']);
  });

  test('accepter fait passer des invités aux membres', () async {
    await repo.inviteMember('g1', 'invite');
    await repo.acceptInvitation('g1', 'invite');

    final data = await readGroup();
    expect(data['member_ids'], ['owner', 'invite']);
    expect(data['invited_ids'], isEmpty);
  });

  test('refuser ou annuler retire l\'invitation seule', () async {
    await repo.inviteMember('g1', 'invite');
    await repo.withdrawInvitation('g1', 'invite');

    final data = await readGroup();
    expect(data['member_ids'], ['owner']);
    expect(data['invited_ids'], isEmpty);
  });

  test('l\'invité voit l\'invitation, pas le groupe', () async {
    await repo.inviteMember('g1', 'invite');

    final invitations = await repo.watchMyInvitations('invite').first;
    final groups = await repo.watchMyGroups('invite').first;

    expect(invitations.map((g) => g.id), ['g1']);
    expect(invitations.single.invitedIds, ['invite']);
    expect(groups, isEmpty);
  });

  group('groupes en pause', () {
    test('un groupe en pause reste listé, et se lit dans la portée', () async {
      await firestore.collection('groups').doc('g2').set({
        'name': 'Cousins',
        'owner_id': 'owner',
        'member_ids': ['owner'],
        'created_at': DateTime.utc(2026, 10, 2),
      });
      await firestore.collection('planning_reach').doc('owner').set({
        'uids': <String>[],
        'group_ids': ['g1'],
        'masked_group_ids': ['g2'],
      });

      final groups = await repo.watchMyGroups('owner').first;
      expect(groups.map((g) => g.id), ['g1', 'g2']);
      expect(await repo.watchMaskedGroupIds('owner').first, {'g2'});
    });

    test('sans portée, ou portée antérieure : rien en pause', () async {
      expect(await repo.watchMaskedGroupIds('owner').first, isEmpty);
      await firestore.collection('planning_reach').doc('owner').set({
        'uids': <String>[],
      });
      expect(await repo.watchMaskedGroupIds('owner').first, isEmpty);
    });

    test('une invitation vers un groupe en pause est masquée', () async {
      await repo.inviteMember('g1', 'invite');
      await firestore.collection('groups').doc('g3').set({
        'name': 'Voisins',
        'owner_id': 'autre',
        'member_ids': ['autre'],
        'invited_ids': ['invite'],
        'created_at': DateTime.utc(2026, 10, 3),
      });
      await firestore.collection('planning_reach').doc('invite').set({
        'uids': <String>[],
        'masked_invitation_ids': ['g3'],
      });

      final invitations = await repo.watchMyInvitations('invite').first;
      expect(invitations.map((g) => g.id), ['g1']);
    });
  });

  group('watchReach', () {
    test('sans document de portée : vide', () async {
      expect(await repo.watchReach('owner').first, isEmpty);
    });

    test('rend les autres comptes, sans le titulaire', () async {
      await firestore.collection('group_reach').doc('owner').set({
        'uids': ['a', 'owner', 'b'],
      });

      expect(await repo.watchReach('owner').first, {'a', 'b'});
    });
  });
}
