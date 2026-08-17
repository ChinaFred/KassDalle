import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/auth/presentation/pending_approval_screen.dart';

/// Le sas d'entrée, vu du client.
///
/// `resolveRedirect` est le seul endroit de l'application qui décide qui voit
/// quoi ; il doit rester le miroir de `isApproved()` dans `firestore.rules`. Un
/// compte en attente est **authentifié** : le renvoyer vers l'écran de
/// connexion le ferait rebondir vers l'accueil, où les règles lui refuseraient
/// tout sans jamais lui dire pourquoi.
void main() {
  AppUser user({required UserRole role, bool isRevoked = false}) {
    return AppUser(
      uid: 'uid-1',
      email: 'invite@example.test',
      displayName: 'Invité',
      role: role,
      createdAt: DateTime.utc(2026, 8, 1),
      lastSeenAt: DateTime.utc(2026, 8, 1),
      isRevoked: isRevoked,
    );
  }

  String? redirect(AppUser? appUser, String location) =>
      resolveRedirect(user: appUser, isLoading: false, location: location);

  group('aiguillage d\'un compte en attente', () {
    test('depuis n\'importe où, il est mené à la salle d\'attente', () {
      final pending = user(role: UserRole.pending);
      for (final from in [
        AppRoutes.home,
        AppRoutes.recipes,
        AppRoutes.planning,
        AppRoutes.login,
        AppRoutes.adminUsers,
      ]) {
        expect(redirect(pending, from), AppRoutes.pending, reason: from);
      }
    });

    test('une fois dans la salle d\'attente, il y reste', () {
      expect(redirect(user(role: UserRole.pending), AppRoutes.pending), isNull);
    });

    test('nommé lecteur, la salle d\'attente se referme sur l\'accueil', () {
      expect(
        redirect(user(role: UserRole.reader), AppRoutes.pending),
        AppRoutes.home,
      );
    });
  });

  group('les autres états ne passent pas par l\'attente', () {
    test('sans session : connexion', () {
      expect(redirect(null, AppRoutes.home), AppRoutes.login);
    });

    test('révoqué : connexion, avec le motif', () {
      expect(
        redirect(user(role: UserRole.editor, isRevoked: true), AppRoutes.home),
        contains('revoked=true'),
      );
    });

    test('un compte révoqué ET en attente est traité comme révoqué', () {
      expect(
        redirect(user(role: UserRole.pending, isRevoked: true), AppRoutes.home),
        contains('revoked=true'),
      );
    });

    test('un lecteur nommé circule, mais pas dans l\'administration', () {
      final reader = user(role: UserRole.reader);
      expect(redirect(reader, AppRoutes.home), isNull);
      expect(redirect(reader, AppRoutes.adminUsers), AppRoutes.home);
    });

    test('pendant le chargement, rien ne bouge', () {
      expect(
        resolveRedirect(user: null, isLoading: true, location: AppRoutes.home),
        isNull,
      );
    });
  });

  testWidgets('la salle d\'attente affiche l\'adresse à communiquer', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUserProvider.overrideWith(
            (ref) => Stream.value(user(role: UserRole.pending)),
          ),
        ],
        child: const MaterialApp(home: PendingApprovalScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Votre compte attend son approbation'), findsOneWidget);
    expect(find.text('invite@example.test'), findsOneWidget);
    expect(find.text('Se déconnecter'), findsOneWidget);
  });
}
