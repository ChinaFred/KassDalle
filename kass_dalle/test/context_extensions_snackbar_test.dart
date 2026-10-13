import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/context_extensions.dart';

/// Un SnackBar avec action disparaît après sa durée et se ferme par une croix
/// (ticket #69 : depuis Flutter 3.29, il restait affiché indéfiniment).
void main() {
  Future<BuildContext> pumpHost(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return captured;
  }

  SnackBarAction voir() => SnackBarAction(label: 'Voir', onPressed: () {});

  final variants = <String, void Function(BuildContext, SnackBarAction)>{
    'succès': (c, a) => c.showSuccessSnackBar('Ticket envoyé.', action: a),
    'erreur': (c, a) => c.showErrorSnackBar('Échec.', action: a),
    'neutre': (c, a) => c.showSnackBar('Info.', action: a),
  };

  for (final entry in variants.entries) {
    testWidgets('${entry.key} avec action : disparaît après sa durée', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      entry.value(context, voir());
      // Le minuteur de la durée part à la fin de l'animation d'entrée.
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('${entry.key} avec action : une croix le ferme', (
      tester,
    ) async {
      final context = await pumpHost(tester);
      entry.value(context, voir());
      await tester.pumpAndSettle();
      final close = find.byIcon(Icons.close);
      expect(close, findsOneWidget);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });
  }

  testWidgets('sans action : pas de croix', (tester) async {
    final context = await pumpHost(tester);
    context.showSuccessSnackBar('Enregistré.');
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('avec action et lecteur d\'écran : reste affiché', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(accessibleNavigation: true),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                captured = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    captured.showSuccessSnackBar('Liste remplacée.', action: voir());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('avec action : encore visible à 6 s', (tester) async {
    final context = await pumpHost(tester);
    context.showErrorSnackBar('Échec.', action: voir());
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
