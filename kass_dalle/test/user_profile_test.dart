import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/auth/data/user_profile_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/domain/user_profile.dart';
import 'package:kass_dalle/features/groups/data/group_repository.dart';

void main() {
  group('UserProfile.displayedName', () {
    test('le nom préféré passe en premier', () {
      const p = UserProfile(
        uid: 'u1',
        displayName: 'Marie Kassbi',
        preferredName: 'Mimi',
      );
      expect(p.displayedName, 'Mimi');
    });

    test('sinon le prénom du compte Google', () {
      const p = UserProfile(uid: 'u1', displayName: 'Marie Kassbi');
      expect(p.displayedName, 'Marie');
    });

    test('sans nom : « Membre », jamais une adresse', () {
      const p = UserProfile(uid: 'u1', displayName: '  ');
      expect(p.displayedName, UserProfile.fallbackName);
    });

    test('compte courant sans nom Google : même nom que son document', () {
      final user = AppUser(
        uid: 'u1',
        email: 'marie@example.com',
        displayName: '',
        role: UserRole.reader,
        createdAt: DateTime(2026),
        lastSeenAt: DateTime(2026),
      );
      expect(user.displayedName, 'marie');
      expect(UserProfile.fromAppUser(user).displayedName, 'marie');
    });

    test('ni nom ni adresse : « Membre » des deux côtés', () {
      final user = AppUser(
        uid: 'u1',
        email: '',
        displayName: '',
        role: UserRole.reader,
        createdAt: DateTime(2026),
        lastSeenAt: DateTime(2026),
      );
      expect(user.displayedName, UserProfile.fallbackName);
      expect(UserProfile.fromAppUser(user).displayedName, 'Membre');
    });

    test('même nom que AppUser.displayedName pour un compte nommé', () {
      final user = AppUser(
        uid: 'u1',
        email: 'marie@example.com',
        displayName: 'Marie Kassbi',
        preferredName: 'Mimi',
        role: UserRole.reader,
        createdAt: DateTime(2026),
        lastSeenAt: DateTime(2026),
      );
      expect(UserProfile.fromAppUser(user).displayedName, user.displayedName);
    });

    test('un document mal formé ne lève pas', () {
      final p = UserProfile.fromFirestore('u1', {
        'display_name': 42,
        'preferred_name': false,
      });
      expect(p.displayName, '');
      expect(p.preferredName, isNull);
      expect(p.displayedName, UserProfile.fallbackName);
    });
  });

  group('UserProfile.truncateName', () {
    test('60 caractères passent tels quels, au-delà ils sont coupés', () {
      final sixty = 'é' * 60;
      expect(UserProfile.truncateName(sixty), sixty);
      expect(UserProfile.truncateName('a' * 61), 'a' * 60);
    });

    test('ne coupe pas un caractère hors du plan de base en deux', () {
      // Un emoji vaut 2 unités UTF-16, comme dans les règles : 30 emoji au plus.
      expect(UserProfile.truncateName('😀' * 61), '😀' * 30);
      // Une coupe qui tomberait au milieu d'une paire recule d'une unité.
      expect(UserProfile.truncateName('a${'😀' * 40}'), 'a${'😀' * 29}');
    });
  });

  group('UserProfileRepository', () {
    test('lit user_profiles, et null si le profil manque', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('user_profiles/u1').set({
        'display_name': 'Marie Kassbi',
        'preferred_name': 'Mimi',
      });
      final repo = UserProfileRepository(firestore: db);
      expect((await repo.getProfile('u1'))?.displayedName, 'Mimi');
      expect(await repo.getProfile('absent'), isNull);
    });
  });

  group('GroupRepository.searchUsers', () {
    test('cherche par nom dans user_profiles, jamais dans users', () async {
      final db = FakeFirebaseFirestore();
      await db.doc('user_profiles/u1').set({'display_name': 'Marie Kassbi'});
      await db.doc('user_profiles/u2').set({
        'display_name': 'Paul Kassbi',
        'preferred_name': 'Popol',
      });
      // Un compte présent dans `users` seulement ne sort pas.
      await db.doc('users/u3').set({
        'display_name': 'Marie Cachée',
        'email': 'marie.cachee@example.com',
      });
      final repo = GroupRepository(firestore: db);

      final marie = await repo.searchUsers('marie');
      expect(marie.map((p) => p.uid), ['u1']);

      final popol = await repo.searchUsers('POPOL');
      expect(popol.map((p) => p.uid), ['u2']);

      expect(await repo.searchUsers('example.com'), isEmpty);
      expect(await repo.searchUsers('   '), isEmpty);
    });
  });
}
