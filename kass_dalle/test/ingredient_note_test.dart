import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/recipe_portion_scaler.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// La note explicative d'un ingrédient.
///
/// Ce que ces tests verrouillent : « 1 filet de saumon de 1,8 kg **avec la peau
/// mais écaillée** » garde sa précision. La quantité se compte, la précision se
/// lit — et la seconde ne doit pas disparaître au premier redimensionnement ni
/// au premier aller-retour Firestore. Une note perdue ne lève aucune erreur :
/// l'ingrédient reste là, simplement muet.
void main() {
  group('aller-retour Firestore', () {
    test('la note survit à l\'écriture et à la relecture', () {
      const source = RecipeIngredient(
        name: 'filet de saumon',
        qty: '1.8',
        unit: 'kg',
        category: 'Pour le saumon',
        note: 'avec la peau mais écaillée',
      );
      final relu = RecipeIngredient.fromMap(source.toMap());
      expect(relu.note, 'avec la peau mais écaillée');
      expect(relu.category, 'Pour le saumon');
      expect(relu.qty, '1.8');
    });

    test('un ingrédient sans note n\'écrit pas de champ vide', () {
      const source = RecipeIngredient(name: 'sel', qty: '200', unit: 'g');
      expect(source.toMap().containsKey('note'), isFalse);
      expect(RecipeIngredient.fromMap(source.toMap()).note, isNull);
    });

    test('une note vide en base se lit comme une absence de note', () {
      // Les recettes importées avant ce champ, et celles où le modèle a rendu
      // une chaîne vide, ne doivent pas afficher une ligne blanche sous la puce.
      final relu = RecipeIngredient.fromMap({
        'name': 'sel',
        'qty': '200',
        'unit': 'g',
        'note': '   ',
      });
      expect(relu.note, isNull);
    });
  });

  group('redimensionnement', () {
    test('la quantité change, la note ne bouge pas', () {
      // « Avec la peau mais écaillée » reste vrai pour deux parts comme pour
      // douze : mettre une note à l'échelle n'aurait aucun sens.
      final mis = scaleRecipeIngredients(const [
        RecipeIngredient(
          name: 'filet de saumon',
          qty: '1.8',
          unit: 'kg',
          note: 'avec la peau mais écaillée',
        ),
      ], 2.0);
      expect(mis.single.note, 'avec la peau mais écaillée');
      expect(mis.single.qty, isNot('1.8'));
    });

    test('un facteur de 1 rend la liste telle quelle, note comprise', () {
      const liste = [
        RecipeIngredient(
          name: 'ail',
          qty: '2',
          unit: 'gousse',
          note: 'dégermées',
        ),
      ];
      expect(scaleRecipeIngredients(liste, 1.0).single.note, 'dégermées');
    });
  });
}
