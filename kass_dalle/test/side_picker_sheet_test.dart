import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      'frites',
      'Frites maison',
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
    expect(find.text('Aucun accompagnement'), findsOneWidget);
  });

  testWidgets('une pastille de famille ne garde que cette famille', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Légume'));
    await tester.pump();

    expect(find.text('Haricots verts'), findsOneWidget);
    expect(find.text('Semoule'), findsNothing);
    expect(find.text('Frites maison'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Tout'));
    await tester.pump();
    expect(find.text('Semoule'), findsOneWidget);
  });

  testWidgets('rien ne correspond : un message le dit', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'quinoa');
    await tester.pump();

    expect(find.text('Aucun accompagnement ne correspond.'), findsOneWidget);
  });
}
