import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/cooklang_parser.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Tests du parseur CookLang côté Dart.
///
/// CookLang est le format de stockage de toutes les recettes : ce parseur et son
/// jumeau TypeScript (`functions/src/cooklang/parser.ts`) doivent lire la même
/// recette de la même façon. Les cas viennent de `test-fixtures/`, rejoués par
/// les deux suites.
Map<String, dynamic> _loadFixture(String name) {
  final file = File('test-fixtures/$name');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

PageType _pageTypeFromString(String raw) => switch (raw) {
  'technique' => PageType.technique,
  'equipment' => PageType.equipment,
  'ingredient_note' => PageType.ingredientNote,
  'other' => PageType.other,
  _ => PageType.recipe,
};

void main() {
  final fixture = _loadFixture('cooklang_parsing.json');
  final recipes = (fixture['recipes'] as List).cast<Map<String, dynamic>>();

  test('la fixture partagée est non vide', () {
    expect(recipes, isNotEmpty);
  });

  for (final r in recipes) {
    final label = r['label'] as String;
    final cooklang = r['cooklang'] as String;

    group('CookLang — $label', () {
      test('ingrédients structurés (${r['why']})', () {
        final expected = (r['ingredients'] as List)
            .cast<Map<String, dynamic>>();
        final actual = extractIngredientsStructured(cooklang);

        expect(
          actual.length,
          expected.length,
          reason:
              'attendu ${expected.length} ingrédient(s), '
              'obtenu ${actual.map((i) => '${i.name}(${i.qty}${i.unit})').toList()}',
        );
        for (var i = 0; i < expected.length; i++) {
          expect(actual[i].name, expected[i]['name'], reason: 'nom #$i');
          expect(actual[i].qty, expected[i]['qty'], reason: 'quantité #$i');
          expect(actual[i].unit, expected[i]['unit'], reason: 'unité #$i');
          expect(
            actual[i].category,
            expected[i]['category'],
            reason: 'catégorie #$i',
          );
        }
      });

      test('liste des noms d\'ingrédients', () {
        expect(
          extractIngredients(cooklang),
          (r['names'] as List).cast<String>(),
        );
      });

      test('index de recherche partagé', () {
        expect(
          buildIngredientsIndex(extractIngredientsStructured(cooklang)),
          (r['index'] as List).cast<String>(),
        );
      });

      test('titre', () {
        expect(extractTitle(cooklang), r['title']);
      });

      test('portions', () {
        expect(extractPortions(cooklang), r['portions']);
      });

      test('numéro de page', () {
        expect(extractPageNumber(cooklang), r['pageNumber']);
      });

      test('type de page', () {
        expect(
          extractPageType(cooklang),
          _pageTypeFromString(r['pageType'] as String),
        );
      });

      test('tags', () {
        final expected = r['tags'] as Map<String, dynamic>;
        final actual = extractRecipeTags(cooklang);
        expect(actual.difficulty, expected['difficulty'], reason: 'difficulté');
        expect(actual.prepTime, expected['prepTime'], reason: 'temps de prépa');
        expect(actual.cookTime, expected['cookTime'], reason: 'temps de cuisson');
        expect(
          actual.dishTypes,
          (expected['dishTypes'] as List).cast<String>(),
          reason: 'types de plat',
        );
      });
    });
  }

  group('parsePageTypeLabel — cas partagés', () {
    final cases = (fixture['pageTypeLabels'] as List)
        .cast<Map<String, dynamic>>();
    for (final c in cases) {
      test('« ${c['input']} » → ${c['expected']}  (${c['why']})', () {
        expect(
          parsePageTypeLabel(c['input'] as String),
          _pageTypeFromString(c['expected'] as String),
        );
      });
    }
  });

  group('stripCooklangMeta — cas partagés', () {
    final cases = (fixture['stripMeta'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      test(c['why'] as String, () {
        expect(stripCooklangMeta(c['input'] as String), c['expected']);
      });
    }
  });

  group('parseCooklangMeta — propriétés', () {
    test('les clés sont normalisées en minuscules, les valeurs non', () {
      final meta = parseCooklangMeta('>> Titre: Mon Plat\n>> PORTIONS: 4\n');
      expect(meta['titre'], 'Mon Plat');
      expect(meta['portions'], '4');
    });

    test('une ligne >> sans deux-points est ignorée', () {
      expect(parseCooklangMeta('>> ligne sans separateur\n'), isEmpty);
    });

    test('les deux-points suivants restent dans la valeur', () {
      final meta = parseCooklangMeta('>> source: Livre: tome 2\n');
      expect(meta['source'], 'Livre: tome 2');
    });
  });

  group('ingredientKey — normalisation de déduplication', () {
    test('accents et majuscules sont neutralisés', () {
      expect(ingredientKey('Crème Fraîche'), ingredientKey('creme fraiche'));
    });

    test('le pluriel de chaque mot est neutralisé', () {
      expect(ingredientKey('tomates cerises'), 'tomate cerise');
    });

    test('les mots de deux lettres gardent leur s', () {
      expect(ingredientKey('os'), 'os');
    });

    test('les apostrophes typographiques sont normalisées', () {
      expect(ingredientKey('huile d’olive'), ingredientKey("huile d'olive"));
    });
  });

  group('extractPortions — formats tolérés', () {
    test('accepte « 4 personnes »', () {
      expect(extractPortions('>> portions: 4 personnes\n'), 4);
    });

    test('accepte l\'alias servings', () {
      expect(extractPortions('>> servings: 8\n'), 8);
    });

    test('retourne null si non numérique', () {
      expect(extractPortions('>> portions: beaucoup\n'), isNull);
    });
  });
}

