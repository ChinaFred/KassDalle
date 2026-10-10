import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/ranked_candidates.dart';
import 'package:kass_dalle/features/planning/domain/registered_meals.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';

/// « Autre suggestion » sans IA : le client pioche dans la liste classée par
/// le serveur. Il filtre ; il ne note rien.
void main() {
  const ranking = [
    RankedCandidate(recipeId: 'a', why: 'volaille · 20 min'),
    RankedCandidate(recipeId: 'b', why: 'poisson'),
    RankedCandidate(recipeId: 'c', why: 'servie il y a 3 jours', repeat: true),
    RankedCandidate(recipeId: 'd'),
  ];
  const all = {'a', 'b', 'c', 'd'};

  group('nextRankedCandidate', () {
    test('rend le premier candidat de la liste', () {
      expect(
        nextRankedCandidate(
          ranking,
          dismissed: {},
          usedElsewhere: {},
          availableIds: all,
        )?.recipeId,
        'a',
      );
    });

    test('saute une recette écartée du créneau', () {
      expect(
        nextRankedCandidate(
          ranking,
          dismissed: {'a'},
          usedElsewhere: {},
          availableIds: all,
        )?.recipeId,
        'b',
      );
    });

    test('saute une recette posée sur un autre créneau', () {
      expect(
        nextRankedCandidate(
          ranking,
          dismissed: {'a'},
          usedElsewhere: {'b'},
          availableIds: all,
        )?.recipeId,
        'c',
      );
    });

    test('une répétition annoncée par le serveur reste admise ailleurs', () {
      expect(
        nextRankedCandidate(
          ranking,
          dismissed: {'a', 'b'},
          usedElsewhere: {'c'},
          availableIds: all,
        )?.recipeId,
        'c',
      );
    });

    test('saute une recette sortie du corpus', () {
      expect(
        nextRankedCandidate(
          ranking,
          dismissed: {'a'},
          usedElsewhere: {},
          availableIds: {'c', 'd'},
        )?.recipeId,
        'c',
      );
    });

    test('liste épuisée : null', () {
      expect(
        nextRankedCandidate(
          ranking,
          dismissed: all,
          usedElsewhere: {},
          availableIds: all,
        ),
        isNull,
      );
    });
  });

  group('SlotRanking.fromMap', () {
    test('lit les listes, ignore un élément sans identifiant', () {
      final r = SlotRanking.fromMap({
        'slot': 0,
        'plats': [
          {'recipeId': 'a', 'why': 'volaille', 'resizeReason': 'Écrite pour 4'},
          {'why': 'sans id'},
          'texte',
        ],
        'desserts': [
          {'recipeId': 'd', 'repeat': true},
        ],
        'prepDate': '2026-10-11',
      });
      expect(r.plats.map((c) => c.recipeId), ['a']);
      expect(r.plats.single.resizeReason, 'Écrite pour 4');
      expect(r.entrees, isEmpty);
      expect(r.desserts.single.repeat, isTrue);
      expect(r.prepDate, DateTime(2026, 10, 11));
    });
  });

  group('MealPlanResponse.fromMap', () {
    test('lit la réponse de la présélection serveur', () {
      final r = MealPlanResponse.fromMap({
        'runId': 'pr_abc',
        'modelStatus': 'failed',
        'notice': 'L\'IA n\'a pas répondu.',
        'conceptsRemaining': 2,
        'suggestions': [
          {
            'slot': 0,
            'recipeId': 'a',
            'justification': 'volaille',
            'source': 'code',
            'repeat': true,
            'resized': true,
            'resizeReason': 'Écrite pour 4 parts, servie pour 6.',
          },
        ],
        'rankedCandidates': [
          {'slot': 0, 'plats': []},
        ],
        'excludedRecentIds': ['x', 3],
      });
      expect(r.runId, 'pr_abc');
      expect(r.modelStatus, 'failed');
      expect(r.notice, isNotNull);
      expect(r.conceptsRemaining, 2);
      expect(r.suggestions.single.source, 'code');
      expect(r.suggestions.single.repeat, isTrue);
      expect(r.suggestions.single.resized, isTrue);
      expect(r.rankedCandidates, hasLength(1));
      expect(r.excludedRecentIds, ['x']);
    });

    test('une réponse sans les nouveaux champs reste lisible', () {
      final r = MealPlanResponse.fromMap({
        'suggestions': [
          {'slot': 1, 'recipeId': 'b', 'resized': false},
          {'slot': 'x', 'recipeId': 'c'},
        ],
        'excludedRecentIds': [],
      });
      expect(r.suggestions.single.slot, 1);
      expect(r.suggestions.single.source, 'model');
      expect(r.runId, isNull);
      expect(r.conceptsRemaining, 0);
      expect(r.rankedCandidates, isEmpty);
    });
  });

  group('MealChoiceSource', () {
    test('libellés de la ligne d\'origine', () {
      expect(MealChoiceSource.ai.label, 'Choisie par l\'IA');
      expect(MealChoiceSource.rules.label, 'Choisie par Kass\'Dalle');
      expect(MealChoiceSource.concept.label, 'Conçue par l\'IA');
      expect(MealChoiceSource.manual.label, 'Choisie par vous');
    });

    test('source du serveur : model → IA, code → Kass\'Dalle', () {
      expect(MealChoiceSource.fromServer('model'), MealChoiceSource.ai);
      expect(MealChoiceSource.fromServer('code'), MealChoiceSource.rules);
    });

    test('valeur inconnue ou absente : pas d\'origine', () {
      expect(MealChoiceSource.fromValue(null), isNull);
      expect(MealChoiceSource.fromValue('robot'), isNull);
      expect(MealChoiceSource.fromValue('rules'), MealChoiceSource.rules);
    });

    test('aller-retour Firestore du repas planifié', () {
      final meal = PlannedMeal(
        id: 'm',
        uid: 'u',
        recipeId: 'r',
        recipeTitre: 'Soupe',
        plannedAt: DateTime(2026, 10, 12, 19),
        durationMinutes: 30,
        choiceSource: MealChoiceSource.rules,
        createdAt: DateTime(2026, 10, 10),
      );
      final map = meal.toFirestore();
      expect(map['choice_source'], 'rules');
      final back = PlannedMeal.fromFirestore('m', {
        ...map,
        'planned_at': Timestamp.fromDate(meal.plannedAt),
        'created_at': Timestamp.fromDate(meal.createdAt),
      });
      expect(back.choiceSource, MealChoiceSource.rules);
    });

    test('un changement d\'origine change l\'empreinte du repas', () {
      PlannedMeal of(MealChoiceSource? s) => PlannedMeal(
        id: 'm',
        uid: 'u',
        recipeId: 'r',
        recipeTitre: 'Soupe',
        plannedAt: DateTime(2026, 10, 12, 19),
        durationMinutes: 30,
        choiceSource: s,
        createdAt: DateTime(2026, 10, 10),
      );
      expect(
        plannedMealContentKey(of(MealChoiceSource.ai)),
        isNot(plannedMealContentKey(of(MealChoiceSource.manual))),
      );
    });
  });

  group('MealOriginLine', () {
    test('le robot ne précède que ce qu\'une IA a produit', () {
      expect(
        MealOriginLine.iconFor(MealChoiceSource.ai),
        Icons.smart_toy_outlined,
      );
      expect(
        MealOriginLine.iconFor(MealChoiceSource.concept),
        Icons.smart_toy_outlined,
      );
      expect(
        MealOriginLine.iconFor(MealChoiceSource.manual),
        Icons.person_outline,
      );
      expect(
        MealOriginLine.iconFor(MealChoiceSource.rules),
        isNot(Icons.smart_toy_outlined),
      );
    });

    test('rien à dire : pas de ligne', () {
      expect(MealOriginLine.maybe(source: null, facts: '  '), isNull);
      expect(MealOriginLine.maybe(source: MealChoiceSource.manual), isNotNull);
    });

    testWidgets('origine puis faits', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MealOriginLine(
              source: MealChoiceSource.rules,
              facts: 'volaille · 35 min',
            ),
          ),
        ),
      );
      expect(
        find.text('Choisie par Kass\'Dalle · volaille · 35 min'),
        findsOneWidget,
      );
    });
  });
}
