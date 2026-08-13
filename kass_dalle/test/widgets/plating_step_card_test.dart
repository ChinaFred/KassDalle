import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/plating_advice.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/dressing_coach_widgets.dart';

/// Verrouillage des actions pendant une génération.
///
/// Les visuels se construisent l'un sur l'autre : deux générations lancées en
/// parallèle produiraient deux assiettes concurrentes, et la série cesserait de
/// raconter un montage. Le bouton reste visible — le faire disparaître
/// laisserait croire que l'action n'existe pas — mais il ne répond plus.

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));
}

void main() {
  const etapeSansVisuel = PlatingStep(titre: 'Le lit', geste: 'Étaler le confit.');

  testWidgets('une étape sans visuel propose de l\'illustrer', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        PlatingStepCard(
          index: 0,
          step: etapeSansVisuel,
          onGenerateImage: () => tapped = true,
        ),
      ),
    );

    await tester.tap(find.text('Illustrer cette étape'));
    expect(tapped, isTrue);
  });

  testWidgets('pendant une génération ailleurs, le bouton reste visible mais inerte', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        PlatingStepCard(
          index: 1,
          step: etapeSansVisuel,
          busy: true,
          onGenerateImage: () => tapped = true,
        ),
      ),
    );

    expect(find.text('Illustrer cette étape'), findsOneWidget);
    await tester.tap(find.text('Illustrer cette étape'));
    expect(tapped, isFalse);
  });

  testWidgets('l\'étape en cours affiche son attente, pas un bouton', (tester) async {
    await tester.pumpWidget(
      _host(
        PlatingStepCard(
          index: 0,
          step: etapeSansVisuel,
          generating: true,
          busy: true,
          onGenerateImage: () {},
        ),
      ),
    );

    expect(find.text('Création du visuel de montage…'), findsOneWidget);
    expect(find.text('Illustrer cette étape'), findsNothing);
  });

  testWidgets('sans droit d\'édition, aucune action n\'est proposée', (tester) async {
    await tester.pumpWidget(
      _host(const PlatingStepCard(index: 0, step: etapeSansVisuel)),
    );

    expect(find.text('Illustrer cette étape'), findsNothing);
    expect(find.text('Étaler le confit.'), findsOneWidget);
  });
}
