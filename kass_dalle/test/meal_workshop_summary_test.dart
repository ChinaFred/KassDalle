import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/estimated_times.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_summary.dart';

/// Le résumé d'une recette envoyé par l'atelier repas : les trois écritures
/// de `duree`, le plafond de 6 ingrédients, et les clés — celles de
/// `SUMMARY_KEYS` côté serveur, sans `livre` ni `statut`.
void main() {
  Recipe recipe({
    int? prep,
    int? cook,
    RecipeEstimatedTimes? estimated,
    List<String> ingredients = const [],
    String cooklang = '',
  }) => Recipe(
    id: 'r1',
    titre: 'Blanquette de veau',
    bookTitre: 'Le Grand Livre',
    langue: 'fr',
    rawCooklang: cooklang,
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(
      themes: const ['hiver'],
      cuisines: const ['française'],
      difficulty: 'moyen',
      prepTime: prep,
      cookTime: cook,
      mealRole: 'plat',
      mainProtein: 'veau',
      mainStarch: 'riz',
    ),
    ingredientsIndex: ingredients,
    createdBy: 'moi',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    estimatedTimes: estimated,
  );

  group('duree', () {
    test('une durée lue : « 35 min »', () {
      expect(workshopRecipeDuration(recipe(prep: 15, cook: 20)), '35 min');
      expect(buildMealWorkshopSummary(recipe(prep: 35))['duree'], '35 min');
    });

    test('une durée lue dans les métadonnées CookLang compte comme lue', () {
      final r = recipe(
        cooklang: '>> temps_preparation: 10\n>> temps_cuisson: 25\n',
      );
      expect(workshopRecipeDuration(r), '35 min');
    });

    test('une durée estimée par l\'IA : « ≈ 40 min »', () {
      final r = recipe(
        estimated: const RecipeEstimatedTimes(prep: 20, cook: 20),
      );
      expect(workshopRecipeDuration(r), '≈ 40 min');
    });

    test(
      'une composante lue, l\'autre estimée : le total est marqué « ≈ »',
      () {
        final r = recipe(
          prep: 15,
          estimated: const RecipeEstimatedTimes(prep: 99, cook: 25),
        );
        expect(workshopRecipeDuration(r), '≈ 40 min');
      },
    );

    test('sans aucune durée : « inconnue »', () {
      expect(workshopRecipeDuration(recipe()), 'inconnue');
      expect(buildMealWorkshopSummary(recipe())['duree'], 'inconnue');
    });
  });

  group('résumé', () {
    test(
      'les clés sont celles du serveur, dans son ordre : ni livre, ni statut',
      () {
        final summary = buildMealWorkshopSummary(recipe(prep: 10), myRating: 8);
        expect(summary.keys.toList(), kWorkshopSummaryKeys);
        expect(summary.containsKey('livre'), isFalse);
        expect(summary.containsKey('statut'), isFalse);
        expect(summary['id'], 'r1');
        expect(summary['titre'], 'Blanquette de veau');
        expect(summary['themes'], 'hiver');
        expect(summary['cuisines'], 'française');
        expect(summary['difficulte'], 'moyen');
        expect(summary['role'], 'plat');
        expect(summary['proteine'], 'veau');
        expect(summary['feculent'], 'riz');
        expect(summary['note'], '8/10');
        expect(summary['duree'], '10 min');
      },
    );

    test('sans note : « non notee », comme « Chercher avec l\'IA »', () {
      expect(buildMealWorkshopSummary(recipe())['note'], 'non notee');
    });

    test(
      'les ingrédients sont plafonnés à $kWorkshopSummaryMaxIngredients',
      () {
        final many = [for (var i = 1; i <= 20; i++) 'ingredient$i'];
        final summary = buildMealWorkshopSummary(recipe(ingredients: many));
        expect(
          summary['ingredients'],
          'ingredient1, ingredient2, ingredient3, ingredient4, ingredient5, '
          'ingredient6',
        );
        final few = buildMealWorkshopSummary(
          recipe(ingredients: const ['veau', 'carotte']),
        );
        expect(few['ingredients'], 'veau, carotte');
        expect(buildMealWorkshopSummary(recipe())['ingredients'], '');
      },
    );
  });
}
