import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/recipe_tag_sections.dart';
import 'package:kass_dalle/features/recipes/domain/meal_role.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le rôle d'une recette dans un repas, côté client : la liste proposée à
/// l'utilisateur et son affichage. Les valeurs sont celles du serveur, qui
/// seul lit la réponse du modèle ; un écart ferait proposer un rôle que le
/// planning ne connaît pas, sans lever d'erreur. La fixture partagée les
/// verrouille.
void main() {
  final file = File('test-fixtures/meal_roles.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('la liste des rôles est la même que côté serveur', () {
    expect(kMealRoles, List<String>.from(fixture['roles'] as List));
  });

  test(
    'chaque rôle a un libellé français, une valeur inconnue reste lisible',
    () {
      for (final role in kMealRoles) {
        expect(mealRoleLabel(role), isNotEmpty);
        expect(mealRoleLabel(role), isNot(role));
      }
      expect(mealRoleLabel('entree'), 'Entrée');
      expect(mealRoleLabel('brunch'), 'brunch');
    },
  );

  group('buildRecipeTagSections', () {
    test('le rôle s\'affiche en dernier, en français', () {
      final sections = buildRecipeTagSections(
        const RecipeTags(
          cuisines: ['française'],
          dishTypes: ['viande'],
          mealRole: 'plat',
        ),
      );
      expect(sections.map((s) => s.label), [
        'Cuisine',
        'Type de plat',
        'Rôle dans un repas',
      ]);
      expect(sections.last.values, ['Plat']);
    });

    test('sans rôle, pas de section', () {
      for (final tags in const [
        RecipeTags(cuisines: ['française']),
        RecipeTags(cuisines: ['française'], mealRole: ''),
        RecipeTags(cuisines: ['française'], mealRole: '  '),
      ]) {
        expect(
          buildRecipeTagSections(tags).map((s) => s.label),
          isNot(contains('Rôle dans un repas')),
        );
      }
    });

    test('le résumé de la liste garde Cuisine et Type de plat', () {
      final summary = buildRecipeTagSummary(
        const RecipeTags(
          cuisines: ['française'],
          dishTypes: ['viande'],
          mealRole: 'plat',
        ),
      );
      expect(summary, 'Cuisine: française | Type de plat: viande');
    });
  });
}
