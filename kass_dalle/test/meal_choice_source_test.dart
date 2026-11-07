import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_choice_source.dart';
import 'package:kass_dalle/features/planning/domain/planning_refusals.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';

/// `MealChoiceSource.workshop` (v0.24.78) : la valeur stockée, le libellé
/// « Composée avec l'IA », la lecture tolérante, l'icône robot, et le refus
/// compté comme pour `ai` et `concept`.
void main() {
  test('valeur stockée et libellé', () {
    expect(MealChoiceSource.workshop.value, 'workshop');
    expect(MealChoiceSource.workshop.label, 'Composée avec l\'IA');
  });

  test('fromValue lit workshop, et rend null pour une valeur inconnue', () {
    expect(MealChoiceSource.fromValue('workshop'), MealChoiceSource.workshop);
    expect(MealChoiceSource.fromValue('atelier'), isNull);
    expect(MealChoiceSource.fromValue(null), isNull);
  });

  test('écarter une recette posée par l\'atelier compte comme un refus', () {
    expect(countsAsRefusal(MealChoiceSource.workshop), isTrue);
  });

  test('icône robot, comme ai et concept', () {
    expect(
      MealOriginLine.iconFor(MealChoiceSource.workshop),
      Icons.smart_toy_outlined,
    );
    expect(
      MealOriginLine.iconFor(MealChoiceSource.workshop),
      MealOriginLine.iconFor(MealChoiceSource.concept),
    );
  });
}
