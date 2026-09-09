import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planning_week.dart';

/// La semaine de planning, unité de lecture de l'onglet Liste.
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

  group('semaines à proposer', () {
    final today = DateTime(2026, 9, 9);

    test('sans repas : la semaine en cours et la suivante', () {
      final weeks = planningWeeksFor(
        mealDays: const [],
        today: today,
        cycleStartDay: DateTime.friday,
      );
      expect(weeks.map((w) => w.start), [
        DateTime(2026, 9, 4),
        DateTime(2026, 9, 11),
      ]);
    });

    test('les repas anciens et lointains étendent la plage, sans trou', () {
      final weeks = planningWeeksFor(
        mealDays: [DateTime(2026, 8, 14, 19), DateTime(2026, 9, 26, 12)],
        today: today,
        cycleStartDay: DateTime.friday,
      );
      expect(weeks.first.start, DateTime(2026, 8, 14));
      expect(weeks.last.start, DateTime(2026, 9, 25));
      expect(weeks.length, 7);
      for (var i = 1; i < weeks.length; i++) {
        expect(weeks[i].start, weeks[i - 1].next.start);
      }
    });

    test('la semaine où l\'on a navigué reste proposée', () {
      final weeks = planningWeeksFor(
        mealDays: const [],
        today: today,
        cycleStartDay: DateTime.friday,
        alsoCover: [DateTime(2026, 10, 30)],
      );
      expect(weeks.last.start, DateTime(2026, 10, 30));
    });
  });
}
