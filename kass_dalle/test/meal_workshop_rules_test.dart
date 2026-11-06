import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_composition.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_summary.dart';

/// Les bornes de l'atelier repas, côté Dart.
///
/// Le client ferme le champ au 21e tour et refuse un message trop long ; le
/// serveur refuse les mêmes entrées, lit les résumés en liste blanche et
/// tronque le menu. Un écart ne lève aucune erreur : il laisse passer un
/// message que le serveur refuse, ou coupe un résumé que le serveur attend.
/// Les valeurs viennent donc de `test-fixtures/meal_workshop_rules.json`,
/// rejouée par `functions/src/tests/`.
void main() {
  final file = File('test-fixtures/meal_workshop_rules.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('services et accompagnements au plus par menu', () {
    expect(kMaxCoursesPerMenu, fixture['max_courses']);
    expect(kMaxSidesPerDish, fixture['max_sides']);
    expect(kWorkshopMaxDishCourses, fixture['max_dish_courses']);
  });

  test('tours et caractères au plus par conversation', () {
    expect(kWorkshopMaxTurns, fixture['max_turns']);
    expect(kWorkshopMaxMessageChars, fixture['max_user_chars']);
    expect(kWorkshopMaxAssistantChars, fixture['max_assistant_chars']);
  });

  test('tours par jour et par compte', () {
    expect(kWorkshopDailyLimit, fixture['daily_limit']);
  });

  test('résumé d\'une recette : ingrédients et clés', () {
    expect(kWorkshopSummaryMaxIngredients, fixture['max_summary_ingredients']);
    expect(
      kWorkshopSummaryKeys,
      (fixture['summary_keys'] as List).cast<String>(),
    );
  });
}
