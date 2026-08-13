import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/recipe_portion_scaler.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Tests du recalcul de quantités par portions.
///
/// Purement Dart (pas d'équivalent backend) : c'est de l'affichage client.
/// Visible par l'utilisateur à chaque changement de portions sur une recette.
void main() {
  group('portionScaleFactor', () {
    test('rapport simple', () {
      expect(portionScaleFactor(basePortions: 4, targetPortions: 8), 2.0);
    });

    test('réduction', () {
      expect(portionScaleFactor(basePortions: 4, targetPortions: 2), 0.5);
    });

    test('identité', () {
      expect(portionScaleFactor(basePortions: 6, targetPortions: 6), 1.0);
    });

    test('base nulle ou négative → facteur neutre', () {
      expect(portionScaleFactor(basePortions: 0, targetPortions: 8), 1.0);
      expect(portionScaleFactor(basePortions: -2, targetPortions: 8), 1.0);
    });

    test('cible nulle ou négative → facteur neutre', () {
      expect(portionScaleFactor(basePortions: 4, targetPortions: 0), 1.0);
      expect(portionScaleFactor(basePortions: 4, targetPortions: -1), 1.0);
    });
  });

  group('scaleQuantityText — entiers et décimaux', () {
    test('entier doublé', () {
      expect(scaleQuantityText('200', 2), '400');
    });

    test('entier divisé', () {
      expect(scaleQuantityText('200', 0.5), '100');
    });

    test('décimal à virgule française', () {
      expect(scaleQuantityText('1,5', 2), '3');
    });

    test('résultat non entier formaté à la française', () {
      expect(scaleQuantityText('5', 0.5), '2,5');
    });

    test('arrondi à deux décimales, zéros inutiles supprimés', () {
      expect(scaleQuantityText('10', 0.125), '1,25');
    });

    test('facteur neutre : chaîne inchangée', () {
      expect(scaleQuantityText('1 1/2', 1.0), '1 1/2');
    });

    test('chaîne vide inchangée', () {
      expect(scaleQuantityText('', 2), '');
    });

    test('texte sans nombre inchangé', () {
      expect(scaleQuantityText('une pincée', 2), 'une pincée');
    });
  });

  group('scaleQuantityText — fractions', () {
    test('fraction ASCII', () {
      expect(scaleQuantityText('1/2', 2), '1');
    });

    test('nombre mixte ASCII', () {
      expect(scaleQuantityText('1 1/2', 2), '3');
    });

    test('nombre mixte Unicode collé', () {
      expect(scaleQuantityText('1½', 2), '3');
    });

    test('fraction ASCII réduite', () {
      expect(scaleQuantityText('3/4', 2), '1,5');
    });

    test('fraction Unicode seule', () {
      expect(scaleQuantityText('½', 2), '1');
      expect(scaleQuantityText('¾', 4), '3');
    });

    test('glyphe Unicode hors du jeu historique (⅚)', () {
      expect(scaleQuantityText('⅚', 6), '5');
    });

    // Régression : quatre passes de regex successives mettaient les fractions
    // à l'échelle deux fois (« 1 1/2 » ×2 donnait « 6 » au lieu de « 3 »).
    test('aucune double mise à l\'échelle des fractions', () {
      expect(scaleQuantityText('1/2', 3), '1,5');
      expect(scaleQuantityText('1 1/2', 4), '6');
      expect(scaleQuantityText('2½', 2), '5');
    });

    test('dénominateur nul laissé intact', () {
      expect(scaleQuantityText('1/0', 2), '1/0');
    });
  });

  group('scaleRecipeIngredients', () {
    test('met à l\'échelle les quantités sans toucher au reste', () {
      final scaled = scaleRecipeIngredients(const [
        RecipeIngredient(name: 'farine', qty: '200', unit: 'g'),
        RecipeIngredient(name: 'oeuf', qty: '3', unit: 'piece'),
      ], 2);
      expect(scaled[0].qty, '400');
      expect(scaled[0].name, 'farine');
      expect(scaled[0].unit, 'g');
      expect(scaled[1].qty, '6');
    });

    test('facteur neutre : liste retournée telle quelle', () {
      const input = [RecipeIngredient(name: 'sel', qty: '1', unit: 'pincée')];
      expect(identical(scaleRecipeIngredients(input, 1.0), input), isTrue);
    });

    test('liste vide', () {
      expect(scaleRecipeIngredients(const [], 2), isEmpty);
    });
  });

  group('scaleShoppingProducts', () {
    test('met à l\'échelle les quantités de la liste de courses', () {
      final scaled = scaleShoppingProducts(const [
        RecipeShoppingProduct(name: 'lait', qty: '50', unit: 'cl'),
      ], 3);
      expect(scaled.single.qty, '150');
      expect(scaled.single.unit, 'cl');
    });
  });
}
