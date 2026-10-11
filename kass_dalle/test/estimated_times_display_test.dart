import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/estimated_times.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_filter.dart';
import 'package:kass_dalle/features/recipes/presentation/cooklang_preview_sections.dart';
import 'package:kass_dalle/features/search/domain/explore_facets.dart';

/// Affichage des durées estimées par l'IA : fiche recette et tuile Explorer.
void main() {
  Future<void> pumpRow(
    WidgetTester tester, {
    Map<String, String> meta = const {},
    RecipeEstimatedTimes? estimated,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CooklangMetaRow(
          meta: meta,
          selectedPortions: null,
          onSelectedPortionsChanged: null,
          minPortions: 1,
          maxPortions: 99,
          illustrationUrls: const [],
          estimatedTimes: estimated,
        ),
      ),
    ),
  );

  const note = 'Durées estimées par l\'IA, absentes de la recette d\'origine.';

  testWidgets('une durée estimée s\'affiche « ≈ », avec la mention', (
    tester,
  ) async {
    await pumpRow(
      tester,
      estimated: const RecipeEstimatedTimes(prep: 20, cook: 25),
    );
    expect(find.text('≈ Prép. 20 min'), findsOneWidget);
    expect(find.text('≈ Cuisson 25 min'), findsOneWidget);
    expect(find.text(note), findsOneWidget);
    expect(find.byTooltip('Estimé par l\'IA'), findsNWidgets(2));
    expect(
      find.bySemanticsLabel('Préparation environ 20 minutes, estimée'),
      findsOneWidget,
    );
  });

  testWidgets('une durée lue dans le texte garde la priorité', (tester) async {
    await pumpRow(
      tester,
      meta: const {'temps_preparation': '15'},
      estimated: const RecipeEstimatedTimes(prep: 40, cook: 25),
    );
    expect(find.text('Prép. 15 min'), findsOneWidget);
    expect(find.text('≈ Prép. 40 min'), findsNothing);
    expect(find.text('≈ Cuisson 25 min'), findsOneWidget);
    expect(find.text(note), findsOneWidget);
  });

  testWidgets('sans estimation, ni « ≈ » ni mention', (tester) async {
    await pumpRow(
      tester,
      meta: const {'temps_preparation': '15', 'temps_cuisson': '30'},
      estimated: const RecipeEstimatedTimes(prep: 40, cook: 25),
    );
    expect(find.textContaining('≈'), findsNothing);
    expect(find.text(note), findsNothing);
  });

  test('lecture d\'écran : minutes et heures', () {
    expect(spokenDuration(1), '1 minute');
    expect(spokenDuration(20), '20 minutes');
    expect(spokenDuration(60), '1 heure');
    expect(spokenDuration(150), '2 heures 30');
  });

  test('tuile Explorer : « ≈ …, estimé » si une composante est estimée', () {
    expect(exploreDurationText(45, estimated: false), '45 min');
    expect(exploreDurationText(45, estimated: true), '≈ 45 min, estimé');
    expect(exploreDurationText(80, estimated: true), '≈ 1 h 20, estimé');
    expect(
      exploreDurationSpoken(80, estimated: false),
      'Temps total : 1 heure 20',
    );
    expect(
      exploreDurationSpoken(45, estimated: true),
      'Temps total environ 45 minutes, estimé',
    );
  });
}
