/// « Générer avec l'IA » dans le sélecteur du planning.
///
/// Ce que ces tests gardent : l'idée retenue sort en repas libre avec ses
/// durées, la relance transporte tous les titres déjà affichés — pas seulement
/// le dernier lot —, et un générateur qui échoue laisse un message, pas un
/// écran figé. Le message d'échec tient en deux phrases lisibles (« Idées non
/// proposées. Connexion perdue. ») : le texte brut de l'exception n'y figure
/// pas, sauf le message qu'un callable écrit pour l'écran.
library;

import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/core/widgets/error_message.dart' show kAiBudgetScope;
import 'package:kass_dalle/features/planning/domain/meal_idea.dart';
import 'package:kass_dalle/features/planning/presentation/meal_ideas_sheet.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

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
Future<Future<Recipe?> Function()> _pumpHost(
  WidgetTester tester,
  MealIdeasGenerator generate, {
  MealIdeaConceiver? conceive,
  String initialPrompt = '',
  ErrorReportService? errors,
}) async {
  Recipe? result;
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
                conceive: conceive,
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
      // Sans rédaction, l'idée sort en repas libre.
      expect(picked?.id, isEmpty);
    });

    testWidgets('avec un rédacteur, l\'idée retenue sort en recette '
        'enregistrée', (tester) async {
      MealIdea? conceived;
      final read = await _pumpHost(
        tester,
        ({required prompt, required previousTitles}) async => _lot1,
        conceive: (idea) async {
          conceived = idea;
          return idea.toFreeRecipe().copyWith(titre: 'Enregistrée');
        },
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'un plat léger');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Proposer trois idées'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Mes créations'), findsOneWidget);

      await tester.tap(find.text('Omelette aux herbes'));
      await tester.pumpAndSettle();

      expect(conceived?.titre, 'Omelette aux herbes');
      final picked = await read();
      expect(picked?.titre, 'Enregistrée');
    });

    testWidgets('un rédacteur qui échoue laisse un message et les idées', (
      tester,
    ) async {
      final errors = _RecordingErrorReportService();
      await _pumpHost(
        tester,
        ({required prompt, required previousTitles}) async => _lot1,
        conceive: (idea) async => throw StateError('rédaction impossible'),
        errors: errors,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'un plat léger');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Proposer trois idées'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Soupe de courge'));
      await tester.pumpAndSettle();

      expect(
        find.text('Recette non conçue. Une erreur inattendue est survenue.'),
        findsOneWidget,
      );
      expect(find.textContaining('rédaction impossible'), findsNothing);
      expect(errors.features, ['mealIdeasSheet.conceive']);
      // Les idées restent, et se retiennent encore.
      expect(find.text('Dahl de lentilles corail'), findsOneWidget);
      expect(
        tester
            .widget<ListTile>(find.widgetWithText(ListTile, 'Soupe de courge'))
            .enabled,
        isTrue,
      );
    });

    testWidgets('le bouton Fermer et un clic hors de la feuille la quittent '
        'sans rien retenir, même avec un rédacteur', (tester) async {
      final read = await _pumpHost(
        tester,
        ({required prompt, required previousTitles}) async => _lot1,
        conceive: (idea) async => idea.toFreeRecipe(),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      expect(find.text('Générer avec l\'IA'), findsOneWidget);

      await tester.tap(find.byTooltip('Fermer'));
      await tester.pumpAndSettle();
      expect(find.text('Générer avec l\'IA'), findsNothing);
      expect(await read(), isNull);

      // Rouverte : le clic sur le fond fait de même.
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('Générer avec l\'IA'), findsNothing);
    });

    testWidgets('pendant la rédaction, ni le bouton Fermer ni le fond ne '
        'quittent la feuille', (tester) async {
      final writing = Completer<Recipe>();
      final read = await _pumpHost(
        tester,
        ({required prompt, required previousTitles}) async => _lot1,
        conceive: (idea) => writing.future,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'un plat léger');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Proposer trois idées'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Omelette aux herbes'));
      await tester.pump();

      expect(find.textContaining('Rédaction de'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
            .onPressed,
        isNull,
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(find.text('Générer avec l\'IA'), findsOneWidget);

      // La recette écrite sort ensuite normalement.
      writing.complete(_lot1[1].toFreeRecipe().copyWith(titre: 'Écrite'));
      await tester.pumpAndSettle();
      expect((await read())?.titre, 'Écrite');
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

      expect(
        find.text('Idées non proposées. Une erreur inattendue est survenue.'),
        findsOneWidget,
      );
      expect(find.textContaining('moteur indisponible'), findsNothing);
      expect(errors.features, ['mealIdeasSheet.generate']);
      final button = find.widgetWithText(FilledButton, 'Proposer trois idées');
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    });

    /// Ouvre la feuille avec un générateur qui lève [error], et demande des
    /// idées.
    Future<void> generateFailing(WidgetTester tester, Object error) async {
      await _pumpHost(tester, ({
        required prompt,
        required previousTitles,
      }) async {
        throw error;
      }, errors: _RecordingErrorReportService());
      await tester.pumpAndSettle();
      await tester.tap(find.text('ouvrir'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'des pâtes');
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Proposer trois idées'),
      );
      await tester.pumpAndSettle();
    }

    /// Tout le texte affiché, pour vérifier qu'aucun fragment technique n'y
    /// reste.
    String shownText(WidgetTester tester) => tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ');

    testWidgets('une connexion perdue s\'affiche en deux phrases, sans texte '
        'technique', (tester) async {
      await generateFailing(
        tester,
        FirebaseException(
          plugin: 'cloud_functions',
          code: 'unavailable',
          message: 'The service is currently unavailable.',
        ),
      );

      expect(
        find.text('Idées non proposées. Connexion perdue.'),
        findsOneWidget,
      );
      final text = shownText(tester);
      expect(text, isNot(contains('[')));
      expect(text, isNot(contains('Exception')));
      expect(text.toLowerCase(), isNot(contains('firebase')));
    });

    testWidgets('le plafond d\'IA du jour garde le message du serveur', (
      tester,
    ) async {
      await generateFailing(
        tester,
        GeminiCallableException(
          'resource-exhausted',
          'Plafond du jour atteint : revenez demain.',
          {'reason': 'cost', 'scope': kAiBudgetScope},
        ),
      );

      expect(
        find.text(
          'Idées non proposées. Plafond du jour atteint : revenez demain.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('le texte brut du fournisseur saturé n\'est pas recopié', (
      tester,
    ) async {
      await generateFailing(
        tester,
        GeminiCallableException(
          'resource-exhausted',
          '429 Resource has been exhausted (e.g. check quota).',
          null,
        ),
      );

      expect(
        find.text('Idées non proposées. Service d\'IA saturé.'),
        findsOneWidget,
      );
      expect(find.textContaining('429'), findsNothing);
    });

    testWidgets('le texte anglais du SDK sur mobile n\'est pas recopié', (
      tester,
    ) async {
      await generateFailing(
        tester,
        GeminiCallableException('unavailable', 'UNAVAILABLE', null),
      );

      expect(
        find.text('Idées non proposées. Connexion perdue.'),
        findsOneWidget,
      );
      expect(find.textContaining('UNAVAILABLE'), findsNothing);
    });

    testWidgets('un invalid-argument du serveur n\'est pas recopié', (
      tester,
    ) async {
      await generateFailing(
        tester,
        GeminiCallableException('invalid-argument', 'prompt est requis.', null),
      );

      expect(find.textContaining('prompt est requis'), findsNothing);
      expect(find.textContaining('Idées non proposées.'), findsOneWidget);
    });

    testWidgets('une erreur interne du serveur n\'est pas recopiée', (
      tester,
    ) async {
      await generateFailing(
        tester,
        GeminiCallableException(
          'internal',
          'TypeError: Cannot read properties of undefined',
          null,
        ),
      );

      expect(
        find.text('Idées non proposées. Une erreur inattendue est survenue.'),
        findsOneWidget,
      );
      expect(find.textContaining('TypeError'), findsNothing);
    });
  });
}
