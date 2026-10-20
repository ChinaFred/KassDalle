import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/core/presentation/leave_guard.dart';
import 'package:kass_dalle/features/auth/data/auth_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/account_screen.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';

/// Compte la déconnexion ; l'enregistrement du nom préféré échoue comme sans
/// réseau ; tout autre appel échoue.
class _FakeAuthRepository implements AuthRepository {
  int signOuts = 0;

  @override
  Future<void> signOut() async => signOuts++;

  @override
  Future<void> updatePreferredName(String uid, String? name) async =>
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
        message: 'Failed to get document because the client is offline.',
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// La déconnexion échoue comme sans réseau.
class _OfflineAuthRepository implements AuthRepository {
  @override
  Future<void> signOut() async => throw FirebaseException(
    plugin: 'firebase_auth',
    code: 'network-request-failed',
    message: 'A network error has occurred, the client is offline.',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Retient les rapports d'erreur au lieu de les écrire dans Firestore.
class _FakeErrorReports extends Fake implements ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'id';
  }
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

  testWidgets('déconnexion en échec : deux phrases, en erreur, sans texte '
      'technique', (tester) async {
    final reports = _FakeErrorReports();
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        appUserProvider.overrideWith(
          (ref) => Stream.value(_user(displayName: 'Zoé')),
        ),
        authRepositoryProvider.overrideWithValue(_OfflineAuthRepository()),
        errorReportServiceProvider.overrideWithValue(reports),
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

    await tester.tap(find.text('Se déconnecter'));
    await tester.pumpAndSettle();

    expect(
      find.text('Déconnexion non effectuée. Connexion perdue.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);
    expect(find.textContaining('firebase_auth'), findsNothing);
    expect(reports.features, ['leaveGuard.signOutGuarded']);
  });

  testWidgets('profil illisible : état d’erreur avec « Réessayer », pas une '
      'roue sans fin', (tester) async {
    final container = ProviderContainer(
      // Sans réessai automatique : aucun minuteur ne survit au test.
      retry: (_, _) => null,
      overrides: [
        appUserProvider.overrideWith(
          (ref) => Stream<AppUser?>.error(
            FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
          ),
        ),
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

    expect(find.text('Profil non chargé'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('nom préféré non enregistré : deux phrases, en erreur, sans '
      'texte technique', (tester) async {
    await _open(tester, _user(displayName: 'Zoé'), _FakeAuthRepository());

    await tester.tap(find.text('Nom préféré'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Zozo');
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.text('Nom préféré non enregistré. Connexion perdue.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('offline'), findsNothing);
  });

  testWidgets('profil refusé : conseil de reconnexion, pas celui d’un livre', (
    tester,
  ) async {
    final container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        appUserProvider.overrideWith(
          (ref) => Stream<AppUser?>.error(
            FirebaseException(
              plugin: 'cloud_firestore',
              code: 'permission-denied',
            ),
          ),
        ),
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

    expect(find.text('Profil non chargé'), findsOneWidget);
    expect(find.text(kProfileDeniedAdvice), findsOneWidget);
    expect(find.textContaining('livre'), findsNothing);
  });
}
