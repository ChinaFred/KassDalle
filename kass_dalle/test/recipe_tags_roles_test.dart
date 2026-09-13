import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le rôle d'une recette dans un repas, porté par ses tags.
///
/// Le défaut à éviter ne lève rien : un formulaire qui réécrit `tags` sans
/// connaître le rôle l'efface, et le planning retrouve une recette « pas
/// encore classée » que le backfill avait classée la veille.
void main() {
  group('rôle dans un repas', () {
    test('lu depuis Firestore', () {
      final tags = RecipeTags.fromMap({
        'meal_role': 'plat',
        'contains': ['proteine'],
        'suggested_sides': ['riz', 'pommes vapeur'],
      });
      expect(tags.mealRole, 'plat');
      expect(tags.hasMealRole, isTrue);
      expect(tags.contains, ['proteine']);
      expect(tags.suggestedSides, ['riz', 'pommes vapeur']);
    });

    test('absent : pas classée, et rien n\'est écrit', () {
      final tags = RecipeTags.fromMap({
        'cuisines': ['Belge'],
      });
      expect(tags.mealRole, isNull);
      expect(tags.hasMealRole, isFalse);
      expect(tags.contains, isEmpty);
      final map = tags.toMap();
      expect(map.containsKey('meal_role'), isFalse);
      expect(map.containsKey('contains'), isFalse);
      expect(map.containsKey('suggested_sides'), isFalse);
      expect(map['cuisines'], ['Belge']);
    });

    test('écrit dès que le rôle est connu, listes vides comprises', () {
      final map = const RecipeTags(mealRole: 'dessert').toMap();
      expect(map['meal_role'], 'dessert');
      expect(map['contains'], isEmpty);
      expect(map['suggested_sides'], isEmpty);
    });

    test(
      'copyWith sans argument garde le rôle : le formulaire ne l\'efface pas',
      () {
        const base = RecipeTags(
          mealRole: 'plat',
          contains: ['proteine', 'legume'],
          suggestedSides: ['riz'],
        );
        // Ce que fait `buildTagsFromForm` : les champs du formulaire seulement.
        final edited = base.copyWith(cuisines: ['Française'], prepTime: 20);
        expect(edited.mealRole, 'plat');
        expect(edited.contains, ['proteine', 'legume']);
        expect(edited.suggestedSides, ['riz']);
        expect(edited.cuisines, ['Française']);
      },
    );

    test('aller-retour Firestore', () {
      const tags = RecipeTags(
        dishTypes: ['viande'],
        mealRole: 'plat',
        contains: ['proteine'],
        suggestedSides: ['purée', 'haricots verts'],
      );
      final back = RecipeTags.fromMap(tags.toMap());
      expect(back.mealRole, 'plat');
      expect(back.contains, ['proteine']);
      expect(back.suggestedSides, ['purée', 'haricots verts']);
      expect(back.dishTypes, ['viande']);
    });
  });
}
