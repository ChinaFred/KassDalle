import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/leave_guard.dart';
import 'package:kass_dalle/features/books/presentation/book_form_screen.dart';

/// Un écran d'accueil qui pousse le formulaire de création d'un livre.
Future<ProviderContainer> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const BookFormScreen(),
                  ),
                ),
                child: const Text('ouvrir'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('ouvrir'));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _goBack(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'un titre saisi : le retour demande, « Rester » garde la saisie',
    (tester) async {
      await _open(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Titre du livre *'),
        'Cuisine de Mamie',
      );

      await _goBack(tester);
      expect(find.text('Quitter sans enregistrer ?'), findsOneWidget);
      expect(find.text('Ce livre ne sera pas créé.'), findsOneWidget);

      await tester.tap(find.text('Rester'));
      await tester.pumpAndSettle();
      expect(find.byType(BookFormScreen), findsOneWidget);
      expect(find.text('Cuisine de Mamie'), findsOneWidget);

      await _goBack(tester);
      await tester.tap(find.text('Quitter'));
      await tester.pumpAndSettle();
      expect(find.byType(BookFormScreen), findsNothing);
    },
  );

  testWidgets('un formulaire intact se quitte sans question', (tester) async {
    await _open(tester);
    await _goBack(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(BookFormScreen), findsNothing);
  });

  testWidgets('le garde posé pour la navigation pose la même question', (
    tester,
  ) async {
    final container = await _open(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Auteur *'),
      'Mamie',
    );
    final guard = container.read(leaveGuardProvider);
    expect(guard, isNotNull);

    final answer = guard!();
    await tester.pumpAndSettle();
    expect(find.text('Quitter sans enregistrer ?'), findsOneWidget);
    await tester.tap(find.text('Rester'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });
}
