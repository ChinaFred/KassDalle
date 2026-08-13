import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/cooklang_preview.dart';

/// Filet de caractérisation de l'aperçu CookLang.
///
/// Écrits **avant** le découpage de `_buildPreview` (430 lignes), ces tests
/// décrivent ce que l'écran affiche aujourd'hui. Leur rôle n'est pas de juger
/// ce comportement : c'est de garantir qu'il ne change pas pendant qu'on
/// déplace le code. Un refactoring dont personne ne peut prouver qu'il est
/// neutre n'est pas un refactoring, c'est une réécriture.
void main() {
  Future<void> pump(
    WidgetTester tester,
    String cooklang, {
    List<RecipeIngredient>? overrideIngredients,
    RecipeTags? tags,
    int? basePortions,
    int? selectedPortions,
    Widget? topContent,
    Widget? bottomContent,
    VoidCallback? onCreateShoppingList,
  }) async {
    final ctrl = TextEditingController(text: cooklang);
    addTearDown(ctrl.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('fr'),
        home: Scaffold(
          body: CooklangPreview(
            ctrl: ctrl,
            overrideIngredients: overrideIngredients,
            recipeTags: tags,
            basePortions: basePortions,
            selectedPortions: selectedPortions,
            topContent: topContent,
            bottomContent: bottomContent,
            onCreateShoppingList: onCreateShoppingList,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// Le texte des étapes est rendu en RichText — les ingrédients y sont des
  /// jetons insérés en WidgetSpan.
  Finder richTextContaining(String s) =>
      find.textContaining(s, findRichText: true);

  /// Un ingrédient apparaît à **deux** endroits : en puce dans la liste des
  /// ingrédients, et en jeton au fil de l'étape qui l'emploie. Les deux n'ont
  /// pas le même rôle, ni la même source — la liste vient du modèle, le jeton
  /// du texte. Les tests visent donc la puce, seul endroit que la liste pilote :
  /// la liste utilise `Chip`, le jeton un simple `Container`.
  Finder ingredientChip(String label) => find.widgetWithText(Chip, label);

  group('contenu vide', () {
    testWidgets('un texte vide le dit, sans sections fantômes', (tester) async {
      await pump(tester, '   ');
      expect(find.text('Aucun contenu à afficher'), findsOneWidget);
      expect(find.text('Ingrédients'), findsNothing);
      expect(find.text('Préparation'), findsNothing);
    });
  });

  group('métadonnées', () {
    testWidgets('portions, préparation et cuisson deviennent des puces', (
      tester,
    ) async {
      await pump(
        tester,
        '>> portions: 4\n>> prep_time: 20\n>> cook_time: 45\nMélanger.',
      );

      expect(find.textContaining('4'), findsWidgets);
      expect(find.text('Prép. 20 min'), findsOneWidget);
      expect(find.text('Cuisson 45 min'), findsOneWidget);
    });

    testWidgets('sans métadonnée de temps, aucune puce de temps', (
      tester,
    ) async {
      await pump(tester, 'Mélanger la @farine{200%g}.');
      expect(find.textContaining('Prép.'), findsNothing);
      expect(find.textContaining('Cuisson'), findsNothing);
    });
  });

  group('ingrédients', () {
    testWidgets('les ingrédients balisés sont extraits du texte', (
      tester,
    ) async {
      await pump(
        tester,
        'Mélanger la @farine{200%g} et le @lait{50%cl}.',
      );

      expect(find.text('Ingrédients'), findsOneWidget);
      expect(ingredientChip('200 g farine'), findsOneWidget);
      expect(ingredientChip('50 cl lait'), findsOneWidget);
    });

    testWidgets('un ingrédient répété entre étapes n\'est listé qu\'une fois', (
      tester,
    ) async {
      await pump(
        tester,
        'Verser le @lait{50%cl}.\nRéchauffer le @lait{50%cl}.',
      );
      // Deux jetons dans les étapes, mais une seule puce dans la liste.
      expect(ingredientChip('50 cl lait'), findsOneWidget);
      expect(richTextContaining('Réchauffer'), findsWidgets);
    });

    testWidgets('les ingrédients fournis priment sur ceux du texte', (
      tester,
    ) async {
      await pump(
        tester,
        'Mélanger la @farine{200%g}.',
        overrideIngredients: const [
          RecipeIngredient(name: 'beurre', qty: '30', unit: 'g'),
        ],
      );

      expect(ingredientChip('30 g beurre'), findsOneWidget);
      // La liste ne montre plus la farine ; l'étape la nomme toujours, car
      // l'override remplace le modèle, pas le texte de la recette.
      expect(ingredientChip('200 g farine'), findsNothing);
      expect(find.text('200 g farine'), findsOneWidget);
    });

    testWidgets('les sections == == regroupent les ingrédients', (
      tester,
    ) async {
      await pump(
        tester,
        '== Pâte ==\nMélanger la @farine{200%g}.\n'
        '== Garniture ==\nAjouter la @crème{20%cl}.',
      );

      expect(find.text('Pâte'), findsWidgets);
      expect(find.text('Garniture'), findsWidgets);
      expect(ingredientChip('200 g farine'), findsOneWidget);
      expect(ingredientChip('20 cl crème'), findsOneWidget);
    });
  });

  group('mise à l\'échelle des portions', () {
    testWidgets('doubler les portions double les quantités affichées', (
      tester,
    ) async {
      await pump(
        tester,
        'Mélanger la @farine{200%g}.',
        basePortions: 4,
        selectedPortions: 8,
      );

      expect(ingredientChip('400 g farine'), findsOneWidget);
      expect(ingredientChip('200 g farine'), findsNothing);
    });

    testWidgets('sans portions cibles, les quantités restent intactes', (
      tester,
    ) async {
      await pump(tester, 'Mélanger la @farine{200%g}.', basePortions: 4);
      expect(ingredientChip('200 g farine'), findsOneWidget);
    });
  });

  group('préparation', () {
    testWidgets('les étapes sont numérotées', (tester) async {
      await pump(tester, 'Préchauffer le four.\nEnfourner.');

      expect(find.text('Préparation'), findsOneWidget);
      expect(richTextContaining('Préchauffer le four.'), findsWidgets);
      expect(richTextContaining('Enfourner.'), findsWidgets);
      expect(find.text('1'), findsWidgets);
      expect(find.text('2'), findsWidgets);
    });

    testWidgets('une ligne « + » prolonge l\'étape au lieu d\'en créer une', (
      tester,
    ) async {
      await pump(tester, 'Préchauffer le four.\n+ à 180 degrés.');

      expect(richTextContaining('à 180 degrés.'), findsWidgets);
      // Une seule étape : pas de numéro 2.
      expect(find.text('2'), findsNothing);
    });

    testWidgets('les commentaires -- sont ignorés', (tester) async {
      await pump(tester, '-- note interne\nPréchauffer le four.');
      expect(richTextContaining('note interne'), findsNothing);
    });
  });

  group('catégorisation', () {
    testWidgets('les tags de recette forment une section repliable', (
      tester,
    ) async {
      await pump(
        tester,
        'Mélanger.',
        tags: const RecipeTags(cuisines: ['belge'], dishTypes: ['dessert']),
      );

      expect(find.text('Catégorisation'), findsOneWidget);
      expect(find.text('belge'), findsOneWidget);
      expect(find.text('dessert'), findsOneWidget);
    });

    testWidgets('sans tags, pas de section Catégorisation', (tester) async {
      await pump(tester, 'Mélanger.');
      expect(find.text('Catégorisation'), findsNothing);
    });
  });

  group('sections repliables', () {
    testWidgets('replier Ingrédients masque les puces sans perdre l\'en-tête', (
      tester,
    ) async {
      await pump(tester, 'Mélanger la @farine{200%g}.');
      expect(ingredientChip('200 g farine'), findsOneWidget);

      await tester.tap(find.text('Ingrédients'));
      await tester.pump();

      expect(find.text('Ingrédients'), findsOneWidget);
      expect(ingredientChip('200 g farine'), findsNothing);
    });

    testWidgets('replier Préparation masque les étapes', (tester) async {
      await pump(tester, 'Préchauffer le four.');
      expect(richTextContaining('Préchauffer le four.'), findsWidgets);

      await tester.tap(find.text('Préparation'));
      await tester.pump();

      expect(richTextContaining('Préchauffer le four.'), findsNothing);
    });
  });

  group('contenus encadrants', () {
    testWidgets('topContent et bottomContent sont rendus', (tester) async {
      await pump(
        tester,
        'Mélanger.',
        topContent: const Text('AVANT'),
        bottomContent: const Text('APRÈS'),
      );

      expect(find.text('AVANT'), findsOneWidget);
      expect(find.text('APRÈS'), findsOneWidget);
    });

    testWidgets('le bouton liste de courses n\'apparaît qu\'avec son rappel', (
      tester,
    ) async {
      await pump(tester, 'Mélanger la @farine{200%g}.');
      expect(find.byTooltip('Liste de courses'), findsNothing);

      await pump(
        tester,
        'Mélanger la @farine{200%g}.',
        onCreateShoppingList: () {},
      );
      expect(find.byTooltip('Liste de courses'), findsOneWidget);
    });
  });
}
