import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/language_names.dart';
import 'package:kass_dalle/features/processing/domain/processing_step_labels.dart';
import 'package:kass_dalle/features/recipes/domain/original_text.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

class _FakeTimestamp {
  final DateTime value;
  const _FakeTimestamp(this.value);
  DateTime toDate() => value;
}

Map<String, dynamic> _doc({String? langueOrigine}) => {
  'titre': 'Banana bread',
  'langue': 'fr',
  'raw_cooklang': 'Mélanger.',
  'created_by': 'u1',
  'created_at': _FakeTimestamp(DateTime(2026, 10, 10)),
  'updated_at': _FakeTimestamp(DateTime(2026, 10, 10)),
  'langue_origine': ?langueOrigine,
};

void main() {
  group("Recipe — langue d'origine", () {
    test("une recette traduite porte sa langue d'origine", () {
      final recipe = Recipe.fromFirestore('r1', _doc(langueOrigine: 'en'));
      expect(recipe.langueOrigine, 'en');
      expect(recipe.isTranslated, isTrue);
    });

    test("une recette française n'a rien de plus", () {
      final recipe = Recipe.fromFirestore('r1', _doc());
      expect(recipe.langueOrigine, isNull);
      expect(recipe.isTranslated, isFalse);
    });

    test("le client n'écrit jamais la langue d'origine", () {
      final recipe = Recipe.fromFirestore('r1', _doc(langueOrigine: 'en'));
      expect(recipe.toFirestore().containsKey('langue_origine'), isFalse);
    });

    test("une édition garde la langue d'origine", () {
      final recipe = Recipe.fromFirestore('r1', _doc(langueOrigine: 'ja'));
      expect(recipe.copyWith(titre: 'Autre').langueOrigine, 'ja');
    });
  });

  group('noms de langues', () {
    test('forme « Traduit de… » avec élision écrite dans la table', () {
      expect(translatedFromLabel('en'), "Traduit de l'anglais");
      expect(translatedFromLabel('ja'), 'Traduit du japonais');
      expect(translatedFromLabel('he'), "Traduit de l'hébreu");
      expect(translatedFromLabel('EN-gb'), "Traduit de l'anglais");
    });

    test('un code absent de la table ne prétend rien', () {
      expect(translatedFromLabel('xx'), "Traduit d'une autre langue");
      expect(languageName('xx'), isNull);
      expect(inLanguageLabel('xx'), "dans sa langue d'origine (xx)");
      expect(inLanguageLabel('it'), 'en italien');
    });

    test("sens d'écriture", () {
      expect(isRightToLeft('ar'), isTrue);
      expect(isRightToLeft('he'), isTrue);
      expect(isRightToLeft('en'), isFalse);
    });
  });

  group("OriginalText — lecture du sous-document", () {
    test('les groupes, les lignes et les notes sont relus', () {
      final text = OriginalText.fromMap({
        'langue': 'en',
        'titre': 'Banana bread',
        'introduction': '  ',
        'sections_ingredients': [
          {
            'titre': 'For the batter',
            'lignes': ['3 bananas', ' ', '2 cups flour'],
          },
          {'titre': 'Vide', 'lignes': <String>[]},
        ],
        'sections_etapes': [
          {
            'titre': '',
            'etapes': ['Preheat the oven to 350°F.', 'Bake.'],
          },
        ],
        'notes': [
          {'genre': 'Tip', 'texte': 'Very ripe bananas.'},
          {'genre': 'Vide', 'texte': ''},
        ],
      });
      expect(text.langue, 'en');
      expect(text.introduction, isNull);
      expect(text.ingredientSections, hasLength(1));
      expect(text.ingredientSections.single.lignes, [
        '3 bananas',
        '2 cups flour',
      ]);
      expect(text.stepSections.single.lignes, hasLength(2));
      expect(text.notes.single.genre, 'Tip');
    });
  });

  test("l'étape de traduction a un libellé", () {
    expect(
      formatProcessingStep('translate'),
      "Traduction de la recette par l'IA…",
    );
  });
}
