import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/admin/data/admin_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';

/// Le sas d'entrée et la révocation, vus du client.
///
/// Ces assertions doivent rester le miroir de `firestore.rules` : `canRead` de
/// `isApproved()`, `canEdit` de `isEditor()`. Un client plus permissif que les
/// règles n'ouvre rien de plus — il affiche des écrans vides et des erreurs de
/// permission au lieu de dire ce qui manque.
void main() {
  Map<String, dynamic> userDoc({
    String uid = 'uid-1',
    String? role,
    bool isRevoked = false,
    DateTime? createdAt,
  }) {
    return {
      'uid': uid,
      'email': '$uid@example.test',
      'display_name': 'Compte $uid',
      'role': ?role,
      'created_at': Timestamp.fromDate(createdAt ?? DateTime.utc(2026, 1, 1)),
      'last_seen_at': Timestamp.fromDate(DateTime.utc(2026, 8, 1)),
      'is_revoked': isRevoked,
    };
  }

  group('rôle lu depuis Firestore', () {
    test('un rôle absent vaut « en attente », jamais « lecteur »', () {
      final user = AppUser.fromFirestore(userDoc());
      expect(user.role, UserRole.pending);
      expect(user.isPending, isTrue);
      expect(user.canRead, isFalse);
    });

    test('un rôle inconnu vaut « en attente »', () {
      final user = AppUser.fromFirestore(userDoc(role: 'superadmin'));
      expect(user.role, UserRole.pending);
      expect(user.canRead, isFalse);
    });

    test('les trois rôles nommés se relisent tels quels', () {
      expect(
        AppUser.fromFirestore(userDoc(role: 'reader')).role,
        UserRole.reader,
      );
      expect(
        AppUser.fromFirestore(userDoc(role: 'editor')).role,
        UserRole.editor,
      );
      expect(
        AppUser.fromFirestore(userDoc(role: 'admin')).role,
        UserRole.admin,
      );
    });
  });

  group('ce qu’un rôle ouvre', () {
    test('un compte en attente ne lit rien et n’écrit rien', () {
      final user = AppUser.fromFirestore(userDoc(role: 'pending'));
      expect(user.canRead, isFalse);
      expect(user.canEdit, isFalse);
      expect(user.isAdmin, isFalse);
    });

    test('un lecteur lit sans écrire', () {
      final user = AppUser.fromFirestore(userDoc(role: 'reader'));
      expect(user.canRead, isTrue);
      expect(user.canEdit, isFalse);
      expect(user.isAdmin, isFalse);
    });

    test('un éditeur écrit sans administrer', () {
      final user = AppUser.fromFirestore(userDoc(role: 'editor'));
      expect(user.canEdit, isTrue);
      expect(user.isAdmin, isFalse);
    });
  });

  group('la révocation mord sur tous les rôles', () {
    test('un éditeur révoqué n’écrit plus et ne lit plus', () {
      final user = AppUser.fromFirestore(
        userDoc(role: 'editor', isRevoked: true),
      );
      expect(user.canEdit, isFalse);
      expect(user.canRead, isFalse);
    });

    test('un administrateur révoqué n’administre plus', () {
      final user = AppUser.fromFirestore(
        userDoc(role: 'admin', isRevoked: true),
      );
      expect(user.isAdmin, isFalse);
      expect(user.canEdit, isFalse);
      expect(user.canRead, isFalse);
    });
  });

  group('liste d’administration', () {
    test(
      'les comptes en attente passent devant, le reste garde son ordre',
      () async {
        final firestore = FakeFirebaseFirestore();
        await firestore
            .collection('users')
            .doc('ancien')
            .set(
              userDoc(
                uid: 'ancien',
                role: 'editor',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            );
        await firestore
            .collection('users')
            .doc('recent')
            .set(
              userDoc(
                uid: 'recent',
                role: 'reader',
                createdAt: DateTime.utc(2026, 6, 1),
              ),
            );
        await firestore
            .collection('users')
            .doc('arrivant')
            .set(
              userDoc(
                uid: 'arrivant',
                role: 'pending',
                createdAt: DateTime.utc(2026, 8, 1),
              ),
            );

        final users = await AdminRepository(
          firestore: firestore,
        ).watchAllUsers().first;

        expect(users.map((u) => u.uid), ['arrivant', 'ancien', 'recent']);
      },
    );
  });

  // Miroir des règles `recipes` et `books` de `firestore.rules` (v0.23.8) :
  // on ne modifie que son propre contenu, éditeur compris ; l'administrateur
  // agit comme le créateur.
  group('propriété du contenu', () {
    AppUser user(String role, {bool isRevoked = false}) =>
        AppUser.fromFirestore(
          userDoc(uid: 'moi', role: role, isRevoked: isRevoked),
        );

    test('un éditeur ne modifie ni la recette ni le livre d\'un autre', () {
      expect(user('editor').canModifyRecipe('autre'), isFalse);
      expect(user('editor').canModifyBook('autre'), isFalse);
      expect(user('editor').canModifyRecipe('moi'), isTrue);
      expect(user('editor').canModifyBook('moi'), isTrue);
    });

    test('un lecteur modifie sa recette, pas un livre', () {
      expect(user('reader').canModifyRecipe('moi'), isTrue);
      expect(user('reader').canModifyBook('moi'), isFalse);
    });

    test('un administrateur modifie le contenu de tous', () {
      expect(user('admin').canModifyRecipe('autre'), isTrue);
      expect(user('admin').canModifyBook('autre'), isTrue);
    });

    test('un created_by vide n\'appartient à personne', () {
      expect(user('editor').canModifyRecipe(''), isFalse);
    });

    test('révoqué ou en attente : rien', () {
      expect(user('editor', isRevoked: true).canModifyRecipe('moi'), isFalse);
      expect(user('pending').canModifyRecipe('moi'), isFalse);
    });
  });
}
