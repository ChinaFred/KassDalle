import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/auth/data/auth_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';

/// Le jeton suit-il le document du compte ? Un compte révoqué rétabli à sa
/// reconnexion (`applyRevokedInvitation`) garde sinon un jeton `revoked: true`
/// que les règles croient, jusqu'à une heure.
void main() {
  AppUser user({UserRole role = UserRole.reader, bool revoked = false}) =>
      AppUser(
        uid: 'gab',
        email: 'gabriel@gmail.com',
        displayName: 'Gabriel',
        role: role,
        createdAt: DateTime(2026),
        lastSeenAt: DateTime(2026),
        isRevoked: revoked,
      );

  test('jeton révoqué, compte rétabli : en retard', () {
    expect(
      tokenLagsBehind({'role': 'reader', 'revoked': true}, user()),
      isTrue,
    );
  });

  test('rôle du jeton différent du rôle nommé : en retard', () {
    expect(
      tokenLagsBehind({
        'role': 'reader',
        'revoked': false,
      }, user(role: UserRole.editor)),
      isTrue,
    );
    expect(
      tokenLagsBehind({
        'role': 'pending',
        'revoked': false,
      }, user(role: UserRole.reader)),
      isTrue,
    );
  });

  test('jeton à jour, ou sans claim : rien à faire', () {
    expect(
      tokenLagsBehind({'role': 'reader', 'revoked': false}, user()),
      isFalse,
    );
    expect(tokenLagsBehind({}, user()), isFalse);
    expect(tokenLagsBehind(null, user()), isFalse);
  });

  test('compte révoqué ou en attente : jamais de renouvellement', () {
    expect(
      tokenLagsBehind({
        'role': 'editor',
        'revoked': false,
      }, user(revoked: true)),
      isFalse,
    );
    expect(
      tokenLagsBehind({
        'role': 'reader',
        'revoked': true,
      }, user(role: UserRole.pending)),
      isFalse,
    );
  });
}
