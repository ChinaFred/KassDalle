import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';

/// La disposition de « Nouveau planning » selon la largeur.
///
/// Grand écran : un panneau à gauche (cycle, consignes, « Planifier avec
/// l'IA », « Valider »), la grille des créneaux à droite, et plus de barre
/// du bas. Téléphone : les consignes repliées en tête de liste, « Valider »
/// seul en bas.
void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  Future<void> pumpAt(WidgetTester tester, Size logical) async {
    // La largeur lue par l'écran vient de la vue, pas de la surface.
    tester.view.physicalSize = logical;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          // Sans repository, l'écran ne charge rien : seule la disposition
          // est en jeu.
          planningRepositoryProvider.overrideWithValue(null),
          // Sans consignes : le titre replié doit dire « vide ».
          planningPreferencesOnceProvider.overrideWith(
            (ref) async => const PlanningPreferences(globalConstraints: ''),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('fr'),
          home: BatchPlanningScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('grand écran : panneau à gauche, pas de barre du bas', (
    tester,
  ) async {
    await pumpAt(tester, const Size(1400, 900));

    expect(tester.takeException(), isNull);
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(find.byType(PlanWithAiButton), findsOneWidget);
    expect(find.textContaining('Valider le planning'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.bottomNavigationBar, isNull);
    // Les consignes sont ouvertes dans le panneau, sans pli.
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.text('Consignes du cycle'), findsOneWidget);
    expect(find.byType(BatchSlotTile), findsWidgets);
    expect(find.text('Ajouter un jour'), findsOneWidget);
    // L'IA n'est plus dans la barre de titre.
    expect(find.byTooltip('Suggérer avec l\'IA'), findsNothing);
  });

  testWidgets('grand écran : plusieurs colonnes de cartes', (tester) async {
    await pumpAt(tester, const Size(1600, 900));

    Offset topLeftOf(int index) => tester.getTopLeft(
      find.byWidgetPredicate((w) => w is BatchSlotTile && w.index == index),
    );
    // 1600 px moins le panneau : trois colonnes de 560 px au plus.
    final columns = {
      for (final tile in tester.widgetList<BatchSlotTile>(
        find.byType(BatchSlotTile),
      ))
        topLeftOf(tile.index).dx,
    };
    expect(columns, hasLength(3));
    // Lecture ligne par ligne : le deuxième créneau est à droite du premier,
    // le quatrième sous le premier.
    expect(topLeftOf(1).dx, greaterThan(topLeftOf(0).dx));
    expect(topLeftOf(1).dy, topLeftOf(0).dy);
    expect(topLeftOf(3).dx, topLeftOf(0).dx);
    expect(topLeftOf(3).dy, greaterThan(topLeftOf(0).dy));
  });

  testWidgets('téléphone 360 px : consignes repliées, Valider en bas, '
      'sans débordement', (tester) async {
    await pumpAt(tester, const Size(360, 800));

    expect(tester.takeException(), isNull);
    expect(find.byType(VerticalDivider), findsNothing);
    expect(find.byType(PlanWithAiButton), findsNothing);
    expect(find.byTooltip('Suggérer avec l\'IA'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.bottomNavigationBar, isNotNull);
    expect(find.text('Consignes du cycle · aucune'), findsOneWidget);
    expect(find.byType(BatchSlotTile), findsWidgets);

    // Déplier les consignes ouvre le champ, et le compte suit la saisie.
    await tester.tap(find.text('Consignes du cycle · aucune'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      'pas de dessert\n\nvarier les protéines',
    );
    await tester.pumpAndSettle();
    expect(find.text('Consignes du cycle · 2 règles'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
