import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/splash_greeting.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';

class _FakeFirebaseUser extends Fake implements User {}

AppUser _user({String? preferred}) => AppUser(
  uid: 'u1',
  email: 'fred@example.com',
  displayName: 'Fred Martin',
  preferredName: preferred,
  role: UserRole.reader,
  createdAt: DateTime(2026),
  lastSeenAt: DateTime(2026),
);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required Stream<User?> auth,
    required Stream<AppUser?> user,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseAuthStateProvider.overrideWith((ref) => auth),
          appUserProvider.overrideWith((ref) => user),
        ],
        child: const MaterialApp(home: SplashGreeting(child: Text('accueil'))),
      ),
    );
    await tester.pump();
  }

  testWidgets('affiche « Bonjour {prénom} » puis se retire après 5 s', (
    tester,
  ) async {
    await pump(
      tester,
      auth: Stream.value(_FakeFirebaseUser()),
      user: Stream.value(_user()),
    );
    await tester.pump();
    expect(find.text('Bonjour Fred'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Bonjour Fred'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Bonjour Fred'), findsNothing);
    expect(find.text('accueil'), findsOneWidget);
  });

  testWidgets('le nom préféré remplace le prénom Google', (tester) async {
    await pump(
      tester,
      auth: Stream.value(_FakeFirebaseUser()),
      user: Stream.value(_user(preferred: 'Fredo')),
    );
    await tester.pump();
    expect(find.text('Bonjour Fredo'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('un appui ferme l\'écran avant 5 s', (tester) async {
    await pump(
      tester,
      auth: Stream.value(_FakeFirebaseUser()),
      user: Stream.value(_user()),
    );
    await tester.pump();
    await tester.tap(find.text('Bonjour Fred'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Bonjour Fred'), findsNothing);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('non connecté : « Bonjour » seul', (tester) async {
    await pump(tester, auth: Stream.value(null), user: Stream.value(null));
    await tester.pump();
    expect(find.text('Bonjour'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('profil jamais chargé : « Bonjour » seul à 10 s, fermé ensuite', (
    tester,
  ) async {
    await pump(
      tester,
      auth: Stream.value(_FakeFirebaseUser()),
      user: const Stream<AppUser?>.empty(),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Bonjour'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('accueil'), findsOneWidget);
  });
}
