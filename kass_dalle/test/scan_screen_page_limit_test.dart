import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/features/auth/data/user_preferences_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/processing/presentation/processing_providers.dart';
import 'package:kass_dalle/features/recipes/data/scan_upload_service.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/recipes/presentation/scan/scan_screen.dart';

/// File de pages au-delà de 21 (ticket #156) : la file reste, l'écran dit
/// combien de pages retirer et « Analyser » attend qu'on le fasse.
class _FakeScanNotifier extends ScanUploadNotifier {
  _FakeScanNotifier(this.initial);

  final ScanState initial;
  int processed = 0;

  @override
  ScanState build() => initial;

  /// L'écran remet l'état à zéro en arrivant ; la file du test doit rester.
  @override
  void reset() {}

  @override
  void removePendingPageAt(int index) {
    final names = List<String>.from(state.pendingPageNames)..removeAt(index);
    state = state.copyWith(pendingPageNames: names);
  }

  @override
  Future<void> processPages({
    String? bookId,
    String? bookTitre,
    bool importIllustrations = false,
  }) async {
    processed++;
  }
}

ScanState _pending(int count) => ScanState(
  status: ScanStatus.pendingFiles,
  intent: ScanIntent.recipe,
  pendingPageNames: [for (var i = 1; i <= count; i++) 'page_$i.jpg'],
);

Future<_FakeScanNotifier> _pump(WidgetTester tester, int pages) async {
  final notifier = _FakeScanNotifier(_pending(pages));
  final container = ProviderContainer(
    overrides: [
      appUserProvider.overrideWith(
        (ref) => Stream.value(
          AppUser(
            uid: 'u1',
            email: 'u1@example.com',
            displayName: 'Utilisateur',
            role: UserRole.editor,
            createdAt: DateTime(2026),
            lastSeenAt: DateTime(2026),
          ),
        ),
      ),
      scanUploadProvider.overrideWith(() => notifier),
      userPreferencesProvider.overrideWith(
        (ref) async => const UserPreferences(),
      ),
      myBooksOrderedProvider.overrideWithValue(const AsyncData(<Book>[])),
      activeProcessingJobsCountProvider.overrideWithValue(0),
    ],
  );
  addTearDown(container.dispose);
  final router = GoRouter(
    initialLocation: '/scan',
    routes: [GoRoute(path: '/scan', builder: (_, _) => const ScanScreen())],
  );
  tester.view.physicalSize = const Size(1200, 6000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
  return notifier;
}

FilledButton _analyse(WidgetTester tester) => tester.widget<FilledButton>(
  find.ancestor(
    of: find.textContaining('Analyser ('),
    matching: find.byWidgetPredicate((w) => w is FilledButton),
  ),
);

void main() {
  testWidgets('22 pages : titre, ligne d\'erreur, « Analyser » désactivé ; '
      'une page retirée le réactive', (tester) async {
    final notifier = await _pump(tester, 22);

    expect(find.text('Pages à analyser (22 sur 21 au plus)'), findsOneWidget);
    // Sous le titre, et au-dessus de « Analyser ».
    expect(
      find.text("Retirez 1 page pour lancer l'analyse."),
      findsNWidgets(2),
    );
    expect(_analyse(tester).onPressed, isNull);

    await tester.tap(find.byTooltip('Supprimer cette page').first);
    await tester.pump();

    expect(find.text('Pages à analyser (21)'), findsOneWidget);
    expect(find.textContaining('Retirez'), findsNothing);
    expect(_analyse(tester).onPressed, isNotNull);
    await tester.tap(find.textContaining('Analyser ('));
    await tester.pump();
    expect(notifier.processed, 1);
  });

  testWidgets('25 pages : « Retirez 4 pages », au pluriel', (tester) async {
    await _pump(tester, 25);
    expect(find.text('Pages à analyser (25 sur 21 au plus)'), findsOneWidget);
    expect(
      find.text("Retirez 4 pages pour lancer l'analyse."),
      findsNWidgets(2),
    );
  });
}
