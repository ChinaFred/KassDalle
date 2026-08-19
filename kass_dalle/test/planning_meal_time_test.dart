import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';

/// L'heure d'un repas : celle du jour s'il en a une, celle de tout le monde
/// sinon.
///
/// La règle vit dans le modèle et nulle part ailleurs — deux écrans qui la
/// recalculent chacun finissent par ne plus dire la même heure.
void main() {
  const prefs = PlanningPreferences(defaultMealHour: 19, defaultMealMinute: 30);

  group('mealTimeFor', () {
    test('un jour sans heure propre suit l\'heure par défaut', () {
      final t = prefs.mealTimeFor(DateTime.monday);
      expect(t.hour, 19);
      expect(t.minute, 30);
    });

    test('un jour qui a son heure la garde', () {
      final custom = prefs.copyWith(
        dailyConstraints: {
          DateTime.wednesday: const DayConstraint(mealHour: 12, mealMinute: 15),
        },
      );
      final mercredi = custom.mealTimeFor(DateTime.wednesday);
      expect(mercredi.hour, 12);
      expect(mercredi.minute, 15);

      // Les autres ne bougent pas pour autant.
      expect(custom.mealTimeFor(DateTime.thursday).hour, 19);
    });

    test(
      'une heure sans minutes vaut l\'heure pile, pas la minute globale',
      () {
        // `mealMinute` absent ne doit pas emprunter les 30 minutes du défaut :
        // ce serait une heure que personne n'a choisie.
        final custom = prefs.copyWith(
          dailyConstraints: {
            DateTime.friday: const DayConstraint(mealHour: 20),
          },
        );
        final vendredi = custom.mealTimeFor(DateTime.friday);
        expect(vendredi.hour, 20);
        expect(vendredi.minute, 0);
      },
    );
  });

  group('withDefaultMealTime', () {
    test('change le défaut et ramène tous les jours à cette heure', () {
      final custom = prefs.copyWith(
        dailyConstraints: {
          DateTime.wednesday: const DayConstraint(mealHour: 12, mealMinute: 15),
          DateTime.friday: const DayConstraint(mealHour: 20, notes: 'street'),
        },
      );

      final reset = custom.withDefaultMealTime(18, 0);

      expect(reset.defaultMealHour, 18);
      expect(reset.defaultMealMinute, 0);
      for (final day in [DateTime.wednesday, DateTime.friday]) {
        expect(reset.mealTimeFor(day).hour, 18);
        expect(reset.dailyConstraints[day]!.hasOwnTime, isFalse);
      }
    });

    test('le reste de la contrainte du jour survit à la remise à l\'heure', () {
      // Remettre les heures d'aplomb ne doit pas effacer une note écrite à la
      // main ni un jour de réchauffage.
      final custom = prefs.copyWith(
        dailyConstraints: {
          DateTime.friday: const DayConstraint(
            mealHour: 20,
            notes: 'street food',
            maxPrepMinutes: 45,
            isBatchCooking: true,
          ),
        },
      );

      final vendredi = custom
          .withDefaultMealTime(18, 0)
          .dailyConstraints[DateTime.friday]!;
      expect(vendredi.notes, 'street food');
      expect(vendredi.maxPrepMinutes, 45);
      expect(vendredi.isBatchCooking, isTrue);
    });
  });

  group('persistance', () {
    test('une heure de jour fait l\'aller-retour Firestore', () {
      final custom = prefs.copyWith(
        dailyConstraints: {
          DateTime.saturday: const DayConstraint(mealHour: 13, mealMinute: 45),
        },
      );

      final relu = PlanningPreferences.fromFirestore(custom.toFirestore());
      expect(relu.mealTimeFor(DateTime.saturday).hour, 13);
      expect(relu.mealTimeFor(DateTime.saturday).minute, 45);
    });

    test('un jour sans heure n\'en invente pas au retour', () {
      const day = DayConstraint(notes: 'léger');
      final relu = DayConstraint.fromMap(day.toMap());
      expect(relu.hasOwnTime, isFalse);
      expect(relu.mealHour, isNull);
    });

    test('un jour qui n\'a QUE son heure n\'est pas considéré comme vide', () {
      // `isEmpty` décide si le jour est enregistré : l'oublier ferait
      // disparaître l'heure choisie à la sauvegarde suivante.
      const day = DayConstraint(mealHour: 12);
      expect(day.isEmpty, isFalse);
    });

    test('clearMealTime rend le jour à l\'heure par défaut', () {
      const day = DayConstraint(mealHour: 12, mealMinute: 30, notes: 'midi');
      final rendu = day.copyWith(clearMealTime: true);
      expect(rendu.hasOwnTime, isFalse);
      expect(rendu.notes, 'midi');
    });
  });
}
