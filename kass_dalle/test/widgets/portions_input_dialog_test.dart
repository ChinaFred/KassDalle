import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/portions_input_dialog.dart';

/// Le dialogue de portions vivait au milieu des 1200 lignes de
/// `cooklang_preview.dart`, hors d'atteinte de tout test. Extrait, il en a.
void main() {
  group('validatePortionsInput', () {
    test('une valeur dans les bornes est acceptée', () {
      expect(
        validatePortionsInput('4', minPortions: 1, maxPortions: 99),
        isNull,
      );
    });

    test('les bornes elles-mêmes sont acceptées', () {
      expect(
        validatePortionsInput('1', minPortions: 1, maxPortions: 99),
        isNull,
      );
      expect(
        validatePortionsInput('99', minPortions: 1, maxPortions: 99),
        isNull,
      );
    });

    test('les espaces autour du nombre sont tolérés', () {
      expect(
        validatePortionsInput('  6  ', minPortions: 1, maxPortions: 99),
        isNull,
      );
    });

    test('ce qui n\'est pas un entier est refusé, en français', () {
      expect(
        validatePortionsInput('quatre', minPortions: 1, maxPortions: 99),
        'Saisis un nombre entier.',
      );
      expect(
        validatePortionsInput('', minPortions: 1, maxPortions: 99),
        'Saisis un nombre entier.',
      );
      expect(
        validatePortionsInput('4.5', minPortions: 1, maxPortions: 99),
        'Saisis un nombre entier.',
      );
    });

    test('hors bornes, le message rappelle les bornes', () {
      expect(
        validatePortionsInput('0', minPortions: 1, maxPortions: 99),
        contains('entre 1 et 99'),
      );
      expect(
        validatePortionsInput('100', minPortions: 1, maxPortions: 99),
        contains('entre 1 et 99'),
      );
    });

    test('un nombre négatif est hors bornes, pas illisible', () {
      expect(
        validatePortionsInput('-3', minPortions: 1, maxPortions: 99),
        contains('entre 1 et 99'),
      );
    });
  });

  group('PortionsInputDialog', () {
    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          locale: Locale('fr'),
          home: Scaffold(
            body: PortionsInputDialog(
              current: 4,
              minPortions: 1,
              maxPortions: 12,
            ),
          ),
        ),
      );
    }

    testWidgets('s\'ouvre garni de la valeur courante', (tester) async {
      await pump(tester);
      expect(find.widgetWithText(TextField, '4'), findsOneWidget);
    });

    testWidgets('une saisie hors bornes affiche l\'erreur sans fermer', (
      tester,
    ) async {
      await pump(tester);

      await tester.enterText(find.byType(TextField), '50');
      await tester.tap(find.text('Valider'));
      await tester.pump();

      expect(find.textContaining('entre 1 et 12'), findsOneWidget);
      expect(find.byType(PortionsInputDialog), findsOneWidget);
    });

    testWidgets('l\'erreur s\'efface dès que l\'utilisateur corrige', (
      tester,
    ) async {
      await pump(tester);

      await tester.enterText(find.byType(TextField), '50');
      await tester.tap(find.text('Valider'));
      await tester.pump();
      expect(find.textContaining('entre 1 et 12'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '5');
      await tester.pump();
      expect(find.textContaining('entre 1 et 12'), findsNothing);
    });
  });
}
