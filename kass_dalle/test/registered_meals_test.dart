import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/registered_meals.dart';

/// Reprendre dans un cycle les repas déjà au planning.
///
/// Un jour déjà planifié qui s'affiche vide reçoit une suggestion de l'IA, puis
/// « Valider » propose de le remplacer ou de le doubler : le cycle demande sept
/// repas quand il n'en manque que quatre.
PlannedMeal _meal(
  String id,
  DateTime at, {
  String? recipeId = 'r',
  List<MealComponent> components = const [],
}) => PlannedMeal(
  id: id,
  uid: 'u',
  recipeId: recipeId,
  recipeTitre: 'Titre $id',
  plannedAt: at,
  durationMinutes: 30,
  components: components,
  createdAt: at,
);

/// Sept jours à partir du vendredi 18 septembre 2026.
List<DateTime> _cycle() => List.generate(7, (i) => DateTime(2026, 9, 18 + i));

void main() {
  group('repas déjà au planning, par créneau', () {
    test('un repas occupe le créneau de sa date, heure comprise', () {
      final bySlot = registeredMealsBySlot(
        slotDates: _cycle(),
        meals: [
          _meal('a', DateTime(2026, 9, 18, 19)),
          _meal('b', DateTime(2026, 9, 20, 12, 30)),
          _meal('c', DateTime(2026, 9, 23, 19)),
        ],
      );
      expect(bySlot.keys, [0, 2, 5]);
      expect(bySlot[2]!.id, 'b');
    });

    test(
      'les créneaux sans repas ne figurent pas : ils restent à proposer',
      () {
        final bySlot = registeredMealsBySlot(
          slotDates: _cycle(),
          meals: [
            _meal('a', DateTime(2026, 9, 18, 19)),
            _meal('b', DateTime(2026, 9, 19, 19)),
            _meal('c', DateTime(2026, 9, 20, 19)),
          ],
        );
        expect(_cycle().length - bySlot.length, 4);
      },
    );

    test('un repas hors du cycle n\'occupe aucun créneau', () {
      final bySlot = registeredMealsBySlot(
        slotDates: _cycle(),
        meals: [
          _meal('avant', DateTime(2026, 9, 17, 19)),
          _meal('apres', DateTime(2026, 9, 25, 19)),
        ],
      );
      expect(bySlot, isEmpty);
    });

    test('deux repas le même jour : le premier de la journée l\'emporte', () {
      final bySlot = registeredMealsBySlot(
        slotDates: _cycle(),
        meals: [
          _meal('soir', DateTime(2026, 9, 19, 19)),
          _meal('midi', DateTime(2026, 9, 19, 12)),
        ],
      );
      expect(bySlot.length, 1);
      expect(bySlot[1]!.id, 'midi');
    });

    test('un repas libre, sans recette, occupe son créneau aussi', () {
      final bySlot = registeredMealsBySlot(
        slotDates: _cycle(),
        meals: [_meal('libre', DateTime(2026, 9, 21, 19), recipeId: null)],
      );
      expect(bySlot[3]!.recipeId, isNull);
    });
  });

  group('empreinte d\'un repas', () {
    test('la même pour deux lectures du même repas', () {
      final at = DateTime(2026, 9, 18, 19);
      expect(
        plannedMealContentKey(_meal('a', at)),
        plannedMealContentKey(_meal('a', at)),
      );
    });

    test('ni l\'identifiant ni la date de création n\'y entrent', () {
      final at = DateTime(2026, 9, 18, 19);
      final other = PlannedMeal(
        id: 'autre',
        uid: 'autre',
        recipeId: 'r',
        recipeTitre: 'Titre a',
        plannedAt: at,
        durationMinutes: 45,
        createdAt: DateTime(2020),
      );
      expect(
        plannedMealContentKey(other),
        plannedMealContentKey(_meal('a', at)),
      );
    });

    test('changer la recette, l\'heure ou un composant la fait bouger', () {
      final at = DateTime(2026, 9, 18, 19);
      final base = plannedMealContentKey(_meal('a', at));
      expect(
        plannedMealContentKey(_meal('a', at, recipeId: 'autre')),
        isNot(base),
      );
      expect(
        plannedMealContentKey(_meal('a', DateTime(2026, 9, 18, 20))),
        isNot(base),
      );
      expect(
        plannedMealContentKey(
          _meal(
            'a',
            at,
            components: const [
              MealComponent(
                role: MealComponentRole.accompagnement,
                stapleId: 'riz',
                label: 'Riz',
              ),
            ],
          ),
        ),
        isNot(base),
      );
    });
  });
}
