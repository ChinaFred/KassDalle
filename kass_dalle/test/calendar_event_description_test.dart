import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/app_links.dart';
import 'package:kass_dalle/features/planning/domain/calendar_event_description.dart';
import 'package:kass_dalle/features/planning/domain/meal_recipe_location.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';

/// Le lien collé dans un événement Google Calendar.
///
/// Il n'est lu par aucun code : c'est un navigateur qui l'ouvre, une heure
/// avant de cuisiner. Une adresse fausse ne lève rien — elle affiche
/// l'accueil, ou une page blanche, et le lecteur retape le titre.
void main() {
  PlannedMeal meal({
    String? recipeId = 'abc',
    int? basePortions,
    int? targetPortions,
    DateTime? prepDate,
  }) {
    return PlannedMeal(
      id: 'm1',
      uid: 'u1',
      recipeId: recipeId,
      recipeTitre: 'Gratin dauphinois',
      plannedAt: DateTime(2026, 9, 12, 19, 30),
      durationMinutes: 60,
      basePortions: basePortions,
      targetPortions: targetPortions,
      prepDate: prepDate,
      createdAt: DateTime(2026, 9, 1),
    );
  }

  group('adresse publique', () {
    test('la route passe entière derrière le dièse, paramètres compris', () {
      expect(
        appWebLink('/recipes/abc?portions=8').toString(),
        'https://kassdale-6d948.web.app/#/recipes/abc?portions=8',
      );
    });

    test('une route nue garde le même dessin', () {
      expect(
        appWebLink('/recipes/abc').toString(),
        'https://kassdale-6d948.web.app/#/recipes/abc',
      );
    });
  });

  group('route de la fiche recette', () {
    test('sans contexte, la fiche telle qu\'elle est écrite', () {
      expect(recipeLocationFor(recipeId: 'abc'), '/recipes/abc');
    });

    test('les parts ne voyagent que si elles diffèrent de la recette', () {
      expect(
        recipeLocationFor(recipeId: 'abc', targetPortions: 4, basePortions: 4),
        '/recipes/abc',
      );
      expect(
        recipeLocationFor(recipeId: 'abc', targetPortions: 8, basePortions: 4),
        '/recipes/abc?portions=8',
      );
    });

    test('le jour de préparation emmène le jour du repas avec lui', () {
      expect(
        recipeLocationFor(
          recipeId: 'abc',
          prepDate: DateTime(2026, 9, 10),
          mealDate: DateTime(2026, 9, 12, 19, 30),
        ),
        '/recipes/abc?prep=2026-09-10&meal=2026-09-12',
      );
    });

    test('un repas sans recette n\'a pas d\'adresse', () {
      expect(mealRecipeLocation(meal(recipeId: null)), isNull);
      expect(mealRecipeLocation(meal(recipeId: '')), isNull);
    });
  });

  group('description de l\'événement', () {
    test('le lien vient en premier, avec les parts et les dates du repas', () {
      final description = mealCalendarDescription(
        meal(
          basePortions: 4,
          targetPortions: 8,
          prepDate: DateTime(2026, 9, 10),
        ),
      );

      expect(
        description.split('\n').first,
        '📖 Recette : https://kassdale-6d948.web.app/#/recipes/abc'
        '?portions=8&prep=2026-09-10&meal=2026-09-12',
      );
      expect(description, endsWith(kCalendarSignature));
    });

    test('sans recette, la signature seule', () {
      expect(mealCalendarDescription(meal(recipeId: null)), kCalendarSignature);
    });

    test(
      'les détails de l\'écran se placent entre le lien et la signature',
      () {
        final description = buildCalendarDescription(
          recipeLocation: '/recipes/abc',
          details: const ['⏱ Préparation : 20 min', '🔥 Cuisson : 40 min'],
        );

        expect(
          description,
          '📖 Recette : https://kassdale-6d948.web.app/#/recipes/abc\n'
          '\n'
          '⏱ Préparation : 20 min\n'
          '🔥 Cuisson : 40 min\n'
          '\n'
          'Repas planifié avec Kass\'Dalle',
        );
      },
    );
  });
}
