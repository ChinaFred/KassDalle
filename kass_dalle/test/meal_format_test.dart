import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';

/// Le format d'un repas : ce qu'il demande autour du plat, et comment il se
/// stocke sur un jour de la semaine.
///
/// Un format mal lu ne lève rien : un dessert apparaît un mardi qui n'en
/// voulait pas, ou le repas complet du dimanche retombe en plat seul.
void main() {
  group('format', () {
    test('clé et retour', () {
      for (final f in MealFormat.values) {
        expect(MealFormat.fromKey(f.key), f, reason: f.key);
      }
    });

    test('absent ou inconnu : pas réglé, jamais deviné', () {
      expect(MealFormat.fromKey(null), isNull);
      expect(MealFormat.fromKey('brunch'), isNull);
      expect(MealFormat.fromKey(''), isNull);
    });

    test('le défaut est le plat seul', () {
      expect(MealFormat.defaultFormat, MealFormat.plat);
      expect(MealFormat.plat.wantsStarter, isFalse);
      expect(MealFormat.plat.wantsDessert, isFalse);
      expect(MealFormat.plat.isLight, isFalse);
    });

    test('ce que chaque format demande', () {
      expect(MealFormat.platDessert.wantsDessert, isTrue);
      expect(MealFormat.platDessert.wantsStarter, isFalse);
      expect(MealFormat.entreePlat.wantsStarter, isTrue);
      expect(MealFormat.entreePlat.wantsDessert, isFalse);
      expect(MealFormat.entreePlatDessert.wantsStarter, isTrue);
      expect(MealFormat.entreePlatDessert.wantsDessert, isTrue);
      expect(MealFormat.leger.isLight, isTrue);
      expect(MealFormat.leger.wantsStarter, isFalse);
      expect(MealFormat.leger.wantsDessert, isFalse);
    });

    test('chaque format a un libellé et une description', () {
      for (final f in MealFormat.values) {
        expect(f.label.trim(), isNotEmpty, reason: f.key);
        expect(f.description.trim(), isNotEmpty, reason: f.key);
      }
    });
  });

  group('sur un jour de la semaine', () {
    test('absent : le plat seul, et rien n\'est écrit', () {
      final c = DayConstraint.fromMap({'max_prep_minutes': 30});
      expect(c.mealFormat, isNull);
      expect(c.effectiveFormat, MealFormat.plat);
      expect(c.toMap().containsKey('meal_format'), isFalse);
    });

    test('réglé : écrit sous sa clé, et le jour n\'est plus vide', () {
      const c = DayConstraint(mealFormat: MealFormat.entreePlatDessert);
      expect(c.isEmpty, isFalse);
      expect(c.toMap()['meal_format'], 'entree_plat_dessert');
      final back = DayConstraint.fromMap(c.toMap());
      expect(back.mealFormat, MealFormat.entreePlatDessert);
    });

    test('une clé inconnue en base se relit comme « pas réglé »', () {
      final c = DayConstraint.fromMap({'meal_format': 'brunch'});
      expect(c.mealFormat, isNull);
      expect(c.isEmpty, isTrue);
    });

    test('copyWith garde le format, clearMealFormat le retire', () {
      const c = DayConstraint(mealFormat: MealFormat.leger, targetPortions: 4);
      expect(c.copyWith(targetPortions: 2).mealFormat, MealFormat.leger);
      expect(c.copyWith(clearMealFormat: true).mealFormat, isNull);
      expect(
        c.copyWith(mealFormat: MealFormat.platDessert).mealFormat,
        MealFormat.platDessert,
      );
    });
  });
}
