import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_prep_context.dart';
import 'package:kass_dalle/features/planning/domain/meal_storage_rules.dart';

/// Contexte de préparation à l'avance transporté dans l'adresse de la recette.
///
/// Ce qui se joue ici est un aller-retour : le planning écrit deux dates dans
/// l'URL, le routeur les relit. Une écriture et une lecture qui divergent ne
/// lèvent aucune erreur — la fiche s'ouvre simplement sans bandeau, comme si le
/// plat se cuisinait le jour même.
void main() {
  group('aller-retour par l\'adresse', () {
    test('les deux dates survivent au passage par les paramètres', () {
      final source = MealPrepContext(
        prepDate: DateTime(2026, 8, 23),
        mealDate: DateTime(2026, 8, 25),
      );

      final relu = MealPrepContext.fromQueryParameters(
        source.toQueryParameters(),
      );

      expect(relu, isNotNull);
      expect(relu!.prepDate, DateTime(2026, 8, 23));
      expect(relu.mealDate, DateTime(2026, 8, 25));
      expect(relu.daysAhead, 2);
    });

    test('les jours à un chiffre gardent leur zéro', () {
      final params = MealPrepContext(
        prepDate: DateTime(2026, 1, 5),
        mealDate: DateTime(2026, 1, 7),
      ).toQueryParameters();

      expect(params[kPrepDateQueryParam], '2026-01-05');
      expect(params[kMealDateQueryParam], '2026-01-07');
    });

    test('une adresse sans contexte ne rend rien', () {
      expect(
        MealPrepContext.fromQueryParameters(const {'portions': '8'}),
        isNull,
      );
    });

    test('une date illisible ne rend rien plutôt qu\'une date inventée', () {
      expect(
        MealPrepContext.fromQueryParameters(const {
          kPrepDateQueryParam: 'dimanche',
          kMealDateQueryParam: '2026-08-25',
        }),
        isNull,
      );
    });

    test('une seule des deux dates ne suffit pas', () {
      expect(
        MealPrepContext.fromQueryParameters(const {
          kPrepDateQueryParam: '2026-08-23',
        }),
        isNull,
      );
    });
  });

  group('ce que le contexte décide', () {
    test('préparé le jour du repas, il n\'y a rien à conserver', () {
      final context = MealPrepContext(
        prepDate: DateTime(2026, 8, 24, 10),
        mealDate: DateTime(2026, 8, 24, 19),
      );

      expect(context.isAhead, isFalse);
      expect(context.mode, MealStorageMode.sameDay);
    });

    test('la veille au soir pour le lendemain compte un jour', () {
      final context = MealPrepContext(
        prepDate: DateTime(2026, 8, 23, 22),
        mealDate: DateTime(2026, 8, 24, 12),
      );

      expect(context.isAhead, isTrue);
      expect(context.mode, MealStorageMode.fridge);
      expect(context.instruction, contains('réfrigérateur'));
    });

    test(
      'au-delà de la limite du froid, la consigne bascule au congélateur',
      () {
        final context = MealPrepContext(
          prepDate: DateTime(2026, 8, 23),
          mealDate: DateTime(
            2026,
            8,
            23,
          ).add(const Duration(days: kMaxFridgeDays + 1)),
        );

        expect(context.mode, MealStorageMode.freezer);
        expect(context.instruction, contains('congeler'));
      },
    );
  });
}
