import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/week_replay.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Reprendre une semaine passée : jour de semaine pour jour de semaine, sans
/// appel d'IA.
///
/// Un mauvais appariement ne lève rien : le mardi reçoit le plat du lundi, et
/// personne ne voit pourquoi la reprise ne ressemble pas à la semaine choisie.
Recipe _recipe(String id) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: 'Recette $id',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
  );
}

PlannedMeal _meal(String? recipeId, DateTime at) => PlannedMeal(
  id: '${recipeId ?? 'vide'}-${at.millisecondsSinceEpoch}',
  uid: 'u',
  recipeId: recipeId,
  recipeTitre: recipeId == null ? 'Repas libre' : 'Recette $recipeId',
  plannedAt: at,
  durationMinutes: 30,
  createdAt: at,
);

/// Sept jours à partir du vendredi 18 septembre 2026.
List<DateTime> _cycle({int days = 7}) =>
    List.generate(days, (i) => DateTime(2026, 9, 18 + i));

void main() {
  group('semaines à reprendre', () {
    test('groupées par semaine de planning, la plus récente en premier', () {
      final weeks = replayableWeeks(
        [
          _meal('a', DateTime(2026, 9, 4, 19)),
          _meal('b', DateTime(2026, 9, 5, 19)),
          _meal('c', DateTime(2026, 9, 11, 19)),
        ],
        cycleStartDay: DateTime.friday,
        cycleDates: _cycle(),
      );
      expect(weeks.map((w) => w.week.start), [
        DateTime(2026, 9, 11),
        DateTime(2026, 9, 4),
      ]);
      expect(weeks.last.titres, ['Recette a', 'Recette b']);
      expect(weeks.last.recipeIds, {'a', 'b'});
    });

    test('les semaines que recouvre le cycle n\'y sont pas', () {
      final weeks = replayableWeeks(
        [
          _meal('a', DateTime(2026, 9, 11, 19)),
          _meal('d', DateTime(2026, 9, 20, 19)),
        ],
        cycleStartDay: DateTime.friday,
        cycleDates: _cycle(),
      );
      expect(weeks.map((w) => w.week.start), [DateTime(2026, 9, 11)]);
    });

    test('un repas sans recette ne fait pas une semaine', () {
      final weeks = replayableWeeks(
        [_meal(null, DateTime(2026, 9, 11, 19))],
        cycleStartDay: DateTime.friday,
        cycleDates: _cycle(),
      );
      expect(weeks, isEmpty);
    });

    test('les repas d\'une semaine sont dans l\'ordre des jours', () {
      final weeks = replayableWeeks(
        [
          _meal('b', DateTime(2026, 9, 9, 19)),
          _meal('a', DateTime(2026, 9, 5, 19)),
        ],
        cycleStartDay: DateTime.friday,
        cycleDates: _cycle(),
      );
      expect(weeks.single.titres, ['Recette a', 'Recette b']);
    });
  });

  group('reprise', () {
    final source = ReplayableWeek(
      // Semaine du vendredi 4 septembre 2026.
      week: replayableWeeks(
        [_meal('x', DateTime(2026, 9, 4))],
        cycleStartDay: DateTime.friday,
        cycleDates: _cycle(),
      ).single.week,
      meals: [
        _meal('a', DateTime(2026, 9, 4, 19)), // vendredi
        _meal('b', DateTime(2026, 9, 5, 19)), // samedi
        _meal('c', DateTime(2026, 9, 7, 12)), // lundi, midi
        _meal('c2', DateTime(2026, 9, 7, 19)), // lundi, soir
        _meal('perdue', DateTime(2026, 9, 8, 19)), // mardi
      ],
    );
    final recipes = {
      for (final id in ['a', 'b', 'c', 'c2', 'x']) id: _recipe(id),
    };

    test('jour de semaine pour jour de semaine, le premier repas du jour', () {
      final replay = replayWeek(
        source: source,
        slotDates: _cycle(),
        slots: {for (var i = 0; i < 7; i++) i: null},
        recipesById: recipes,
      );
      expect(replay.assignments.map((k, v) => MapEntry(k, v.id)), {
        0: 'a', // vendredi 18
        1: 'b', // samedi 19
        3: 'c', // lundi 21
      });
      expect(replay.applied, 3);
      expect(replay.skippedMissing, 1, reason: 'mardi : recette perdue');
      expect(replay.skippedNoMeal, 3, reason: 'dimanche, mercredi, jeudi');
      expect(replay.skippedFilled, 0);
      expect(replay.skippedDuplicate, 0);
    });

    test('un créneau rempli est laissé tel quel, et sa recette compte', () {
      final replay = replayWeek(
        source: source,
        slotDates: _cycle(),
        slots: {
          for (var i = 0; i < 7; i++) i: null,
          1: _recipe('x'),
          2: _recipe('a'), // dimanche : la recette du vendredi, déjà posée
        },
        recipesById: recipes,
      );
      expect(replay.assignments.keys, [3]);
      expect(replay.skippedFilled, 2);
      expect(replay.skippedDuplicate, 1, reason: 'vendredi : a déjà posée');
    });

    test('un cycle de quatorze jours ne repose pas deux fois le même plat', () {
      final replay = replayWeek(
        source: source,
        slotDates: _cycle(days: 14),
        slots: {for (var i = 0; i < 14; i++) i: null},
        recipesById: recipes,
      );
      expect(replay.assignments.keys, [0, 1, 3, 10]);
      expect(
        replay.assignments[10]!.id,
        'c2',
        reason: 'lundi 28 : c déjà posée',
      );
      expect(replay.skippedDuplicate, 2, reason: 'vendredi 25 et samedi 26');
    });

    test('rien à reprendre quand aucune recette n\'est retrouvée', () {
      final replay = replayWeek(
        source: source,
        slotDates: _cycle(),
        slots: {for (var i = 0; i < 7; i++) i: null},
        recipesById: const {},
      );
      expect(replay.applied, 0);
      expect(replay.skippedMissing, 4);
    });
  });
}
