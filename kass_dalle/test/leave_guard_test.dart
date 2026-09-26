import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/presentation/leave_guard.dart';
import 'package:kass_dalle/features/recipes/data/book_import_analysis.dart';
import 'package:kass_dalle/features/recipes/data/scan_state.dart';

/// Deux écrans reliés par un bouton qui passe par `goGuarded`, comme le menu de
/// navigation. L'écran A pose un garde ; la question est de savoir si le bouton
/// le respecte.
Widget _app(ProviderContainer container) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => goGuarded(context, ref, '/b'),
              child: const Text('Aller à B'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/b',
        builder: (context, state) => const Scaffold(body: Text('Écran B')),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  group('goGuarded', () {
    testWidgets('sans garde, la navigation part tout de suite', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_app(container));

      await tester.tap(find.text('Aller à B'));
      await tester.pumpAndSettle();

      expect(find.text('Écran B'), findsOneWidget);
    });

    testWidgets('un garde qui refuse garde l\'utilisateur sur l\'écran', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var asked = 0;
      container.read(leaveGuardProvider.notifier).set(() async {
        asked++;
        return false;
      });
      await tester.pumpWidget(_app(container));

      await tester.tap(find.text('Aller à B'));
      await tester.pumpAndSettle();

      expect(asked, 1);
      expect(find.text('Aller à B'), findsOneWidget);
      expect(find.text('Écran B'), findsNothing);
    });

    testWidgets('un garde qui accepte laisse partir', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(leaveGuardProvider.notifier).set(() async => true);
      await tester.pumpWidget(_app(container));

      await tester.tap(find.text('Aller à B'));
      await tester.pumpAndSettle();

      expect(find.text('Écran B'), findsOneWidget);
    });
  });

  group('LeaveGuardNotifier', () {
    test('clearIf ne retire que le garde qu\'on lui passe', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(leaveGuardProvider.notifier);

      Future<bool> ancien() async => true;
      Future<bool> nouveau() async => false;

      notifier.set(nouveau);
      // Un écran qui se ferme retire « son » garde : il ne doit pas emporter
      // celui qu'un autre écran vient de poser.
      notifier.clearIf(ancien);
      expect(container.read(leaveGuardProvider), same(nouveau));

      notifier.clearIf(nouveau);
      expect(container.read(leaveGuardProvider), isNull);
    });
  });

  group('ScanState.isPreparingBook', () {
    test('vrai pendant l\'envoi et en attente du feu vert', () {
      expect(
        const ScanState(
          status: ScanStatus.readingBook,
          bookStep: 'Envoi',
        ).isPreparingBook,
        isTrue,
      );
      expect(
        const ScanState(
          status: ScanStatus.readingBook,
          bookStep: 'Lecture du livre',
        ).isPreparingBook,
        isTrue,
      );
      expect(
        const ScanState(
          status: ScanStatus.pendingBookConfirmation,
          bookAnalysis: BookImportAnalysis(
            kind: 'pdf',
            sizeBytes: 1,
            windows: 1,
            pages: 3,
          ),
        ).isPreparingBook,
        isTrue,
      );
    });

    test('faux à la mise en file : le job existe, rien ne s\'abandonne', () {
      expect(
        const ScanState(
          status: ScanStatus.readingBook,
          bookStep: ScanState.bookStepQueueing,
        ).isPreparingBook,
        isFalse,
      );
    });

    test('faux au repos, en erreur et une fois terminé', () {
      for (final status in [
        ScanStatus.idle,
        ScanStatus.picking,
        ScanStatus.pendingFiles,
        ScanStatus.done,
        ScanStatus.error,
      ]) {
        expect(
          ScanState(status: status).isPreparingBook,
          isFalse,
          reason: '$status',
        );
      }
    });
  });
}
