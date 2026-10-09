import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/presentation/leave_guard.dart';
import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/features/auth/data/user_preferences_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/processing/presentation/processing_providers.dart';
import 'package:kass_dalle/features/recipes/data/scan_upload_service.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/recipes/presentation/scan/scan_screen.dart';

/// Le notifier réel ouvre Firebase dès sa construction. Celui-ci ne garde que
/// ce que l'écran lui demande, et compte ce qu'on lui demande.
class _FakeScanNotifier extends ScanUploadNotifier {
  _FakeScanNotifier(this.initial);

  final ScanState initial;
  int cancelled = 0;
  int resets = 0;

  @override
  ScanState build() => initial;

  @override
  Future<void> cancelBookImport() async {
    cancelled++;
    state = const ScanState();
  }

  @override
  void reset() {
    resets++;
  }
}

Widget _app(_FakeScanNotifier notifier, ProviderContainer container) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => context.push('/scan?mode=book-document'),
              child: const Text('Accueil'),
            ),
          ),
        ),
        routes: [
          GoRoute(
            path: 'scan',
            builder: (context, state) => const ScanScreen(),
          ),
        ],
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

AppUser _user(UserRole role) => AppUser(
  uid: 'u1',
  email: 'u1@example.com',
  displayName: 'Utilisateur',
  role: role,
  createdAt: DateTime(2026),
  lastSeenAt: DateTime(2026),
);

ProviderContainer _container(
  _FakeScanNotifier notifier, {
  UserRole role = UserRole.editor,
  Stream<AppUser?>? userStream,
}) {
  return ProviderContainer(
    overrides: [
      appUserProvider.overrideWith(
        (ref) => userStream ?? Stream.value(_user(role)),
      ),
      scanUploadProvider.overrideWith(() => notifier),
      userPreferencesProvider.overrideWith(
        (ref) async => const UserPreferences(),
      ),
      myBooksOrderedProvider.overrideWithValue(const AsyncData(<Book>[])),
      activeProcessingJobsCountProvider.overrideWithValue(0),
    ],
  );
}

/// Une phrase que seul le formulaire d'import affiche (mode livre entier).
const _formMarker = 'Importez un livre en PDF, EPUB ou Word';

/// Laisse passer les animations sans attendre qu'elles s'arrêtent : la barre de
/// progression d'un livre en cours d'envoi tourne tant que l'écran est ouvert,
/// et `pumpAndSettle` n'en verrait jamais la fin.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> _openScan(WidgetTester tester) async {
  await tester.tap(find.text('Accueil'));
  await _settle(tester);
  expect(find.text('Importer un scan'), findsOneWidget);
}

void main() {
  testWidgets(
    'retour pendant l\'envoi : la question est posée, « Continuer » garde tout',
    (tester) async {
      final notifier = _FakeScanNotifier(
        const ScanState(
          status: ScanStatus.readingBook,
          bookStep: 'Envoi',
          filename: 'livre.pdf',
        ),
      );
      final container = _container(notifier);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(notifier, container));
      await _openScan(tester);
      final resetsAtArrival = notifier.resets;

      await tester.tap(find.byType(BackButton));
      await _settle(tester);

      expect(find.text('Envoi du livre en cours'), findsOneWidget);
      expect(find.text('Continuer'), findsOneWidget);
      expect(find.text('Annuler l\'import'), findsOneWidget);

      await tester.tap(find.text('Continuer'));
      await _settle(tester);

      // L'utilisateur est resté, et le retour au premier plan de l'écran n'a
      // pas remis le livre à zéro.
      expect(find.text('Importer un scan'), findsOneWidget);
      expect(notifier.cancelled, 0);
      expect(notifier.resets, resetsAtArrival);
    },
  );

  testWidgets(
    'retour pendant l\'envoi : « Annuler l\'import » abandonne le livre et quitte',
    (tester) async {
      final notifier = _FakeScanNotifier(
        const ScanState(
          status: ScanStatus.readingBook,
          bookStep: 'Envoi',
          filename: 'livre.pdf',
        ),
      );
      final container = _container(notifier);
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(notifier, container));
      await _openScan(tester);

      await tester.tap(find.byType(BackButton));
      await _settle(tester);
      await tester.tap(find.text('Annuler l\'import'));
      await _settle(tester);

      expect(notifier.cancelled, 1);
      expect(find.text('Importer un scan'), findsNothing);
      expect(find.text('Accueil'), findsOneWidget);
    },
  );

  testWidgets('livre lu, import non lancé : le message le dit', (tester) async {
    final notifier = _FakeScanNotifier(
      const ScanState(
        status: ScanStatus.pendingBookConfirmation,
        filename: 'livre.pdf',
      ),
    );
    final container = _container(notifier);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(notifier, container));
    await _openScan(tester);

    await tester.tap(find.byType(BackButton));
    await _settle(tester);

    expect(find.text('Import du livre non lancé'), findsOneWidget);
    expect(
      find.textContaining('le fichier envoyé est supprimé'),
      findsOneWidget,
    );
  });

  testWidgets('la navigation du menu passe par le même garde', (tester) async {
    final notifier = _FakeScanNotifier(
      const ScanState(
        status: ScanStatus.readingBook,
        bookStep: 'Envoi',
        filename: 'livre.pdf',
      ),
    );
    final container = _container(notifier);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(notifier, container));
    await _openScan(tester);

    // Le garde est posé après le premier rendu.
    final guard = container.read(leaveGuardProvider);
    expect(guard, isNotNull);

    final answer = guard!();
    await _settle(tester);
    expect(find.text('Envoi du livre en cours'), findsOneWidget);

    await tester.tap(find.text('Continuer'));
    await _settle(tester);
    expect(await answer, isFalse);
    expect(notifier.cancelled, 0);
  });

  testWidgets('au repos, rien ne retient l\'utilisateur', (tester) async {
    final notifier = _FakeScanNotifier(const ScanState());
    final container = _container(notifier);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(notifier, container));
    await _openScan(tester);

    expect(container.read(leaveGuardProvider), isNull);

    await tester.tap(find.byType(BackButton));
    await _settle(tester);

    expect(find.text('Envoi du livre en cours'), findsNothing);
    expect(find.text('Accueil'), findsOneWidget);
  });

  testWidgets('un lecteur arrivé par un lien voit que l\'import est réservé', (
    tester,
  ) async {
    final notifier = _FakeScanNotifier(const ScanState());
    final container = _container(notifier, role: UserRole.reader);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(notifier, container));
    await tester.tap(find.text('Accueil'));
    await _settle(tester);

    expect(find.text('Importer un scan'), findsOneWidget);
    expect(find.text('Import réservé aux éditeurs'), findsOneWidget);
    expect(find.text('Retour à la bibliothèque'), findsOneWidget);
    // Ni formulaire, ni remise à zéro de l'import : l'écran ne touche à rien.
    expect(find.textContaining(_formMarker), findsNothing);
    expect(notifier.resets, 0);
  });

  testWidgets('tant que le rôle n\'est pas lu, ni formulaire ni refus', (
    tester,
  ) async {
    final notifier = _FakeScanNotifier(const ScanState());
    // Un flux qui n'émet jamais : le compte reste en cours de lecture.
    final pendingUser = StreamController<AppUser?>();
    addTearDown(pendingUser.close);
    final container = _container(notifier, userStream: pendingUser.stream);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(notifier, container));
    await tester.tap(find.text('Accueil'));
    await _settle(tester);

    expect(find.text('Importer un scan'), findsOneWidget);
    expect(find.byType(AppLoadingState), findsOneWidget);
    expect(find.textContaining(_formMarker), findsNothing);
    expect(find.text('Import réservé aux éditeurs'), findsNothing);
    expect(notifier.resets, 0);
  });

  testWidgets(
    'un compte sans profil voit le refus, pas un chargement sans fin',
    (tester) async {
      final notifier = _FakeScanNotifier(const ScanState());
      final container = _container(
        notifier,
        userStream: Stream<AppUser?>.value(null),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(notifier, container));
      await tester.tap(find.text('Accueil'));
      await _settle(tester);

      expect(find.text('Import réservé aux éditeurs'), findsOneWidget);
      expect(find.byType(AppLoadingState), findsNothing);
    },
  );

  testWidgets('un éditeur voit le formulaire', (tester) async {
    final notifier = _FakeScanNotifier(const ScanState());
    final container = _container(notifier);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(notifier, container));
    await _openScan(tester);

    expect(find.textContaining(_formMarker), findsOneWidget);
    expect(find.text('Import réservé aux éditeurs'), findsNothing);
  });
}
