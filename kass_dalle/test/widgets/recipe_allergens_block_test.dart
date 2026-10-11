import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/allergens.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/recipe_allergens_block.dart';

/// Le bloc « Allergènes » de la fiche recette, dans ses états. Le champ
/// absent ne pose aucun bloc : c'est l'appelant qui décide, le test le
/// rejoue avec la même condition.
void main() {
  Future<void> pump(WidgetTester tester, RecipeAllergens? allergens) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              if (allergens != null) RecipeAllergensBlock(allergens: allergens),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('champ absent : rien du tout', (tester) async {
    await pump(tester, null);
    expect(find.text('Allergènes'), findsNothing);
    expect(find.text(RecipeAllergensBlock.disclaimer), findsNothing);
  });

  testWidgets('complet et vide : aucun allergène majeur', (tester) async {
    await pump(tester, const RecipeAllergens(present: [], complete: true));
    expect(find.text('Allergènes'), findsOneWidget);
    expect(find.text(RecipeAllergensBlock.noneDetected), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text(RecipeAllergensBlock.disclaimer), findsOneWidget);
  });

  testWidgets('complet avec allergènes : pastilles seules, ordre UE', (
    tester,
  ) async {
    await pump(
      tester,
      const RecipeAllergens(
        present: ['oeuf', 'lait'],
        complete: true,
        byIngredient: {
          'oeuf': ['œufs', 'mayonnaise'],
          'lait': ['beurre'],
        },
      ),
    );
    expect(find.byType(ActionChip), findsNWidgets(2));
    final oeuf = tester.getTopLeft(find.text('Œuf'));
    final lait = tester.getTopLeft(find.text('Lait'));
    expect(oeuf.dx < lait.dx || oeuf.dy < lait.dy, isTrue);
    expect(find.text(RecipeAllergensBlock.noneDetected), findsNothing);
    expect(
      find.text(RecipeAllergensBlock.incompleteWithAllergens),
      findsNothing,
    );
    expect(find.text(RecipeAllergensBlock.disclaimer), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Allergène : Œuf. Afficher les ingrédients en cause.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('incomplet avec allergènes : avertissement puis pastilles', (
    tester,
  ) async {
    await pump(
      tester,
      const RecipeAllergens(
        present: ['gluten'],
        complete: false,
        byIngredient: {
          'gluten': ['farine'],
        },
      ),
    );
    expect(
      find.text(RecipeAllergensBlock.incompleteWithAllergens),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.help_outline), findsOneWidget);
    expect(find.byType(ActionChip), findsOneWidget);
    expect(find.text(RecipeAllergensBlock.disclaimer), findsOneWidget);
  });

  testWidgets('incomplet et vide : avertissement seul', (tester) async {
    await pump(tester, const RecipeAllergens(present: [], complete: false));
    expect(find.text(RecipeAllergensBlock.incompleteWithout), findsOneWidget);
    expect(find.byType(ActionChip), findsNothing);
    expect(find.text(RecipeAllergensBlock.noneDetected), findsNothing);
    expect(find.text(RecipeAllergensBlock.disclaimer), findsOneWidget);
  });

  testWidgets('appui sur une pastille : ingrédients en cause', (tester) async {
    await pump(
      tester,
      const RecipeAllergens(
        present: ['lait', 'lactose'],
        complete: true,
        byIngredient: {
          'lait': ['beurre', 'crème'],
        },
      ),
    );
    // Clé inconnue affichée en clair.
    expect(find.text('lactose'), findsOneWidget);

    await tester.tap(find.text('Lait'));
    await tester.pumpAndSettle();
    expect(find.text('Ingrédients en cause'), findsOneWidget);
    expect(find.text('beurre'), findsOneWidget);
    expect(find.text('crème'), findsOneWidget);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Ingrédients en cause'), findsNothing);

    await tester.tap(find.text('lactose'));
    await tester.pumpAndSettle();
    expect(find.text('Ingrédient en cause non précisé.'), findsOneWidget);
  });
}
