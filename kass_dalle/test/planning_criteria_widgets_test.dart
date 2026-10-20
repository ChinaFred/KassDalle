import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_criteria.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';
import 'package:kass_dalle/features/planning/presentation/constraint_understanding.dart';
import 'package:kass_dalle/features/planning/presentation/side_picker_sheet.dart';
import 'package:kass_dalle/features/planning/presentation/staple_allergens_field.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Critères vérifiés (P3), côté client : ce que l'écran dit d'un texte
/// compris, les écarts d'un créneau, l'accompagnement écarté ou signalé, et
/// les champs stockés sur le repas et la garniture.
Recipe _plat({String id = 'p1', String titre = 'Blanquette de veau'}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(mealRole: 'plat', contains: ['proteine', 'legume']),
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
  );
}

UserStaple _staple(String id, String name, {List<String>? allergens}) =>
    UserStaple(
      staple: MealStaple(
        id: id,
        name: name,
        category: StapleCategory.feculent,
        quantityPerPortion: 70,
        allergens: allergens,
      ),
      isOwn: false,
      isOverridden: false,
      hidden: false,
    );

const _sansGluten = PlanningCriteria(excludedAllergens: ['gluten']);

void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  group('accompagnements choisis par le programme', () {
    final plat = _plat();

    test('un candidat qui viole une exclusion n\'est jamais proposé', () {
      final choices = chooseSides(
        main: plat,
        candidates: sideCandidatesFrom(
          staples: [
            _staple('pates', 'Pâtes', allergens: ['gluten', 'oeuf']),
          ],
          recipes: const [],
        ),
        criteria: _sansGluten,
      );
      expect(choices, isEmpty);
    });

    test('vérifié avant non renseigné, et la justification le dit', () {
      final candidates = sideCandidatesFrom(
        staples: [
          _staple('semoule', 'Semoule'),
          _staple('riz', 'Riz', allergens: const []),
        ],
        recipes: const [],
      );
      final verified = chooseSides(
        main: plat,
        candidates: candidates,
        criteria: _sansGluten,
      );
      expect(verified.single.component.sourceId, 'riz');

      final unknownOnly = chooseSides(
        main: plat,
        candidates: [candidates.first],
        criteria: _sansGluten,
      );
      expect(unknownOnly.single.component.sourceId, 'semoule');
      expect(
        unknownOnly.single.component.justification,
        contains('Allergènes non renseignés.'),
      );
    });

    test('sans critère : rien ne change', () {
      final choices = chooseSides(
        main: plat,
        candidates: sideCandidatesFrom(
          staples: [
            _staple('pates', 'Pâtes', allergens: ['gluten']),
          ],
          recipes: const [],
        ),
      );
      expect(choices.single.component.sourceId, 'pates');
    });
  });

  testWidgets('à la main : choisissable, mais signalé « contient : gluten »', (
    tester,
  ) async {
    SidePickerResult? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showModalBottomSheet<SidePickerResult>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => SidePickerSheet(
                    candidates: sideCandidatesFrom(
                      staples: [
                        _staple('pates', 'Pâtes', allergens: ['gluten']),
                        _staple('semoule', 'Semoule'),
                      ],
                      recipes: const [],
                    ),
                    criteria: _sansGluten,
                  ),
                );
              },
              child: const Text('ouvrir'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ouvrir'));
    await tester.pumpAndSettle();
    expect(find.textContaining('contient : gluten'), findsOneWidget);
    expect(find.textContaining('allergènes non renseignés'), findsOneWidget);
    await tester.tap(find.text('Pâtes'));
    await tester.pumpAndSettle();
    expect(picked?.candidate?.id, 'pates');
  });

  group('ce que Kass\'Dalle a compris d\'un texte', () {
    Future<void> pump(
      WidgetTester tester,
      String text,
      ConstraintTranslation? t,
    ) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConstraintUnderstandingLines(text: text, translation: t),
        ),
      ),
    );

    testWidgets('critères compris et reste non vérifié', (tester) async {
      await pump(
        tester,
        'Pas de porc, 30 min max, pas trop gras',
        const ConstraintTranslation(
          text: 'Pas de porc, 30 min max, pas trop gras',
          criteria: PlanningCriteria(
            excludedProteins: ['porc'],
            maxDuration: 30,
          ),
          untranslated: 'pas trop gras',
        ),
      );
      expect(find.text('Compris : sans porc · 30 min max'), findsOneWidget);
      expect(
        find.text('Transmis à l\'IA, non vérifié : « pas trop gras »'),
        findsOneWidget,
      );
    });

    testWidgets('pas encore lu : dit, sans rien traduire', (tester) async {
      await pump(tester, 'sans noix', null);
      expect(
        find.text('Sera lu au prochain « Planifier avec l\'IA ».'),
        findsOneWidget,
      );
    });

    testWidgets('traduction en échec : tout le texte non vérifié', (
      tester,
    ) async {
      await pump(
        tester,
        'sans noix',
        const ConstraintTranslation.failed('sans noix'),
      );
      expect(find.textContaining('Compris'), findsNothing);
      expect(
        find.text('Transmis à l\'IA, non vérifié : « sans noix »'),
        findsOneWidget,
      );
    });

    testWidgets('champ vide : rien', (tester) async {
      await pump(tester, '  ', null);
      expect(find.byType(Text), findsNothing);
    });
  });

  group('écarts sur la carte d\'un créneau', () {
    const relaxed = UnmetCriterion(
      key: 'max_duration',
      regime: CriterionRegime.preference,
      status: 'relaxed',
      service: 'plat',
      detail: '1 h 10, au-delà des 45 min demandées : peu d\'autres choix',
    );
    const dessertEmpty = UnmetCriterion(
      key: 'excluded_allergens',
      regime: CriterionRegime.exclusion,
      status: 'empty',
      service: 'dessert',
      detail: 'Aucun dessert sans fruits à coque.',
    );
    const platEmpty = UnmetCriterion(
      key: 'excluded_proteins',
      regime: CriterionRegime.exclusion,
      status: 'empty',
      service: 'plat',
      detail: 'Aucun plat sans porc.',
    );

    Future<void> pump(
      WidgetTester tester, {
      Recipe? recipe,
      List<UnmetCriterion> unmet = const [],
      List<String> relaxedKeys = const [],
      DayConstraint constraint = const DayConstraint(),
      VoidCallback? onAssign,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: BatchSlotTile(
                index: 0,
                date: DateTime(2026, 10, 16),
                recipe: recipe,
                slotTime: const TimeOfDay(hour: 19, minute: 0),
                isGenerating: false,
                dayConstraint: constraint,
                isBatchDay: false,
                unmet: unmet,
                relaxed: relaxedKeys,
                onAssign: onAssign ?? () {},
                onRemove: () {},
                onDelete: () {},
                onTimeChanged: (_) {},
                onMaxPrepChanged: (_) {},
                onTargetPortionsChanged: (_) {},
                onReheatChanged: (_) {},
                onNotesChanged: (_) {},
                onFormatChanged: (_) {},
                onChangeDessert: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('préférence relâchée : une ligne, sans doublon', (
      tester,
    ) async {
      await pump(
        tester,
        recipe: _plat(),
        unmet: const [relaxed],
        relaxedKeys: const ['max_duration'],
      );
      expect(find.text(relaxed.detail), findsOneWidget);
      expect(
        find.textContaining('plus long que la durée demandée'),
        findsNothing,
      );
    });

    testWidgets('dessert vidé par une exclusion : la raison et « Choisir »', (
      tester,
    ) async {
      await pump(
        tester,
        recipe: _plat(),
        unmet: const [dessertEmpty],
        constraint: const DayConstraint(mealFormat: MealFormat.platDessert),
      );
      expect(
        find.text('Dessert : à choisir. Aucun dessert sans fruits à coque.'),
        findsOneWidget,
      );
      expect(find.text('Choisir'), findsWidgets);
    });

    testWidgets('créneau vidé par une exclusion : « Plat : à choisir »', (
      tester,
    ) async {
      var assigned = 0;
      await pump(tester, unmet: const [platEmpty], onAssign: () => assigned++);
      expect(
        find.text('Plat : à choisir. Aucun plat sans porc.'),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel('Choisir le plat'));
      expect(assigned, 1);
    });
  });

  group('écarts après un geste à la main', () {
    const platGap = UnmetCriterion(
      key: 'max_duration',
      regime: CriterionRegime.preference,
      status: 'relaxed',
      service: 'plat',
      detail: 'plat',
    );
    const dessertGap = UnmetCriterion(
      key: 'excluded_allergens',
      regime: CriterionRegime.exclusion,
      status: 'empty',
      service: 'dessert',
      detail: 'dessert',
    );
    const starterGap = UnmetCriterion(
      key: 'excluded_allergens',
      regime: CriterionRegime.exclusion,
      status: 'unverified',
      service: 'entree',
      detail: 'entrée',
    );
    MealComponent course(String role, String label) =>
        MealComponent.fromMap({'role': role, 'label': label});

    test(
      '« Autre suggestion » : écarts du plat proposé, les autres gardés',
      () {
        const newPlat = UnmetCriterion(
          key: 'light',
          regime: CriterionRegime.preference,
          status: 'relaxed',
          service: 'plat',
          detail: 'nouveau',
        );
        expect(
          unmetWithNewDish(
            current: const [platGap, dessertGap],
            proposed: const [newPlat, starterGap],
          ),
          const [newPlat, dessertGap],
        );
      },
    );

    test(
      'un dessert rempli perd son écart, l\'entrée inchangée garde le sien',
      () {
        final before = [course('entree', 'Velouté'), course('dessert', '')];
        final after = [course('entree', 'Velouté'), course('dessert', 'Pomme')];
        expect(
          unmetAfterManualCourses(
            unmet: const [platGap, dessertGap, starterGap],
            before: before,
            after: after,
          ),
          const [platGap, starterGap],
        );
      },
    );

    test('un service resté « à choisir » garde son écart', () {
      final same = [course('dessert', '')];
      expect(
        unmetAfterManualCourses(
          unmet: const [dessertGap],
          before: same,
          after: same,
        ),
        const [dessertGap],
      );
    });

    test('un dessert retiré ou vidé perd son écart', () {
      final before = [course('dessert', 'Tarte aux noix')];
      expect(
        unmetAfterManualCourses(
          unmet: const [platGap, dessertGap],
          before: before,
          after: const [],
        ),
        const [platGap],
      );
      expect(
        unmetAfterManualCourses(
          unmet: const [platGap, dessertGap],
          before: before,
          after: [course('dessert', '')],
        ),
        const [platGap],
      );
    });

    test('un dessert resté « à choisir » puis retiré perd son écart', () {
      expect(
        unmetAfterManualCourses(
          unmet: const [platGap, dessertGap],
          before: [course('dessert', '')],
          after: const [],
        ),
        const [platGap],
      );
    });
  });

  test('une recette aux allergènes inconnus : « non vérifiés »', () {
    final item = CriteriaItem.ofRecipe(_plat());
    expect(exclusionWarning(_sansGluten, item), 'allergènes non vérifiés');
  });

  group('écarts stockés sur le repas', () {
    test('le repas garde ses écarts, une version ancienne les ignore', () {
      final now = DateTime(2026, 10, 16, 19);
      final meal = PlannedMeal(
        id: 'm',
        uid: 'u',
        recipeTitre: 'Poulet rôti',
        plannedAt: now,
        durationMinutes: 70,
        choiceSource: MealChoiceSource.ai,
        unmetCriteria: const [
          UnmetCriterion(
            key: 'max_duration',
            regime: CriterionRegime.preference,
            status: 'relaxed',
            service: 'plat',
            detail:
                '1 h 10, au-delà des 45 min demandées : peu d\'autres choix',
          ),
        ],
        createdAt: now,
      );
      final data = meal.toFirestore();
      expect((data['unmet_criteria'] as List).single, {
        'key': 'max_duration',
        'regime': 'preference',
        'status': 'relaxed',
        'service': 'plat',
        'detail': '1 h 10, au-delà des 45 min demandées : peu d\'autres choix',
      });
      final back = PlannedMeal.fromFirestore('m', {
        ...data,
        'planned_at': Timestamp.fromDate(now),
        'created_at': Timestamp.fromDate(now),
      });
      expect(back.unmetCriteria, meal.unmetCriteria);
      expect(back.extra.containsKey('unmet_criteria'), isFalse);
      final none = PlannedMeal.fromFirestore('m', {
        ...data,
        'unmet_criteria': 'abîmé',
      });
      expect(none.unmetCriteria, isEmpty);
    });

    testWidgets('la ligne d\'origine dit l\'écart', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MealOriginLine(
              source: MealChoiceSource.ai,
              unmet: [
                UnmetCriterion(
                  key: 'excluded_allergens',
                  regime: CriterionRegime.exclusion,
                  status: 'empty',
                  service: 'dessert',
                  detail: 'Aucun dessert sans fruits à coque.',
                ),
              ],
            ),
          ),
        ),
      );
      expect(
        find.textContaining('dessert : aucun dessert sans fruits à coque'),
        findsOneWidget,
      );
    });
  });

  group('allergènes d\'une garniture', () {
    test('absents : non renseignés ; vide : aucun ; inconnus écartés', () {
      expect(
        MealStaple.fromFirestore('riz', const {'name': 'Riz'}).allergens,
        isNull,
      );
      expect(
        MealStaple.fromFirestore('riz', const {
          'name': 'Riz',
          'allergens': [],
        }).allergens,
        isEmpty,
      );
      expect(
        MealStaple.fromFirestore('pates', const {
          'name': 'Pâtes',
          'allergens': ['oeuf', 'lactose', 'gluten'],
        }).allergens,
        ['gluten', 'oeuf'],
      );
      const s = MealStaple(
        id: 'riz',
        name: 'Riz',
        category: StapleCategory.feculent,
        quantityPerPortion: 70,
      );
      expect(s.toFirestore().containsKey('allergens'), isFalse);
    });

    test('la retouche d\'un utilisateur remplace ceux du référentiel', () {
      const base = MealStaple(
        id: 'pates',
        name: 'Pâtes',
        category: StapleCategory.feculent,
        quantityPerPortion: 80,
        allergens: ['gluten'],
      );
      final merged = mergeStaples(
        [base],
        {
          'pates': const StapleOverride(
            id: 'pates',
            allergens: ['gluten', 'oeuf'],
          ),
          'mien': const StapleOverride(
            id: 'mien',
            isOwn: true,
            name: 'Mon pain',
            quantityPerPortion: 1,
            allergens: ['gluten'],
          ),
        },
      );
      expect(merged.first.staple.allergens, ['gluten', 'oeuf']);
      expect(merged.first.isOverridden, isTrue);
      expect(merged.last.staple.allergens, ['gluten']);
      expect(
        StapleOverride.fromMap('x', const {
          'allergens': ['lait'],
        }).toMap(),
        {
          'allergens': ['lait'],
        },
      );
    });

    testWidgets(
      'pastilles : « Aucun », puis un allergène, puis non renseigné',
      (tester) async {
        List<String>? value;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => SingleChildScrollView(
                  child: StapleAllergensField(
                    value: value,
                    onChanged: (v) => setState(() => value = v),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.textContaining('Non renseignés'), findsOneWidget);
        await tester.tap(find.text('Aucun'));
        await tester.pump();
        expect(value, isEmpty);
        await tester.tap(find.text('Gluten'));
        await tester.pump();
        expect(value, ['gluten']);
        await tester.tap(find.text('Gluten'));
        await tester.pump();
        expect(value, isNull);
        expect(stapleAllergensSummary(null), 'allergènes non renseignés');
      },
    );

    testWidgets('retouche sans valeur propre : « Suit le référentiel »', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StapleAllergensField(
                value: null,
                onChanged: (_) {},
                retouch: true,
                baseAllergens: const ['gluten'],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Suit le référentiel : Gluten.'), findsOneWidget);
      expect(find.textContaining('Non renseignés'), findsNothing);
      expect(stapleAllergensSummary(const ['gluten', 'oeuf']), 'Gluten, Œuf');
    });

    testWidgets('retouche, référentiel sans allergènes saisis : '
        'l\'avertissement reste', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StapleAllergensField(
                value: null,
                onChanged: (_) {},
                retouch: true,
              ),
            ),
          ),
        ),
      );
      expect(
        find.text(
          'Non renseignés : une exclusion d\'allergène ne peut pas être '
          'vérifiée sur cette garniture.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Suit le référentiel'), findsNothing);
    });
  });
}
