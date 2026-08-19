import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';

/// Le bouton « Planifier avec l'IA » des grands écrans.
///
/// Il remplace une baguette magique posée dans un coin de la barre de titre :
/// une icône seule n'apprend pas ce qu'elle fait, et c'est pourtant l'action
/// principale de l'écran — sans elle, il n'y a rien à valider.
void main() {
  List<PopupMenuEntry<int>> menu() => const [
    PopupMenuItem(value: 0, child: Text('Compléter les créneaux vides')),
    PopupMenuItem(value: 1, child: Text('Tout regénérer')),
  ];

  Future<void> pump(
    WidgetTester tester, {
    bool generating = false,
    bool enabled = true,
    int emptySlots = 3,
    void Function(int)? onSelected,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: PlanWithAiButton(
              generating: generating,
              enabled: enabled,
              emptySlots: emptySlots,
              itemBuilder: menu,
              onSelected: onSelected ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('le bouton annonce ce qui reste à remplir', (tester) async {
    await pump(tester, emptySlots: 3);
    expect(
      find.text('Planifier avec l\'IA (3 créneaux vides)'),
      findsOneWidget,
    );
  });

  testWidgets('un seul créneau vide reste au singulier', (tester) async {
    await pump(tester, emptySlots: 1);
    expect(find.text('Planifier avec l\'IA (1 créneau vide)'), findsOneWidget);
  });

  testWidgets('sans créneau vide, le bouton ne compte rien', (tester) async {
    await pump(tester, emptySlots: 0);
    expect(find.text('Planifier avec l\'IA'), findsOneWidget);
  });

  testWidgets('les deux façons de générer restent offertes', (tester) async {
    int? chosen;
    await pump(tester, onSelected: (v) => chosen = v);

    await tester.tap(find.byType(PlanWithAiButton));
    await tester.pumpAndSettle();

    // Compléter et regénérer ne sont pas la même chose : la seconde efface le
    // travail déjà fait à l'écran, et ce choix ne doit pas se faire par mégarde.
    expect(find.text('Compléter les créneaux vides'), findsOneWidget);
    expect(find.text('Tout regénérer'), findsOneWidget);

    await tester.tap(find.text('Tout regénérer'));
    await tester.pumpAndSettle();
    expect(chosen, 1);
  });

  testWidgets('pendant la génération, il le dit et n\'ouvre rien', (
    tester,
  ) async {
    await pump(tester, generating: true);

    expect(find.text('Planification en cours…'), findsOneWidget);
    await tester.tap(find.byType(PlanWithAiButton));
    // `pump` et non `pumpAndSettle` : l'indicateur de progression tourne sans
    // fin, et attendre l'immobilité de l'arbre n'arriverait jamais.
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Tout regénérer'), findsNothing);
  });

  testWidgets('tant que les recettes ne sont pas chargées, il n\'ouvre rien', (
    tester,
  ) async {
    await pump(tester, enabled: false);

    await tester.tap(find.byType(PlanWithAiButton));
    await tester.pumpAndSettle();
    expect(find.text('Compléter les créneaux vides'), findsNothing);
  });
}
