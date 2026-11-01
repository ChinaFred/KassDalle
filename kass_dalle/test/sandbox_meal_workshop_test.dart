import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/sandbox/domain/meal_workshop_menu.dart';

/// Atelier repas (bac à sable, palier 0) : lecture du menu rendu, puce
/// « Modifié » entre deux tours, « Menu inchangé », mise en forme des
/// mesures. Fonctions pures, sans Firebase.
void main() {
  Map<String, dynamic> course(
    String role,
    String title, {
    String? recipeId,
    String? label,
    List<Map<String, dynamic>> sides = const [],
    bool unknown = false,
    String? description,
    String? why,
  }) => {
    'role': role,
    'course_label': label,
    'title': title,
    'description': description,
    'recipe_id': recipeId,
    'why': why,
    'sides': sides,
    'unknown_recipe_id': unknown,
  };

  WorkshopMenu menu(List<Map<String, dynamic>> courses, {int portions = 4}) =>
      WorkshopMenu.fromJson({'portions': portions, 'courses': courses});

  group('lecture du menu rendu', () {
    test('rôles, libellé « Autre », recette liée et accompagnements', () {
      final m = menu([
        course('entree', 'Velouté', why: 'Ouvre sur du chaud.'),
        course(
          'plat',
          'Blanquette de veau',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz', 'recipe_id': null},
            {'label': 'Carottes glacées', 'staple_id': null, 'recipe_id': null},
          ],
        ),
        course('autre', 'Trou normand', label: 'Trou normand'),
        course('dessert', 'Tarte aux poires', unknown: true),
      ]);
      expect(m.portions, 4);
      expect(m.courses.length, 4);
      expect(m.courses[0].role, MealComponentRole.entree);
      expect(m.courses[0].typeLabel, 'Entrée');
      expect(m.courses[0].why, 'Ouvre sur du chaud.');
      expect(m.courses[1].isLinked, isTrue);
      expect(m.courses[1].sides.map((s) => s.label), [
        'Riz',
        'Carottes glacées',
      ]);
      expect(m.courses[1].sides[0].stapleId, 'riz');
      expect(m.courses[2].typeLabel, 'Trou normand');
      expect(m.courses[3].unknownRecipeId, isTrue);
      expect(m.courses[3].isLinked, isFalse);
      expect(m.toWriteCount, 3);
      expect(m.linkedCount, 1);
    });

    test('un rôle inconnu se lit « Autre », un menu sans courses est vide', () {
      final m = menu([course('pizza', 'Quatre fromages')]);
      expect(m.courses.single.role, MealComponentRole.autre);
      expect(WorkshopMenu.fromJson(const {'portions': 6}).isEmpty, isTrue);
    });

    test('toJson ne renvoie pas les marqueurs du contrôle', () {
      final m = menu([course('plat', 'Rôti', unknown: true)]);
      final json = m.toJson();
      expect(json['portions'], 4);
      final c = (json['courses'] as List).single as Map<String, dynamic>;
      expect(c.containsKey('unknown_recipe_id'), isFalse);
      expect(c['role'], 'plat');
      expect(c['title'], 'Rôti');
    });

    test('une réponse sans menu ou sans consommation est refusée', () {
      expect(
        () => WorkshopTurnResult.fromJson(const {'reponse': 'x'}),
        throwsFormatException,
      );
    });

    test('la réponse complète est lue, le coût absent reste null', () {
      final result = WorkshopTurnResult.fromJson({
        'reponse': ' Je vous propose… ',
        'menu': {'portions': 4, 'courses': <Object>[]},
        'control': {
          'inventedIds': 2,
          'truncated': true,
          'droppedCourses': [
            {'index': 3, 'reason': 'role_inconnu', 'detail': 'accompagnement'},
          ],
        },
        'raw': '{}',
        'usage': {
          'costUsd': null,
          'inputTokens': 11240,
          'outputTokens': 420,
          'durationMs': 4100,
          'provider': 'gemini',
          'model': 'gemini-2.5-flash',
        },
        'promptChars': 48200,
        'turn': 3,
      });
      expect(result.reponse, 'Je vous propose…');
      expect(result.usage.costUsd, isNull);
      expect(result.control.inventedIds, 2);
      expect(result.control.lines.first, 'inventedIds : 2');
      expect(
        result.control.lines[3],
        'services écartés : 1 (#3 role_inconnu « accompagnement »)',
      );
      expect(result.turn, 3);
    });
  });

  group('puce « Modifié »', () {
    final previous = menu([
      course('entree', 'Velouté'),
      course(
        'plat',
        'Blanquette',
        recipeId: 'r1',
        sides: [
          {'label': 'Riz', 'staple_id': 'riz'},
        ],
      ),
      course('dessert', 'Tarte aux poires'),
    ]);

    test('sans menu précédent, tout est nouveau', () {
      expect(changedCourseIndexes(null, previous), {0, 1, 2});
    });

    test('un dessert remplacé marque le dessert seul', () {
      final next = menu([
        course('entree', 'Velouté'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz'},
          ],
        ),
        course('dessert', 'Mousse au chocolat'),
      ]);
      expect(changedCourseIndexes(previous, next), {2});
    });

    test('un accompagnement changé marque le plat', () {
      final next = menu([
        course('entree', 'Velouté'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Pommes vapeur', 'staple_id': null},
          ],
        ),
        course('dessert', 'Tarte aux poires'),
      ]);
      expect(changedCourseIndexes(previous, next), {1});
    });

    test('un service inséré ne marque pas ceux qui suivent', () {
      final next = menu([
        course('entree', 'Velouté'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz'},
          ],
        ),
        course('sorbet', 'Sorbet citron'),
        course('dessert', 'Tarte aux poires'),
      ]);
      expect(changedCourseIndexes(previous, next), {2});
    });

    test('description ou raison reformulées ne marquent rien', () {
      final next = menu([
        course('entree', 'Velouté', description: 'Doux et lisse.', why: 'x'),
        course(
          'plat',
          'Blanquette',
          recipeId: 'r1',
          sides: [
            {'label': 'Riz', 'staple_id': 'riz'},
          ],
        ),
        course('dessert', 'Tarte aux poires'),
      ]);
      expect(changedCourseIndexes(previous, next), isEmpty);
    });
  });

  group('« Menu inchangé »', () {
    final a = menu([course('plat', 'Rôti', why: 'Simple.')]);

    test('un JSON identique est inchangé', () {
      expect(
        sameMenu(a, menu([course('plat', 'Rôti', why: 'Simple.')])),
        isTrue,
      );
    });

    test(
      'une raison reformulée, ou des parts changées, n\'est pas inchangé',
      () {
        expect(
          sameMenu(a, menu([course('plat', 'Rôti', why: 'Autre.')])),
          isFalse,
        );
        expect(
          sameMenu(
            a,
            menu([course('plat', 'Rôti', why: 'Simple.')], portions: 6),
          ),
          isFalse,
        );
      },
    );

    test('sans menu précédent, jamais inchangé', () {
      expect(sameMenu(null, a), isFalse);
    });
  });

  group('mesures', () {
    test(
      'coût : quatre décimales à la virgule, « non chiffré » sans montant',
      () {
        expect(formatWorkshopCost(0.0123), '0,0123 \$');
        expect(formatWorkshopCost(0), '0,0000 \$');
        expect(formatWorkshopCost(null), 'non chiffré');
      },
    );

    test('compteurs et durées', () {
      expect(formatWorkshopCount(420), '420');
      expect(formatWorkshopCount(11240), '11 240');
      expect(formatWorkshopCount(1234567), '1 234 567');
      expect(formatWorkshopDuration(850), '850 ms');
      expect(formatWorkshopDuration(4100), '4,1 s');
    });

    test(
      'le moteur prend le libellé de la présélection, sinon provider/model',
      () {
        expect(
          workshopEngineLabel('gemini', 'gemini-2.5-flash'),
          'Gemini 2.5 Flash',
        );
        expect(
          workshopEngineLabel('anthropic', 'claude-sonnet-5'),
          'Claude Sonnet 5',
        );
        expect(workshopEngineLabel('gemini', 'gemini-9'), 'gemini/gemini-9');
      },
    );

    test('la ligne sous la bulle', () {
      const usage = WorkshopUsage(
        costUsd: 0.0123,
        inputTokens: 11240,
        outputTokens: 420,
        durationMs: 4100,
        provider: 'gemini',
        model: 'gemini-2.5-flash',
      );
      expect(
        workshopUsageLine(usage),
        '0,0123 \$ · 11 240 → 420 jetons · 4,1 s · Gemini 2.5 Flash',
      );
      const fallen = WorkshopUsage(
        costUsd: null,
        inputTokens: 1,
        outputTokens: 2,
        durationMs: 3,
        provider: 'gemini',
        model: 'gemini-2.5-flash',
        requested: 'anthropic/claude-sonnet-5',
      );
      expect(workshopUsageLine(fallen), contains('non chiffré'));
      expect(
        workshopUsageLine(fallen),
        endsWith('demandé : anthropic/claude-sonnet-5'),
      );
    });

    test(
      'le tableau tabulé : un en-tête, une ligne par tour, vide sans montant',
      () {
        final table = workshopMeasuresTable(const [
          WorkshopTurnMeasure(
            conversation: 1,
            turn: 1,
            costUsd: 0.0123,
            inputTokens: 11240,
            outputTokens: 420,
            durationMs: 4100,
            inventedIds: 1,
            provider: 'gemini',
            model: 'gemini-2.5-flash',
            promptChars: 48200,
          ),
          WorkshopTurnMeasure(
            conversation: 2,
            turn: 1,
            costUsd: null,
            inputTokens: 0,
            outputTokens: 0,
            durationMs: 0,
            unreadable: true,
            provider: '?',
            model: '?',
            promptChars: 0,
          ),
        ]);
        final lines = table.split('\n');
        expect(lines.length, 3);
        expect(lines[0].split('\t').take(2), ['conversation', 'tour']);
        expect(lines[1].split('\t'), [
          '1',
          '1',
          '0.012300',
          '11240',
          '420',
          '4100',
          '1',
          '0',
          '0',
          '0',
          'gemini/gemini-2.5-flash',
          '48200',
        ]);
        // Deuxième conversation, premier tour, sans montant, illisible.
        expect(lines[2].split('\t').take(2), ['2', '1']);
        expect(lines[2].split('\t')[2], '');
        expect(lines[2].split('\t')[9], '1');
      },
    );

    test('le total distingue les tours sans montant', () {
      final total = workshopCostTotal(const [
        WorkshopTurnMeasure(
          conversation: 1,
          turn: 1,
          costUsd: 0.01,
          inputTokens: 0,
          outputTokens: 0,
          durationMs: 0,
          provider: 'g',
          model: 'm',
          promptChars: 0,
        ),
        WorkshopTurnMeasure(
          conversation: 1,
          turn: 2,
          costUsd: null,
          inputTokens: 0,
          outputTokens: 0,
          durationMs: 0,
          provider: 'g',
          model: 'm',
          promptChars: 0,
        ),
        WorkshopTurnMeasure(
          conversation: 1,
          turn: 3,
          costUsd: 0.02,
          inputTokens: 0,
          outputTokens: 0,
          durationMs: 0,
          provider: 'g',
          model: 'm',
          promptChars: 0,
        ),
      ]);
      expect(total.knownUsd, closeTo(0.03, 1e-9));
      expect(total.unpriced, 1);
    });

    test(
      'un tour illisible lit sa consommation dans les détails de l\'erreur',
      () {
        final m = WorkshopTurnMeasure.unreadable(
          {
            'turn': 5,
            'usage': {
              'costUsd': 0.004,
              'inputTokens': 100,
              'outputTokens': 50,
              'durationMs': 1200,
              'provider': 'anthropic',
              'model': 'claude-haiku-4-5',
            },
            'promptChars': 1000,
          },
          conversation: 3,
          fallbackTurn: 1,
        );
        expect(m.conversation, 3);
        expect(m.turn, 5);
        expect(m.unreadable, isTrue);
        expect(m.costUsd, 0.004);
        expect(m.provider, 'anthropic');
        final bare = WorkshopTurnMeasure.unreadable(
          null,
          conversation: 1,
          fallbackTurn: 7,
        );
        expect(bare.turn, 7);
        expect(bare.costUsd, isNull);
      },
    );
  });
}
