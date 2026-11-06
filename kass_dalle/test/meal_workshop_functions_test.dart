import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/planning/domain/meal_kind.dart';
import 'package:kass_dalle/features/search/data/meal_workshop_functions.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';

/// Les deux appels de l'atelier repas : le payload envoyé, la réponse lue,
/// et une rédaction sans recette traduite en `WorkshopNoRecipeException`.
class _FakeGemini extends GeminiService {
  Map<String, dynamic>? lastTurn;
  Map<String, dynamic>? lastRecipe;
  Object? recipeAnswer;

  @override
  Future<Map<String, dynamic>> mealWorkshopTurn(
    Map<String, dynamic> payload,
  ) async {
    lastTurn = payload;
    return {
      'reponse': 'Voici.',
      'menu': {
        'portions': 6,
        'courses': [
          {'role': 'plat', 'title': 'Bar rôti'},
        ],
      },
      'turn': 2,
      'quota': {'limit': 30, 'remaining': 28},
    };
  }

  @override
  Future<Map<String, dynamic>> mealWorkshopRecipe(
    Map<String, dynamic> payload,
  ) async {
    lastRecipe = payload;
    final answer = recipeAnswer;
    if (answer is Map<String, dynamic>) return answer;
    throw answer!;
  }
}

void main() {
  late _FakeGemini gemini;
  late MealWorkshopFunctions functions;

  setUp(() {
    gemini = _FakeGemini();
    functions = MealWorkshopFunctions(gemini);
  });

  test('un tour : les clés du contrat, le menu relu, le compteur', () async {
    final menu = WorkshopMenu.fromJson({
      'portions': 6,
      'courses': [
        {'role': 'plat', 'title': 'Rôti'},
      ],
    });
    final result = await functions.turn(
      conversationId: 'abcdefgh',
      kind: MealKind.menu,
      history: const [
        {'role': 'user', 'text': 'bonjour'},
      ],
      message: 'un dîner',
      recipes: const [
        {'id': 'r1', 'titre': 'Rôti'},
      ],
      staples: const [],
      globalConstraints: 'pas de porc',
      portions: 6,
      menu: menu,
    );
    final sent = gemini.lastTurn!;
    expect(sent.keys.toSet(), {
      'conversationId',
      'kind',
      'history',
      'message',
      'recipes',
      'staples',
      'globalConstraints',
      'portions',
      'menu',
    });
    expect(sent['kind'], 'menu');
    expect(sent['portions'], 6);
    expect((sent['menu'] as Map)['portions'], 6);
    expect(result.menu.courses.single.title, 'Bar rôti');
    expect(result.turn, 2);
    expect(result.quota?.remaining, 28);
  });

  test('sans menu en cours : `menu` vaut null', () async {
    await functions.turn(
      conversationId: 'abcdefgh',
      kind: MealKind.plat,
      history: const [],
      message: 'un plat',
      recipes: const [],
      staples: const [],
      globalConstraints: '',
      portions: 4,
      menu: null,
    );
    expect(gemini.lastTurn!['menu'], isNull);
    expect(gemini.lastTurn!['kind'], 'plat');
  });

  test('la recette d\'un plat figé : le payload et la forme de '
      'generateRecipeFn', () async {
    gemini.recipeAnswer = {
      'titre': 'Bar rôti au four',
      'cooklang': '>> portions: 4\nRôtir le @bar{1}.',
      'portions': 4,
      'ingredients': [
        {'name': 'bar', 'qty': '1', 'unit': ''},
      ],
      'ingredients_index': ['bar'],
    };
    final recipe = await functions.writeRecipe(
      conversationId: 'abcdefgh',
      titre: 'Bar rôti',
      description: 'au four',
      sides: const ['riz'],
      portions: 4,
      globalConstraints: '',
    );
    expect(gemini.lastRecipe, {
      'conversationId': 'abcdefgh',
      'titre': 'Bar rôti',
      'description': 'au four',
      'sides': ['riz'],
      'portions': 4,
      'globalConstraints': '',
    });
    expect(recipe.titre, 'Bar rôti au four');
    expect(recipe.ingredients.single.name, 'bar');
    expect(recipe.portions, 4);
  });

  test('sans recette : le refus du serveur, ou un CookLang vide', () async {
    gemini.recipeAnswer = GeminiCallableException(
      'internal',
      'L\'IA n\'a pas rendu de recette.',
      {'reason': kWorkshopRecipeUnreadableReason},
    );
    Future<void> write() => functions.writeRecipe(
      conversationId: 'abcdefgh',
      titre: 'Bar rôti',
      description: null,
      sides: const [],
      portions: 4,
      globalConstraints: '',
    );
    await expectLater(write(), throwsA(isA<WorkshopNoRecipeException>()));

    gemini.recipeAnswer = {'titre': 'Bar rôti', 'cooklang': '  '};
    await expectLater(write(), throwsA(isA<WorkshopNoRecipeException>()));

    // Une autre erreur du serveur passe telle quelle.
    gemini.recipeAnswer = GeminiCallableException('unavailable', 'down', null);
    await expectLater(write(), throwsA(isA<GeminiCallableException>()));
  });
}
