import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/planning/presentation/side_picker_sheet.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le choix d'un accompagnement à la main : recherche par nom et filtre par
/// famille, combinés.
Recipe _recipe(
  String id,
  String titre, {
  String? role,
  List<String> contains = const [],
  List<String> sides = const [],
}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(mealRole: role, contains: contains, suggestedSides: sides),
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
  );
}

SideCandidate _staple(String id, String name, StapleCategory category) =>
    SideCandidate.staple(
      MealStaple(
        id: id,
        name: name,
        category: category,
        quantityPerPortion: 70,
      ),
    );

final _candidates = [
  _staple('riz', 'Riz', StapleCategory.feculent),
  _staple('pates', 'Pâtes', StapleCategory.feculent),
  _staple('semoule', 'Semoule', StapleCategory.feculent),
  _staple('haricots_verts', 'Haricots verts', StapleCategory.legume),
  _staple('salade_verte', 'Salade verte', StapleCategory.salade),
  SideCandidate.recipe(
    _recipe(
      'dauphine',
      'Pommes dauphine',
      role: 'accompagnement',
      contains: const ['feculent'],
    ),
  ),
];

final _main = _recipe(
  'poulet',
  'Poulet chasseur',
  role: 'plat',
  contains: const ['proteine'],
  sides: const ['riz'],
);

Future<void> _pumpOpener(
  WidgetTester tester,
  void Function(SidePickerResult?) onResult,
) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onResult(
              await showModalBottomSheet<SidePickerResult>(
                context: context,
                isScrollControlled: true,
                builder: (_) =>
                    SidePickerSheet(main: _main, candidates: _candidates),
              ),
            ),
            child: const Text('Ouvrir'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Ouvrir'));
  await tester.pumpAndSettle();
}

Future<void> _pump(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(800, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SidePickerSheet(main: _main, candidates: _candidates),
      ),
    ),
  );
}

void main() {
  group('sideCandidateMatches', () {
    test('la recherche ignore la casse et les accents', () {
      final pates = _candidates[1];
      expect(sideCandidateMatches(pates, query: 'pate'), isTrue);
      expect(sideCandidateMatches(pates, query: 'PÂT'), isTrue);
      expect(sideCandidateMatches(pates, query: 'riz'), isFalse);
    });

    test('la recherche trouve un mot au milieu du nom', () {
      expect(sideCandidateMatches(_candidates[3], query: 'vert'), isTrue);
    });

    test("la recherche ignore le pluriel et l'ordre des mots", () {
      final dauphine = _candidates[5];
      expect(sideCandidateMatches(dauphine, query: 'pommes dauphines'), isTrue);
      expect(sideCandidateMatches(dauphine, query: 'dauphine pomme'), isTrue);
      expect(sideCandidateMatches(dauphine, query: 'pommes frites'), isFalse);
    });

    test('un nom identique au pluriel près désigne le candidat', () {
      expect(sideCandidateNamed(_candidates[5], 'pommes dauphines'), isTrue);
      expect(sideCandidateNamed(_candidates[5], 'pommes'), isFalse);
    });

    test('le filtre de famille écarte les autres familles', () {
      const legume = SideFamilyFilter.category(StapleCategory.legume);
      expect(sideCandidateMatches(_candidates[3], family: legume), isTrue);
      expect(sideCandidateMatches(_candidates[0], family: legume), isFalse);
      expect(sideCandidateMatches(_candidates[5], family: legume), isFalse);
    });

    test('le filtre « Recettes » ne garde que les recettes', () {
      const recipes = SideFamilyFilter.recipes();
      expect(sideCandidateMatches(_candidates[5], family: recipes), isTrue);
      expect(sideCandidateMatches(_candidates[0], family: recipes), isFalse);
    });
  });

  test('le texte libre est nettoyé et borné', () {
    expect(sideFreeLabelFrom('  frites   maison '), 'Frites maison');
    expect(sideFreeLabelFrom('   '), '');
    expect(sideFreeLabelFrom('a' * 200).length, kSideFreeLabelMaxChars);
  });

  test('un texte libre devient un composant sans garniture ni recette', () {
    final component = const SidePickerResult.free(
      'Frites maison',
    ).toComponent(justification: 'Choisi à la main.');
    expect(component.isFree, isTrue);
    expect(component.toMap(), {
      'role': 'accompagnement',
      'label': 'Frites maison',
      'justification': 'Choisi à la main.',
    });
    final back = MealComponent.fromMap(component.toMap());
    expect(back.isFree, isTrue);
    expect(back.label, 'Frites maison');
    expect(back.totalQuantityFor(4), isNull);
  });

  test('les filtres proposés suivent les familles présentes', () {
    expect(sideFamilyFiltersFor(_candidates).map((f) => f.label).toList(), [
      'Féculent',
      'Légume',
      'Salade et crudités',
      'Recettes',
    ]);
  });

  testWidgets('taper un nom réduit la liste', (tester) async {
    await _pump(tester);
    expect(find.text('Semoule'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'vert');
    await tester.pump();

    expect(find.text('Haricots verts'), findsOneWidget);
    expect(find.text('Salade verte'), findsOneWidget);
    expect(find.text('Semoule'), findsNothing);
    expect(find.text('Riz'), findsNothing);
  });

  testWidgets('une pastille de famille ne garde que cette famille', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Légume'));
    await tester.pump();

    expect(find.text('Haricots verts'), findsOneWidget);
    expect(find.text('Semoule'), findsNothing);
    expect(find.text('Pommes dauphine'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Tout'));
    await tester.pump();
    expect(find.text('Semoule'), findsOneWidget);
  });

  testWidgets('rien ne correspond : le texte libre est proposé', (
    tester,
  ) async {
    SidePickerResult? result;
    await _pumpOpener(tester, (r) => result = r);
    await tester.enterText(find.byType(TextField), 'frites maison');
    await tester.pump();

    expect(
      find.text("Aucune garniture ni recette d'accompagnement ne correspond."),
      findsOneWidget,
    );
    await tester.tap(find.text('Ajouter « Frites maison »'));
    await tester.pumpAndSettle();

    // L'étape de l'apport : deux pastilles facultatives, puis « Ajouter ».
    expect(find.text('« Frites maison »'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Féculent'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
    await tester.pumpAndSettle();

    expect(result?.freeLabel, 'Frites maison');
    expect(result?.provides, ['feculent']);
    expect(result?.candidate, isNull);
  });

  testWidgets(
    'ouverte par « Compléter » : filtrée, pastille cochée d\'office',
    (tester) async {
      SidePickerResult? result;
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await showModalBottomSheet<SidePickerResult>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => SidePickerSheet(
                        main: _main,
                        candidates: _candidates,
                        initialNeed: SideNeed.legume,
                      ),
                    ),
                child: const Text('Ouvrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ouvrir'));
      await tester.pumpAndSettle();

      expect(find.text('Haricots verts'), findsOneWidget);
      expect(find.text('Salade verte'), findsOneWidget);
      expect(find.text('Semoule'), findsNothing);

      await tester.enterText(find.byType(TextField), 'poêlée');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      final legume = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Légume'),
      );
      expect(legume.selected, isTrue);
      await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
      await tester.pumpAndSettle();
      expect(result?.provides, ['legume']);
    },
  );

  testWidgets('un nom déjà connu ne propose pas de texte libre', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'pommes dauphines');
    await tester.pump();

    expect(find.text('Pommes dauphine'), findsOneWidget);
    expect(find.textContaining('Ajouter «'), findsNothing);
  });

  testWidgets('Entrée choisit le candidat qui porte ce nom', (tester) async {
    SidePickerResult? result;
    await _pumpOpener(tester, (r) => result = r);
    await tester.enterText(find.byType(TextField), 'pommes dauphines');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result?.candidate?.id, 'dauphine');
  });

  testWidgets('Entrée pose le texte libre quand rien ne porte ce nom', (
    tester,
  ) async {
    SidePickerResult? result;
    await _pumpOpener(tester, (r) => result = r);
    await tester.enterText(find.byType(TextField), 'poêlée forestière');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
    await tester.pumpAndSettle();

    expect(result?.freeLabel, 'Poêlée forestière');
    expect(result?.provides, isEmpty);
  });
}
