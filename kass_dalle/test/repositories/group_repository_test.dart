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
