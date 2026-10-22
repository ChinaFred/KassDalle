import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/presentation/ai/ai_processing_overlay.dart';
import 'package:kass_dalle/features/recipes/presentation/ai/ai_ui_copy.dart';

/// Horloge pilotée par le test : le chronomètre lit l'heure à chaque seconde,
/// et le test avance cette heure en même temps que le temps simulé.
class _Clock {
  DateTime now = DateTime(2026, 10, 22, 10);
  DateTime call() => now;
}

Widget _host(Widget overlay, {double textScale = 1}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(body: Stack(children: [const SizedBox.expand(), overlay])),
);

Future<void> _advance(WidgetTester tester, _Clock clock, Duration by) async {
  clock.now = clock.now.add(by);
  // Le chronomètre redessine à chaque seconde ; une seule seconde simulée
  // suffit pour qu'il relise l'horloge.
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  const steps = [
    AiProcessingStep('Lecture du texte', AiProcessingStepState.done),
    AiProcessingStep(
      "Traduction depuis l'anglais",
      AiProcessingStepState.current,
    ),
    AiProcessingStep(
      'Repérage des ingrédients et des étapes',
      AiProcessingStepState.upcoming,
    ),
  ];

  testWidgets('avec étapes : une ligne par étape, marquée selon son état', (
    tester,
  ) async {
    final clock = _Clock();
    await tester.pumpWidget(
      _host(
        AiProcessingOverlay(
          title: RecipeAiUiCopy.conversionTitle,
          estimate: RecipeAiUiCopy.conversionEstimate,
          message: RecipeAiUiCopy.conversionStayHere,
          steps: steps,
          clock: clock.call,
        ),
      ),
    );

    expect(find.text('Conversion de la recette'), findsOneWidget);
    expect(find.text('Lecture du texte'), findsOneWidget);
    expect(find.text("Traduction depuis l'anglais"), findsOneWidget);
    expect(find.text('Repérage des ingrédients et des étapes'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsOneWidget);
    // Un seul indicateur : celui de l'étape en cours, pas de doublon au titre.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Comptez 1 à 2 minutes.'), findsOneWidget);
    expect(find.text('Temps écoulé : 0 min 00'), findsOneWidget);
    expect(
      find.text("Restez sur cet écran : la recette s'affichera ici."),
      findsOneWidget,
    );

    // L'étape en cours est une région annoncée par le lecteur d'écran.
    final live = tester.getSemantics(
      find.bySemanticsLabel("Traduction depuis l'anglais, en cours"),
    );
    expect(live.flagsCollection.isLiveRegion, isTrue);
    final done = tester.getSemantics(
      find.bySemanticsLabel('Lecture du texte, terminé'),
    );
    expect(done.flagsCollection.isLiveRegion, isFalse);
  });

  testWidgets('sans étape : ni liste ni coche, titre, message et chronomètre', (
    tester,
  ) async {
    final clock = _Clock();
    await tester.pumpWidget(
      _host(
        AiProcessingOverlay(
          title: RecipeAiUiCopy.processingTitle,
          message: RecipeAiUiCopy.processingMessage,
          clock: clock.call,
        ),
      ),
    );

    expect(find.text('Traitement IA en cours'), findsOneWidget);
    expect(
      find.text('Cela peut prendre une à deux minutes. Restez sur cet écran.'),
      findsOneWidget,
    );
    expect(find.text('Temps écoulé : 0 min 00'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNothing);
    // L'indicateur reste au titre : c'est le seul signe d'activité.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('le chronomètre avance chaque seconde', (tester) async {
    final clock = _Clock();
    await tester.pumpWidget(
      _host(AiProcessingOverlay(title: 'T', clock: clock.call)),
    );
    expect(find.text('Temps écoulé : 0 min 00'), findsOneWidget);

    await _advance(tester, clock, const Duration(seconds: 1));
    expect(find.text('Temps écoulé : 0 min 01'), findsOneWidget);

    await _advance(tester, clock, const Duration(seconds: 64));
    expect(find.text('Temps écoulé : 1 min 05'), findsOneWidget);
  });

  testWidgets('au-delà de 3 minutes, l\'estimation cède la place à l\'alerte', (
    tester,
  ) async {
    final clock = _Clock();
    await tester.pumpWidget(
      _host(
        AiProcessingOverlay(
          title: RecipeAiUiCopy.conversionTitle,
          estimate: RecipeAiUiCopy.conversionEstimate,
          steps: steps,
          clock: clock.call,
        ),
      ),
    );
    const slow =
        "C'est plus long que d'habitude. Le traitement continue : inutile de "
        'relancer.';

    await _advance(tester, clock, const Duration(minutes: 2, seconds: 58));
    expect(find.text('Comptez 1 à 2 minutes.'), findsOneWidget);
    expect(find.text(slow), findsNothing);
    // Avant le seuil, l'estimation n'est pas une région annoncée.
    expect(
      tester
          .getSemantics(find.text('Comptez 1 à 2 minutes.'))
          .flagsCollection
          .isLiveRegion,
      isFalse,
    );

    await _advance(tester, clock, const Duration(seconds: 2));
    expect(find.text('Temps écoulé : 3 min 00'), findsOneWidget);
    expect(find.text('Comptez 1 à 2 minutes.'), findsNothing);
    expect(find.text(slow), findsOneWidget);
    // Le passage des trois minutes est annoncé par le lecteur d'écran.
    expect(
      tester.getSemantics(find.text(slow)).flagsCollection.isLiveRegion,
      isTrue,
    );
  });

  testWidgets('sans estimation, l\'alerte s\'ajoute au-delà de 3 minutes', (
    tester,
  ) async {
    final clock = _Clock();
    await tester.pumpWidget(
      _host(
        AiProcessingOverlay(
          title: RecipeAiUiCopy.processingTitle,
          message: RecipeAiUiCopy.processingMessage,
          clock: clock.call,
        ),
      ),
    );
    await _advance(tester, clock, const Duration(minutes: 3));
    expect(find.textContaining("C'est plus long que d'habitude."), findsOne);
    expect(
      find.text('Cela peut prendre une à deux minutes. Restez sur cet écran.'),
      findsOneWidget,
    );
  });

  testWidgets('le chronomètre s\'arrête quand le voile disparaît', (
    tester,
  ) async {
    final clock = _Clock();
    await tester.pumpWidget(
      _host(AiProcessingOverlay(title: 'T', clock: clock.call)),
    );
    await tester.pumpWidget(_host(const SizedBox.shrink()));
    // Un minuteur encore actif ferait échouer le test à sa sortie.
    await tester.pump(const Duration(seconds: 5));
    expect(find.byType(AiProcessingOverlay), findsNothing);
  });

  testWidgets('texte à 200 % sur un petit écran : la carte défile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clock = _Clock();
    await tester.pumpWidget(
      _host(
        AiProcessingOverlay(
          title: RecipeAiUiCopy.conversionTitle,
          estimate: RecipeAiUiCopy.conversionEstimate,
          message: RecipeAiUiCopy.conversionStayHere,
          steps: steps,
          clock: clock.call,
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
