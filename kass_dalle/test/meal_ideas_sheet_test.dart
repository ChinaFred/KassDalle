/// « Générer avec l'IA » dans le sélecteur du planning.
///
/// Ce que ces tests gardent : l'idée retenue sort en repas libre avec ses
/// durées, la relance transporte tous les titres déjà affichés — pas seulement
/// le dernier lot —, et un générateur qui échoue laisse un message, pas un
/// écran figé.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/planning/domain/meal_idea.dart';
import 'package:kass_dalle/features/planning/presentation/meal_ideas_sheet.dart';

/// Enregistre les postes signalés, sans Firebase.
class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'report';
  }
}

const _lot1 = [
  MealIdea(
    titre: 'Dahl de lentilles corail',
    description: 'Lentilles, lait de coco, riz.',
    prepMinutes: 10,
    cookMinutes: 25,
  ),
  MealIdea(titre: 'Omelette aux herbes', description: 'Œufs, ciboulette.'),
  MealIdea(titre: 'Soupe de courge', description: 'Courge rôtie, crème.'),
];

const _lot2 = [
  MealIdea(titre: 'Riz sauté aux légumes'),
  MealIdea(titre: 'Tarte aux poireaux'),
  MealIdea(titre: 'Gratin de chou-fleur'),
];

/// Ouvre la feuille depuis un bouton et rend ce qu'elle a renvoyé.
Future<Future<MealIdea?> Function()> _pumpHost(
  WidgetTester tester,
  MealIdeasGenerator generate, {
  String initialPrompt = '',
  ErrorReportService? errors,
}) async {
  MealIdea? result;
  var done = false;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showMealIdeasSheet(
                context,
                generate: generate,
                initialPrompt: initialPrompt,
                errorReportService: errors,
              );
              done = true;
            },
            child: const Text('ouvrir'),
          ),
        ),
      ),
    ),
  );
  return () async {
    expect(done, isTrue, reason: 'la feuille est encore ouverte');
    return result;
  };
}

void main() {
  group('MealIdea', () {
    test('toFreeRecipe rend un repas libre avec ses durées', () {
      final recipe = _lot1.first.toFreeRecipe();
      expect(recipe.id, isEmpty);
      expect(recipe.titre, 'Dahl de lentilles corail');
      expect(recipe.tags.prepTime, 10);
      expect(recipe.tags.cookTime, 25);
      expect(recipe.rawCooklang, isEmpty);
    });

    test('timesLabel ne nomme que les durées connues', () {
      expect(_lot1[0].timesLabel, '10min prép + 25min cuisson');
      expect(_lot1[1].timesLabel, isEmpty);
      expect(
        const MealIdea(titre: 'x', cookMinutes: 5).timesLabel,
        '5min cuisson',
      );
    });
  });

  group('MealIdeasSheet', () {
    testWidgets('une consigne rend trois idées et la relance en demande '
        'd\'autres, en citant tout ce qui a déjà été affiché', (tester) async {
      final calls = <({String prompt, List<String> previous})>[];
      var lot = 0;
      final read = await _pumpHost(tester, ({
        required prompt,
        required previousTitles,
      }) async {
        calls.add((prompt: prompt, previous: previousTitles));
        return lot++ == 0 ? _lot1 : _lot2;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();

      // Sans consigne, rien ne part.
      final button = find.widgetWithText(FilledButton, 'Proposer trois idées');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'un plat léger');
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(calls.single.prompt, 'un plat léger');
      expect(calls.single.previous, isEmpty);
      expect(find.text('Dahl de lentilles corail'), findsOneWidget);
      expect(find.text('Soupe de courge'), findsOneWidget);
      expect(find.textContaining('10min prép + 25min cuisson'), findsOneWidget);

      // Relance avec une consigne retouchée : les trois premiers titres partent
      // avec elle.
      await tester.enterText(find.byType(TextField), 'un plat léger sans œuf');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Proposer trois autres idées'),
      );
      await tester.pumpAndSettle();

      expect(calls.length, 2);
      expect(calls[1].prompt, 'un plat léger sans œuf');
      expect(calls[1].previous, [
        'Dahl de lentilles corail',
        'Omelette aux herbes',
        'Soupe de courge',
      ]);
      expect(find.text('Dahl de lentilles corail'), findsNothing);
      expect(find.text('Tarte aux poireaux'), findsOneWidget);

      await tester.tap(find.text('Tarte aux poireaux'));
      await tester.pumpAndSettle();
      final picked = await read();
      expect(picked?.titre, 'Tarte aux poireaux');
    });

    testWidgets('la recherche du sélecteur sert de première consigne', (
      tester,
    ) async {
      await _pumpHost(
        tester,
        ({required prompt, required previousTitles}) async => _lot1,
        initialPrompt: 'tartiflette',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller?.text,
        'tartiflette',
      );
      final button = find.widgetWithText(FilledButton, 'Proposer trois idées');
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    });

    testWidgets('un générateur qui échoue laisse un message et le bouton', (
      tester,
    ) async {
      final errors = _RecordingErrorReportService();
      await _pumpHost(tester, ({
        required prompt,
        required previousTitles,
      }) async {
        throw StateError('moteur indisponible');
      }, errors: errors);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'des pâtes');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Proposer trois idées'),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('moteur indisponible'), findsOneWidget);
      expect(errors.features, ['mealIdeasSheet.generate']);
      final button = find.widgetWithText(FilledButton, 'Proposer trois idées');
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    });
  });
}
