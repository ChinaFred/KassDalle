import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
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

  test('protéines, féculents et rôles qui les portent : mêmes listes que '
      'côté serveur', () {
    expect(kMainProteins, List<String>.from(fixture['main_proteins'] as List));
    expect(kMainStarches, List<String>.from(fixture['main_starches'] as List));
    expect(
      kRolesWithMainIngredients,
      List<String>.from(fixture['roles_with_main_ingredients'] as List),
    );
  });

  test('chaque protéine et chaque féculent a un libellé français', () {
    for (final p in kMainProteins) {
      expect(mainProteinLabel(p), isNotEmpty);
    }
    for (final s in kMainStarches) {
      expect(mainStarchLabel(s), isNotEmpty);
    }
    expect(mainProteinLabel('boeuf'), 'Bœuf');
    expect(mainProteinLabel('fruits_de_mer'), 'Fruits de mer');
    expect(mainStarchLabel('pommes_de_terre'), 'Pommes de terre');
    expect(mainStarchLabel('aucun'), 'Sans féculent');
    expect(mainProteinLabel('oeuf'), 'Œuf');
    // Une valeur inconnue reste lisible telle quelle.
    expect(mainProteinLabel('veau'), 'veau');
  });

  group('protéine et féculent dans la fiche', () {
    test('un plat les affiche après son rôle', () {
      final sections = buildRecipeTagSections(
        const RecipeTags(
          mealRole: 'plat',
          mainProtein: 'volaille',
          mainStarch: 'riz',
        ),
      );
      expect(sections.map((s) => s.label), [
        'Rôle dans un repas',
        'Protéine principale',
        'Féculent principal',
      ]);
      expect(sections[1].values, ['Volaille']);
      expect(sections[2].values, ['Riz']);
    });

    test('un dessert ne les affiche pas, même restés d\'un ancien rôle', () {
      final sections = buildRecipeTagSections(
        const RecipeTags(
          mealRole: 'dessert',
          mainProtein: 'oeuf',
          mainStarch: 'pain',
        ),
      );
      expect(sections.map((s) => s.label), ['Rôle dans un repas']);
    });

    test('lus et réécrits avec la carte des tags', () {
      final tags = RecipeTags.fromMap({
        'meal_role': 'accompagnement',
        'main_protein': 'vegetarien',
        'main_starch': 'pommes_de_terre',
      });
      expect(tags.mainProtein, 'vegetarien');
      expect(tags.mainStarch, 'pommes_de_terre');
      final map = tags.toMap();
      expect(map['main_protein'], 'vegetarien');
      expect(map['main_starch'], 'pommes_de_terre');
      // Lecture tolérante : un type inattendu vaut absent.
      final bad = RecipeTags.fromMap({
        'meal_role': 'plat',
        'main_protein': 42,
        'main_starch': ['riz'],
        'main_ingredients_checked_at': 'hier',
      });
      expect(bad.mainProtein, isNull);
      expect(bad.mainStarch, isNull);
      expect(bad.mainIngredientsCheckedAt, isNull);
      // Le marqueur d'examen survit à une carte réécrite en bloc.
      final checked = RecipeTags.fromMap({
        'meal_role': 'plat',
        'main_ingredients_checked_at': Timestamp.fromDate(
          DateTime(2026, 10, 10),
        ),
      });
      expect(checked.mainIngredientsCheckedAt, DateTime(2026, 10, 10));
      expect(
        checked.toMap()['main_ingredients_checked_at'],
        DateTime(2026, 10, 10),
      );
      // Absents : pas de clé, une écriture ne les efface pas.
      expect(
        const RecipeTags(mealRole: 'plat').toMap().containsKey('main_protein'),
        isFalse,
      );
    });
  });

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

  group('ce que la recette apporte', () {
    test('mêmes valeurs que côté serveur, chacune avec son libellé', () {
      expect(kMealContains, List<String>.from(fixture['contains'] as List));
      expect(kMealContains.map(mealContainsLabel), [
        'Protéine',
        'Féculent',
        'Légume',
      ]);
      expect(mealContainsLabel('fibre'), 'fibre');
    });

    final cases = (fixture['contains_manual_cases'] as List)
        .cast<Map<String, dynamic>>();
    for (final c in cases) {
      test('correction à la main : ${c['name']}', () {
        final tags = RecipeTags.fromMap(
          Map<String, dynamic>.from(c['tags'] as Map),
        );
        expect(tags.containsManual, c['manual']);
        final after = mealContainsAfterSuggestion(
          manual: tags.containsManual,
          current: tags.contains,
          suggested: List<String>.from(c['model_contains'] as List),
        );
        expect(after, List<String>.from(c['result'] as List));
      });
    }

    test(
      'le marqueur est réécrit avec la carte, absent quand il ne vaut pas',
      () {
        final manual = RecipeTags.fromMap({
          'meal_role': 'plat',
          'contains': ['proteine'],
          'contains_manual': true,
        });
        expect(manual.toMap()['contains_manual'], isTrue);
        expect(
          const RecipeTags(
            mealRole: 'plat',
          ).toMap().containsKey('contains_manual'),
          isFalse,
        );
      },
    );

    test(
      'choisir un féculent coche Féculent, « Sans féculent » le décoche',
      () {
        expect(mealContainsWithStarch(['proteine'], 'riz'), [
          'proteine',
          'feculent',
        ]);
        expect(
          mealContainsWithStarch(['feculent', 'proteine', 'legume'], 'aucun'),
          ['proteine', 'legume'],
        );
        expect(mealContainsWithStarch(['legume'], null), ['legume']);
      },
    );

    test("la fiche dit ce qu'apporte un plat, après le féculent", () {
      final sections = buildRecipeTagSections(
        const RecipeTags(
          mealRole: 'plat',
          mainStarch: 'riz',
          contains: ['legume', 'proteine'],
        ),
      );
      expect(sections.last.label, 'Apporte');
      expect(sections.last.values, ['Protéine', 'Légume']);
      expect(
        buildRecipeTagSections(
          const RecipeTags(mealRole: 'dessert', contains: ['feculent']),
        ).map((s) => s.label),
        isNot(contains('Apporte')),
      );
    });
  });
}
