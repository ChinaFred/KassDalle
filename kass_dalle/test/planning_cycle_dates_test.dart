import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';

void main() {
  group('cycleDatesFrom', () {
    test('cycle à cheval sur le changement d\'heure : jours consécutifs', () {
      // Vendredi 23 octobre 2026 ; l'heure d'hiver arrive le dimanche 25.
      final dates = cycleDatesFrom(DateTime(2026, 10, 23, 14, 30), 5, 7);

      expect(dates.map((d) => d.day), [23, 24, 25, 26, 27, 28, 29]);
      expect(dates.map((d) => d.weekday), [5, 6, 7, 1, 2, 3, 4]);
      expect(dates.every((d) => d.hour == 0 && d.minute == 0), isTrue);
    });

    test('cycle à cheval sur le changement d\'heure du printemps', () {
      // Jeudi 25 mars 2027 ; l'heure d'été arrive le dimanche 28.
      final dates = cycleDatesFrom(DateTime(2027, 3, 25), 4, 7);

      expect(dates.map((d) => d.day), [25, 26, 27, 28, 29, 30, 31]);
    });

    test('le jour de départ est aujourd\'hui quand il correspond', () {
      final dates = cycleDatesFrom(DateTime(2026, 10, 23), 5, 2);

      expect(dates.first, DateTime(2026, 10, 23));
    });

    test('le départ passe au prochain jour de cycle et change de mois', () {
      // Mardi 27 octobre 2026, cycle du vendredi : départ le 30.
      final dates = cycleDatesFrom(DateTime(2026, 10, 27), 5, 4);

      expect(dates, [
        DateTime(2026, 10, 30),
        DateTime(2026, 10, 31),
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 2),
      ]);
    });
  });

  // « Nouveau planning » depuis le planning (v0.24.79) : le cycle commence au
  // premier jour de la période affichée, s'il est aujourd'hui ou plus tard.
  group('cycleDatesForStart', () {
    // Mardi 27 octobre 2026, cycle du vendredi.
    final now = DateTime(2026, 10, 27, 14, 30);

    test('un jour à venir : le cycle commence ce jour-là, même longueur', () {
      final dates = cycleDatesForStart(
        now: now,
        startDay: DateTime(2026, 11, 20),
        cycleStartDay: DateTime.friday,
        count: 7,
      );

      expect(dates.first, DateTime(2026, 11, 20));
      expect(dates.map((d) => d.day), [20, 21, 22, 23, 24, 25, 26]);
    });

    test('un jour de semaine autre que celui du cycle est gardé', () {
      // Lundi 9 novembre, cycle du vendredi : départ le lundi.
      final dates = cycleDatesForStart(
        now: now,
        startDay: DateTime(2026, 11, 9, 18),
        cycleStartDay: DateTime.friday,
        count: 3,
      );

      expect(dates, [
        DateTime(2026, 11, 9),
        DateTime(2026, 11, 10),
        DateTime(2026, 11, 11),
      ]);
    });

    test('aujourd\'hui : le cycle commence aujourd\'hui', () {
      final dates = cycleDatesForStart(
        now: now,
        startDay: DateTime(2026, 10, 27),
        cycleStartDay: DateTime.friday,
        count: 2,
      );

      expect(dates, [DateTime(2026, 10, 27), DateTime(2026, 10, 28)]);
    });

    test('un jour passé : le prochain cycle, comme sans jour', () {
      final past = cycleDatesForStart(
        now: now,
        startDay: DateTime(2026, 10, 23),
        cycleStartDay: DateTime.friday,
        count: 4,
      );
      final none = cycleDatesForStart(
        now: now,
        startDay: null,
        cycleStartDay: DateTime.friday,
        count: 4,
      );

      expect(past, cycleDatesFrom(now, DateTime.friday, 4));
      expect(none, past);
      expect(past.first, DateTime(2026, 10, 30));
    });

    test('un cycle demandé qui franchit le changement d\'heure', () {
      // Samedi 24 octobre 2026 ; l'heure d'hiver arrive le dimanche 25.
      final dates = cycleDatesForStart(
        now: DateTime(2026, 10, 20),
        startDay: DateTime(2026, 10, 24),
        cycleStartDay: DateTime.friday,
        count: 3,
      );

      expect(dates.map((d) => d.day), [24, 25, 26]);
      expect(dates.every((d) => d.hour == 0), isTrue);
    });
  });
}
