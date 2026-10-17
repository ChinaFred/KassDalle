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
}
