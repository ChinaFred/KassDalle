import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Valeurs nutritionnelles par portion, calculées à l'affichage.
///
/// Le bloc `nutrition` vit sur la recette, document partagé par toute la
/// famille. Il est donc calculé aux portions **de la recette**, et jamais à
/// celles qu'un lecteur a choisies : l'y écrire faisait que chacun écrasait
/// l'affichage des autres, sans qu'aucune erreur ne soit levée.
///
/// Seule la division par le nombre de parts dépendait de ce choix. Elle se
/// fait ici, dans le contexte qui la demande.
RecipeNutritionSnapshot _snapshot({
  required int selectedPortions,
  required Map<String, double> totals,
}) {
  return RecipeNutritionSnapshot(
    selectedPortions: selectedPortions,
    totalWeightG: 1000,
    coverage: 1,
    coverageState: 'full',
    totals: totals,
    perPortion: {
      for (final e in totals.entries) e.key: e.value / selectedPortions,
    },
    per100g: null,
    quality: const RecipeNutritionQuality(
      score: 100,
      level: 'high',
      warnings: [],
    ),
  );
}

void main() {
  final snapshot = _snapshot(
    selectedPortions: 4,
    totals: const {'kcal': 2000, 'protein_g': 100},
  );

  test('aux portions de référence, les valeurs stockées sont rendues', () {
    expect(snapshot.perPortionFor(4)['kcal'], 500);
    expect(snapshot.perPortionFor(4)['protein_g'], 25);
  });

  test('sans contexte, la référence de la recette s\'applique', () {
    expect(snapshot.perPortionFor(null)['kcal'], 500);
  });

  test('un repas planifié pour 8 divise les mêmes totaux', () {
    expect(snapshot.perPortionFor(8)['kcal'], 250);
    expect(snapshot.perPortionFor(8)['protein_g'], 12.5);
  });

  test('un repas pour 2 aussi, sans rien recalculer côté serveur', () {
    expect(snapshot.perPortionFor(2)['kcal'], 1000);
  });

  test('les totaux ne bougent jamais : ils décrivent la recette', () {
    snapshot.perPortionFor(8);
    expect(snapshot.totals['kcal'], 2000);
  });

  test('un nombre de parts absurde retombe sur la référence', () {
    // Une recette mal saisie ne doit pas produire une division par zéro
    // affichée comme une valeur nutritionnelle.
    expect(snapshot.perPortionFor(0)['kcal'], 500);
    expect(snapshot.perPortionFor(-3)['kcal'], 500);
  });

  test('un bloc hérité, calculé aux parts d\'un lecteur, reste juste', () {
    // Les recettes déjà en base portent le choix de celui qui a bougé le
    // curseur en dernier. La division part des totaux : le résultat est
    // correct avant même que le bloc ait été recalculé.
    final legacy = _snapshot(selectedPortions: 2, totals: const {'kcal': 2000});
    expect(legacy.perPortionFor(4)['kcal'], 500);
    expect(legacy.perPortionFor(2)['kcal'], 1000);
  });
}
