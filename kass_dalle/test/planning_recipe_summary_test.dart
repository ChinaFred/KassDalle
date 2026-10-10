import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/services/planning_ai_service.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le résumé d'une recette envoyé à `suggestMealPlanFn`. La présélection
/// serveur lit la protéine et le féculent dans `mainProtein` / `mainStarch` ;
/// un champ oublié ici fait retomber la répartition sur `dishTypes`, sans
/// erreur.
Recipe _recipe(RecipeTags tags) {
  final t = DateTime(2026, 10, 10);
  return Recipe(
    id: 'r1',
    titre: 'Poulet au riz',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: tags,
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
  );
}

void main() {
  test('un plat envoie sa protéine et son féculent', () {
    final summary = planningRecipeSummary(
      _recipe(
        const RecipeTags(
          mealRole: 'plat',
          mainProtein: 'volaille',
          mainStarch: 'riz',
        ),
      ),
    );
    expect(summary['mainProtein'], 'volaille');
    expect(summary['mainStarch'], 'riz');
  });

  test('un dessert ne les envoie pas, même restés d\'un ancien rôle', () {
    final summary = planningRecipeSummary(
      _recipe(
        const RecipeTags(
          mealRole: 'dessert',
          mainProtein: 'oeuf',
          mainStarch: 'pain',
        ),
      ),
    );
    expect(summary.containsKey('mainProtein'), isFalse);
    expect(summary.containsKey('mainStarch'), isFalse);
  });

  test('sans tag, aucune clé', () {
    final summary = planningRecipeSummary(
      _recipe(const RecipeTags(mealRole: 'plat')),
    );
    expect(summary.containsKey('mainProtein'), isFalse);
    expect(summary.containsKey('mainStarch'), isFalse);
  });
}
