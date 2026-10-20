import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/leave_guard.dart';
import 'package:kass_dalle/features/auth/data/auth_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/account_screen.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';

/// Compte la déconnexion ; tout autre appel échoue.
class _FakeAuthRepository implements AuthRepository {
  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AppUser _user({String displayName = '', UserRole role = UserRole.reader}) =>
    AppUser(
      uid: 'uid-123',
      email: 'zoe@example.com',
      displayName: displayName,
      role: role,
      createdAt: DateTime(2026, 1, 1),
      lastSeenAt: DateTime(2026, 10, 1),
    );

Future<ProviderContainer> _open(
  WidgetTester tester,
  AppUser user,
  _FakeAuthRepository auth,
) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      appUserProvider.overrideWith((ref) => Stream.value(user)),
      authRepositoryProvider.overrideWithValue(auth),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: AccountScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('nom Google vide : initiale de l’e-mail et rôle en français', (
    tester,
  ) async {
    await _open(tester, _user(), _FakeAuthRepository());

    expect(find.text('Z'), findsOneWidget);
    expect(find.text('Lecteur'), findsWidgets);
    expect(find.text('reader'), findsNothing);
    expect(find.text('READER'), findsNothing);
    expect(find.text('Aucune photo'), findsOneWidget);
    expect(find.text('Aucun nom'), findsOneWidget);
  });

  testWidgets('l’identifiant du compte est réservé à l’administrateur', (
    tester,
  ) async {
    await _open(tester, _user(displayName: 'Zoé'), _FakeAuthRepository());
    expect(find.text('Identifiant du compte'), findsNothing);
    expect(find.text('uid-123'), findsNothing);
  });

  testWidgets('un administrateur voit l’identifiant du compte', (tester) async {
    await _open(
      tester,
      _user(displayName: 'Zoé', role: UserRole.admin),
      _FakeAuthRepository(),
    );
    expect(find.text('Identifiant du compte'), findsOneWidget);
    expect(find.text('Administrateur'), findsWidgets);
  });

  testWidgets('un garde qui refuse empêche la déconnexion', (tester) async {
    final auth = _FakeAuthRepository();
    final container = await _open(tester, _user(displayName: 'Zoé'), auth);
    var asked = 0;
    container.read(leaveGuardProvider.notifier).set(() async {
      asked++;
      return false;
    });

    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();

    expect(asked, 1);
    expect(auth.signOuts, 0);
  });

  testWidgets('sans garde, la déconnexion part sans question', (tester) async {
    final auth = _FakeAuthRepository();
    await _open(tester, _user(displayName: 'Zoé'), auth);

    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.signOuts, 1);
  });
}
