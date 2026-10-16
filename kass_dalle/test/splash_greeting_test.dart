import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
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

/// Tirage fixe : renvoie toujours [value].
class _FixedRandom extends Fake implements Random {
  _FixedRandom(this.value);
  final int value;

  @override
  int nextInt(int max) => value;
}

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  Future<void> pump(
    WidgetTester tester, {
    required Stream<User?> auth,
    required Stream<AppUser?> user,
    DateTime? now,
    int pick = 0,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firebaseAuthStateProvider.overrideWith((ref) => auth),
          appUserProvider.overrideWith((ref) => user),
        ],
        child: MaterialApp(
          home: SplashGreeting(
            now: () => now ?? DateTime(2026, 10, 16, 9, 26),
            random: _FixedRandom(pick),
            child: const Text('accueil'),
          ),
        ),
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

  testWidgets('la seconde ligne donne la date et l\'heure du lancement', (
    tester,
  ) async {
    await pump(
      tester,
      auth: Stream.value(_FakeFirebaseUser()),
      user: Stream.value(_user()),
    );
    await tester.pump();
    expect(find.text('vendredi 16 octobre 2026 · 09:26'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  final slots = <(String, DateTime, int, String)>[
    ('5 h', DateTime(2026, 10, 16, 5), 0, 'Bonjour Fred'),
    ('11 h 59', DateTime(2026, 10, 16, 11, 59), 1, 'Belle matinée, Fred'),
    ('12 h', DateTime(2026, 10, 16, 12), 0, 'Bon après-midi Fred'),
    (
      '17 h 59',
      DateTime(2026, 10, 16, 17, 59),
      2,
      "Les casseroles t'attendent, Fred",
    ),
    ('18 h', DateTime(2026, 10, 16, 18), 0, 'Bonsoir Fred'),
    ('4 h 59', DateTime(2026, 10, 16, 4, 59), 0, 'Bonsoir Fred'),
    ('20 h', DateTime(2026, 10, 16, 20), 5, "C'est l'heure du dîner, Fred ?"),
  ];
  for (final (label, now, pick, expected) in slots) {
    testWidgets('la formule suit la tranche horaire ($label)', (tester) async {
      await pump(
        tester,
        auth: Stream.value(_FakeFirebaseUser()),
        user: Stream.value(_user()),
        now: now,
        pick: pick,
      );
      await tester.pump();
      expect(find.text(expected), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
    });
  }

  testWidgets('une ligne fixe suit la date, absente pendant le chargement', (
    tester,
  ) async {
    await pump(
      tester,
      auth: const Stream<User?>.empty(),
      user: const Stream<AppUser?>.empty(),
    );
    expect(find.text(kSplashTagline), findsNothing);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('la ligne fixe s\'affiche avec la formule et la date', (
    tester,
  ) async {
    await pump(
      tester,
      auth: Stream.value(_FakeFirebaseUser()),
      user: Stream.value(_user()),
    );
    await tester.pump();
    expect(find.text(kSplashTagline), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('sans profil : formule sans prénom, date conservée', (
    tester,
  ) async {
    await pump(
      tester,
      auth: Stream.value(null),
      user: Stream.value(null),
      now: DateTime(2026, 10, 16, 21, 5),
      pick: 1,
    );
    await tester.pump();
    expect(find.text('Bonne soirée'), findsOneWidget);
    expect(find.text('vendredi 16 octobre 2026 · 21:05'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
  });
}
