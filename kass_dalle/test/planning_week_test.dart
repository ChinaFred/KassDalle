import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_week.dart';

/// La semaine de planning, unité de lecture de l'écran Planning.
///
/// Une semaine mal bornée ne lève rien : un repas du jeudi se retrouve dans
/// la semaine suivante, et la liste dit qu'il n'y a rien à cuisiner ce soir.
void main() {
  group('semaine contenant un jour', () {
    test(
      'un cycle du vendredi : le mercredi appartient au vendredi précédent',
      () {
        // Mercredi 9 septembre 2026.
        final week = planningWeekOf(
          DateTime(2026, 9, 9),
          cycleStartDay: DateTime.friday,
        );
        expect(week.start, DateTime(2026, 9, 4));
        expect(week.end, DateTime(2026, 9, 10));
      },
    );

    test('le jour de démarrage ouvre sa propre semaine', () {
      final week = planningWeekOf(
        DateTime(2026, 9, 11, 19, 30),
        cycleStartDay: DateTime.friday,
      );
      expect(week.start, DateTime(2026, 9, 11));
    });

    test('un cycle du lundi suit la semaine civile', () {
      final week = planningWeekOf(
        DateTime(2026, 9, 13),
        cycleStartDay: DateTime.monday,
      );
      expect(week.start, DateTime(2026, 9, 7));
      expect(week.end, DateTime(2026, 9, 13));
    });

    test('l\'heure du repas ne compte pas', () {
      final week = planningWeekOf(
        DateTime(2026, 9, 10, 23, 59),
        cycleStartDay: DateTime.friday,
      );
      expect(week.contains(DateTime(2026, 9, 10, 0, 1)), isTrue);
      expect(week.contains(DateTime(2026, 9, 11)), isFalse);
    });
  });

  group('jours de la semaine', () {
    test('sept jours consécutifs, changement d\'heure compris', () {
      // Le passage à l'heure d'hiver 2026 tombe le dimanche 25 octobre.
      final week = PlanningWeek(DateTime(2026, 10, 23));
      final days = week.days;
      expect(days.length, 7);
      for (var i = 0; i < 7; i++) {
        expect(days[i], DateTime(2026, 10, 23 + i), reason: 'jour $i');
        expect(days[i].hour, 0, reason: 'jour $i à minuit');
      }
    });

    test('suivante et précédente se touchent sans trou', () {
      final week = PlanningWeek(DateTime(2026, 9, 11));
      expect(week.next.start, DateTime(2026, 9, 18));
      expect(week.previous.end, DateTime(2026, 9, 10));
      expect(week.next.previous, week);
    });
  });

  group('repas à mettre en courses', () {
    // Mercredi 9 septembre 2026, un cycle du vendredi : la semaine lue va du
    // vendredi 4 au jeudi 10, la suivante du 11 au 17.
    final today = DateTime(2026, 9, 9, 15);
    final thisWeek = planningWeekOf(today, cycleStartDay: DateTime.friday);

    PlannedMeal mealAt(String id, DateTime at) => PlannedMeal(
      id: id,
      uid: 'u',
      recipeTitre: 'Titre $id',
      plannedAt: at,
      durationMinutes: 30,
      createdAt: DateTime(2026, 9, 1),
    );

    final meals = [
      mealAt('passe', DateTime(2026, 9, 8, 19)),
      mealAt('ce-soir', DateTime(2026, 9, 9, 12)),
      mealAt('jeudi', DateTime(2026, 9, 10, 19)),
      mealAt('vendredi', DateTime(2026, 9, 11, 19)),
      mealAt('lointain', DateTime(2026, 9, 28, 19)),
    ];

    List<String> ids(List<PlannedMeal> selected) =>
        selected.map((m) => m.id).toList();

    test(
      'sans semaine : tout ce qui reste à cuisiner, sur toutes les semaines',
      () {
        expect(ids(mealsToShop(meals, today: today)), [
          'ce-soir',
          'jeudi',
          'vendredi',
          'lointain',
        ]);
      },
    );

    test('avec une semaine : seulement ses repas encore à cuisiner', () {
      expect(ids(mealsToShop(meals, today: today, week: thisWeek)), [
        'ce-soir',
        'jeudi',
      ]);
    });

    test('la semaine suivante ne reprend rien de la semaine en cours', () {
      expect(ids(mealsToShop(meals, today: today, week: thisWeek.next)), [
        'vendredi',
      ]);
    });

    test('une semaine passée ne donne aucun repas', () {
      expect(
        mealsToShop(meals, today: today, week: thisWeek.previous),
        isEmpty,
      );
    });

    test('le repas du jour compte, même si son heure est passée', () {
      final lateToday = DateTime(2026, 9, 9, 23, 30);
      expect(ids(mealsToShop(meals, today: lateToday, week: thisWeek)), [
        'ce-soir',
        'jeudi',
      ]);
    });
  });

  group('semaines qui couvrent un mois', () {
    test('cycle du vendredi : octobre 2026 tient en six lignes', () {
      final weeks = planningWeeksCovering(
        DateTime(2026, 10),
        cycleStartDay: DateTime.friday,
      );
      // Le 1er octobre 2026 est un jeudi : la première ligne part du
      // vendredi 25 septembre.
      expect(weeks.first.start, DateTime(2026, 9, 25));
      expect(weeks.last.start, DateTime(2026, 10, 30));
      expect(weeks.length, 6);
      for (var i = 1; i < weeks.length; i++) {
        expect(weeks[i].start, weeks[i - 1].next.start);
      }
    });

    test('chaque ligne commence au jour du cycle', () {
      for (var start = 1; start <= 7; start++) {
        final weeks = planningWeeksCovering(
          DateTime(2026, 2),
          cycleStartDay: start,
        );
        expect(weeks.every((w) => w.start.weekday == start), isTrue);
        expect(weeks.first.contains(DateTime(2026, 2, 1)), isTrue);
        expect(weeks.last.contains(DateTime(2026, 2, 28)), isTrue);
      }
    });

    test('un mois qui commence le jour du cycle ne déborde pas avant', () {
      // Le 1er mai 2026 est un vendredi.
      final weeks = planningWeeksCovering(
        DateTime(2026, 5),
        cycleStartDay: DateTime.friday,
      );
      expect(weeks.first.start, DateTime(2026, 5, 1));
    });
  });

  group('période libre', () {
    test('longueur, jours et décalage', () {
      final p = PlanningPeriod(DateTime(2026, 9, 28), DateTime(2026, 10, 5));
      expect(p.length, 8);
      expect(p.days.first, DateTime(2026, 9, 28));
      expect(p.days.last, DateTime(2026, 10, 5));
      expect(
        p.next,
        PlanningPeriod(DateTime(2026, 10, 6), DateTime(2026, 10, 13)),
      );
      expect(p.previous.end, DateTime(2026, 9, 27));
    });

    test('un changement d\'heure ne retire pas de jour', () {
      // Passage à l'heure d'hiver le dimanche 25 octobre 2026.
      final p = PlanningPeriod(DateTime(2026, 10, 23), DateTime(2026, 10, 29));
      expect(p.length, 7);
      expect(p.days.length, 7);
    });

    test('une semaine vaut la période de mêmes bornes', () {
      final week = PlanningWeek(DateTime(2026, 10, 9));
      expect(
        week,
        PlanningPeriod(DateTime(2026, 10, 9), DateTime(2026, 10, 15)),
      );
      expect(week.length, 7);
    });

    test('between remet les bornes dans l\'ordre', () {
      expect(
        PlanningPeriod.between(DateTime(2026, 10, 14), DateTime(2026, 10, 9)),
        PlanningPeriod(DateTime(2026, 10, 9), DateTime(2026, 10, 14)),
      );
    });

    test('lignes du calendrier qui portent une période', () {
      final rows = calendarRowsFor(
        PlanningPeriod(DateTime(2026, 10, 9), DateTime(2026, 10, 15)),
      );
      expect(rows.map((r) => r.start), [
        DateTime(2026, 10, 5),
        DateTime(2026, 10, 12),
      ]);
      expect(
        calendarRowsFor(
          PlanningPeriod(DateTime(2026, 10, 12), DateTime(2026, 10, 18)),
        ).length,
        1,
      );
    });
  });
}
