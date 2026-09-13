import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Un composant de repas : ce qu'il fige, ce qu'il écrit, ce qu'il compte.
void main() {
  const riz = MealStaple(
    id: 'riz',
    name: 'Riz',
    category: StapleCategory.feculent,
    quantityPerPortion: 70,
    note: 'poids cru',
  );

  group('garniture figée', () {
    test('reprend nom, part, unité, note', () {
      final c = MealComponent.staple(riz, justification: 'pas de féculent');
      expect(c.role, MealComponentRole.accompagnement);
      expect(c.stapleId, 'riz');
      expect(c.isStaple, isTrue);
      expect(c.isRecipe, isFalse);
      expect(c.label, 'Riz');
      expect(c.quantityPerPortion, 70);
      expect(c.unit, 'g');
      expect(c.note, 'poids cru');
      expect(c.shoppingProduct, isNull);
      expect(c.effectiveShoppingProduct, 'Riz');
      expect(c.sourceId, 'riz');
      expect(c.justification, 'pas de féculent');
    });

    test('le produit de courses de la purée est la pomme de terre', () {
      const puree = MealStaple(
        id: 'puree',
        name: 'Purée',
        category: StapleCategory.feculent,
        quantityPerPortion: 250,
        shoppingProduct: 'Pommes de terre',
      );
      expect(
        MealComponent.staple(puree).effectiveShoppingProduct,
        'Pommes de terre',
      );
    });

    test('quantité pour les parts : 4 parts, 280 g ; sans parts, une part', () {
      final c = MealComponent.staple(riz);
      expect(c.totalQuantityFor(4), 280);
      expect(c.totalQuantityFor(null), 70);
      expect(c.totalQuantityFor(0), 70);
      expect(c.quantityLabel, '70 g par part');
    });
  });

  group('recette d\'accompagnement', () {
    test('porte l\'identifiant et le titre, pas de quantité', () {
      final t = DateTime(2026, 1, 1);
      final frites = Recipe(
        id: 'frites',
        titre: 'Frites maison',
        langue: 'fr',
        rawCooklang: '',
        imageUrls: const [],
        reviewStatus: ReviewStatus.validated,
        tags: const RecipeTags(mealRole: 'accompagnement'),
        ingredientsIndex: const [],
        createdBy: 'u',
        createdAt: t,
        updatedAt: t,
      );
      final c = MealComponent.recipe(frites);
      expect(c.isRecipe, isTrue);
      expect(c.recipeId, 'frites');
      expect(c.label, 'Frites maison');
      expect(c.quantityLabel, isNull);
      expect(c.totalQuantityFor(4), isNull);
      expect(c.sourceId, 'frites');
    });
  });

  group('Firestore', () {
    test('aller-retour d\'une garniture', () {
      final c = MealComponent.staple(riz, justification: 'x');
      final back = MealComponent.fromMap(c.toMap());
      expect(back.stapleId, 'riz');
      expect(back.recipeId, isNull);
      expect(back.quantityPerPortion, 70);
      expect(back.unit, 'g');
      expect(back.note, 'poids cru');
      expect(back.justification, 'x');
      expect(c.toMap().containsKey('recipe_id'), isFalse);
      expect(c.toMap().containsKey('shopping_product'), isFalse);
    });

    test('une liste abîmée ne casse pas la lecture', () {
      final out = MealComponent.listFromFirestore([
        {'role': 'accompagnement', 'staple_id': 'riz', 'label': 'Riz'},
        'pas une carte',
        {'role': 'inconnu', 'label': 'Sans rôle connu'},
      ]);
      expect(out, hasLength(2));
      expect(out.first.stapleId, 'riz');
      expect(out.last.role, MealComponentRole.accompagnement);
    });

    test('pas une liste : rien', () {
      expect(MealComponent.listFromFirestore(null), isEmpty);
      expect(MealComponent.listFromFirestore('riz'), isEmpty);
    });
  });

  test('résumé en une ligne', () {
    expect(
      componentsSummary([
        MealComponent.staple(riz),
        const MealComponent(
          role: MealComponentRole.dessert,
          label: 'Tarte aux pommes',
        ),
      ]),
      'Riz · Tarte aux pommes',
    );
  });
}
