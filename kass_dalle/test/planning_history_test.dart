import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_history.dart';

/// La fenêtre de variété : les repas servis avant un cycle.
///
/// Une borne mal posée ne lève rien : un plat de la veille passe pour
/// ancien, ou le premier jour du cycle passe pour de l'historique, et l'IA
/// repropose ou s'interdit sans qu'on sache pourquoi.
PlannedMeal _meal(String? recipeId, DateTime at, {String? titre}) =>
    PlannedMeal(
      id: '${recipeId ?? 'vide'}-${at.millisecondsSinceEpoch}',
      uid: 'u',
      recipeId: recipeId,
      recipeTitre: titre ?? (recipeId ?? ''),
      plannedAt: at,
      durationMinutes: 30,
      createdAt: at,
    );

void main() {
  // Vendredi 18 septembre 2026, premier jour du cycle.
  final cycleStart = DateTime(2026, 9, 18);

  group('fenêtre de variété', () {
    test('deux semaines : du 4 au 17 septembre inclus, le 18 exclu', () {
      final out = recentlyServedBefore(
        [
          _meal('trop_vieux', DateTime(2026, 9, 3, 19)),
          _meal('premier_jour', DateTime(2026, 9, 4, 19)),
          _meal('veille', DateTime(2026, 9, 17, 20, 30)),
          _meal('jour_du_cycle', DateTime(2026, 9, 18, 12)),
        ],
        cycleStart: cycleStart,
        windowWeeks: 2,
      );
      expect(out.map((m) => m.recipeId), ['veille', 'premier_jour']);
    });

    test('zéro semaine : rien, quels que soient les repas', () {
      final out = recentlyServedBefore(
        [_meal('a', DateTime(2026, 9, 17))],
        cycleStart: cycleStart,
        windowWeeks: 0,
      );
      expect(out, isEmpty);
    });

    test('un repas sans recette est un créneau vide, pas un plat servi', () {
      final out = recentlyServedBefore(
        [
          _meal(null, DateTime(2026, 9, 17), titre: 'Repas libre'),
          _meal('', DateTime(2026, 9, 16)),
        ],
        cycleStart: cycleStart,
        windowWeeks: 2,
      );
      expect(out, isEmpty);
    });

    test(
      'une recette servie deux fois compte une fois, à sa date la plus récente',
      () {
        final out = recentlyServedBefore(
          [
            _meal('a', DateTime(2026, 9, 6, 19)),
            _meal('a', DateTime(2026, 9, 13, 19)),
          ],
          cycleStart: cycleStart,
          windowWeeks: 2,
        );
        expect(out, hasLength(1));
        expect(out.single.servedAt, DateTime(2026, 9, 13, 19));
      },
    );

    test('du plus récent au plus ancien', () {
      final out = recentlyServedBefore(
        [
          _meal('a', DateTime(2026, 9, 6)),
          _meal('c', DateTime(2026, 9, 16)),
          _meal('b', DateTime(2026, 9, 10)),
        ],
        cycleStart: cycleStart,
        windowWeeks: 2,
      );
      expect(out.map((m) => m.recipeId), ['c', 'b', 'a']);
    });

    test('quatre semaines au plus, quelle que soit la préférence', () {
      // 18 septembre moins 28 jours : le 21 août est le premier jour lu.
      final out = recentlyServedBefore(
        [
          _meal('hors', DateTime(2026, 8, 20, 23)),
          _meal('dedans', DateTime(2026, 8, 21, 0, 5)),
        ],
        cycleStart: cycleStart,
        windowWeeks: 10,
      );
      expect(out.map((m) => m.recipeId), ['dedans']);
    });

    test('le titre voyage avec la recette', () {
      final out = recentlyServedBefore(
        [_meal('a', DateTime(2026, 9, 17), titre: 'Blanquette de veau')],
        cycleStart: cycleStart,
        windowWeeks: 1,
      );
      expect(out.single.titre, 'Blanquette de veau');
    });

    test('l\'heure du premier jour du cycle ne compte pas', () {
      final out = recentlyServedBefore(
        [_meal('veille', DateTime(2026, 9, 17, 23, 59))],
        cycleStart: DateTime(2026, 9, 18, 19, 30),
        windowWeeks: 1,
      );
      expect(out.map((m) => m.recipeId), ['veille']);
    });
  });

  group('début de fenêtre', () {
    test('deux semaines avant le 18 septembre : le 4', () {
      expect(
        varietyWindowStart(cycleStart: cycleStart, windowWeeks: 2),
        DateTime(2026, 9, 4),
      );
    });

    test('franchit le changement de mois', () {
      expect(
        varietyWindowStart(cycleStart: DateTime(2026, 10, 2), windowWeeks: 3),
        DateTime(2026, 9, 11),
      );
    });

    test('zéro semaine : le premier jour du cycle', () {
      expect(
        varietyWindowStart(cycleStart: cycleStart, windowWeeks: 0),
        cycleStart,
      );
    });
  });

  group('bornes', () {
    test('une valeur négative devient zéro', () {
      expect(clampVarietyWindow(-3), 0);
    });

    test('au-delà de quatre, quatre', () {
      expect(clampVarietyWindow(12), kVarietyWindowMaxWeeks);
    });

    test('le défaut est dans les bornes', () {
      expect(
        clampVarietyWindow(kVarietyWindowDefaultWeeks),
        kVarietyWindowDefaultWeeks,
      );
    });
  });
}
