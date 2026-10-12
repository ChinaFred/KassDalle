import 'dart:async';

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

  group('TokenClaimsAligner', () {
    /// Un jeton dont les claims suivent le compte au bout de [lagReads]
    /// lectures renouvelées.
    ({TokenClaimsAligner aligner, List<bool> reads}) fake(int lagReads) {
      final reads = <bool>[];
      var refreshed = 0;
      final aligner = TokenClaimsAligner(
        delay: Duration.zero,
        readClaims: ({required bool refresh}) async {
          reads.add(refresh);
          if (refresh) refreshed++;
          return refreshed >= lagReads
              ? {'role': 'reader', 'revoked': false}
              : {'role': 'reader', 'revoked': true};
        },
      );
      return (aligner: aligner, reads: reads);
    }

    Future<void> noError(Object e, StackTrace st) async =>
        fail('erreur inattendue : $e');

    test('jeton à jour : aucun renouvellement', () async {
      final f = fake(0);
      final r = await f.aligner.start(
        user(),
        onAligned: () => fail('pas de seconde émission'),
        onGiveUp: (_) async => fail('pas de rapport'),
        onError: noError,
      );
      expect(r, TokenAlignStart.inStep);
      expect(f.reads, [false]);
    });

    test('rattrapé pendant l\'attente courte : émis aligné', () async {
      final f = fake(2);
      final r = await f.aligner.start(
        user(),
        onAligned: () => fail('pas de seconde émission'),
        onGiveUp: (_) async => fail('pas de rapport'),
        onError: noError,
      );
      expect(r, TokenAlignStart.aligned);
      expect(f.reads, [false, true, true]);
    });

    test('rattrapé après l\'émission : seconde émission, une fois', () async {
      final f = fake(5);
      final aligned = Completer<void>();
      final r = await f.aligner.start(
        user(),
        onAligned: aligned.complete,
        onGiveUp: (_) async => fail('pas de rapport'),
        onError: noError,
      );
      expect(r, TokenAlignStart.continuing);
      await aligned.future;
      expect(f.reads.where((x) => x).length, 5);
    });

    test('écart persistant : rapporté une fois, jamais relancé', () async {
      final f = fake(1000);
      final gaveUp = Completer<Map<String, dynamic>?>();
      final r = await f.aligner.start(
        user(),
        onAligned: () => fail('jamais aligné'),
        onGiveUp: (claims) async => gaveUp.complete(claims),
        onError: noError,
      );
      expect(r, TokenAlignStart.continuing);
      expect(await gaveUp.future, {'role': 'reader', 'revoked': true});
      expect(f.reads.where((x) => x).length, kTokenAlignAttempts);

      final before = f.reads.length;
      final again = await f.aligner.start(
        user(),
        onAligned: () => fail('jamais aligné'),
        onGiveUp: (_) async => fail('pas de second rapport'),
        onError: noError,
      );
      expect(again, TokenAlignStart.alreadyTried);
      expect(f.reads.length, before + 1);
    });

    test('un autre état du compte est tenté à son tour', () async {
      final f = fake(1000);
      final gaveUp = Completer<void>();
      await f.aligner.start(
        user(),
        onAligned: () {},
        onGiveUp: (_) async => gaveUp.complete(),
        onError: noError,
      );
      await gaveUp.future;
      final other = await f.aligner.start(
        user(role: UserRole.editor),
        onAligned: () {},
        onGiveUp: (_) async {},
        onError: noError,
      );
      expect(other, TokenAlignStart.continuing);
    });

    test('erreur de lecture après l\'émission : passée à onError', () async {
      var calls = 0;
      final aligner = TokenClaimsAligner(
        delay: Duration.zero,
        readClaims: ({required bool refresh}) async {
          calls++;
          if (calls > 3) throw StateError('réseau');
          return {'role': 'reader', 'revoked': true};
        },
      );
      final error = Completer<Object>();
      final r = await aligner.start(
        user(),
        onAligned: () => fail('jamais aligné'),
        onGiveUp: (_) async => fail('pas de rapport'),
        onError: (e, _) async => error.complete(e),
      );
      expect(r, TokenAlignStart.continuing);
      expect(await error.future, isA<StateError>());
    });
  });
}
