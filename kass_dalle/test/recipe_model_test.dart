import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Substitut de `Timestamp` : `Recipe.fromFirestore` n'attend qu'un objet
/// exposant `toDate()`, ce qui permet de tester le modèle sans Firebase.
class _FakeTimestamp {
  final DateTime value;
  const _FakeTimestamp(this.value);
  DateTime toDate() => value;
}

/// Rejoue le trajet d'un document : ce que `toFirestore` écrit est relu par
/// `fromFirestore`. Seules les dates changent de forme (Firestore les rend
/// sous forme de `Timestamp`).
Map<String, dynamic> _asFirestoreDocument(Map<String, dynamic> written) {
  return written.map((key, value) {
    if (value is DateTime) return MapEntry(key, _FakeTimestamp(value));
    return MapEntry(key, value);
  });
}

Recipe _fullRecipe() {
  return Recipe(
    id: 'r1',
    titre: 'Tarte aux poireaux',
    bookId: 'b1',
    bookTitre: 'Les classiques',
    pageNumber: 42,
    langue: 'fr',
    rawCooklang: '>> portions: 4\nMélanger la @farine{200%g}.',
    draftCooklang: '>> portions: 4\nBrouillon.',
    imageUrls: const ['https://example.test/1.jpg'],
    thumbnailUrls: const ['https://example.test/1_400.webp'],
    reviewStatus: ReviewStatus.inReview,
    tags: const RecipeTags(
      themes: ['hiver'],
      cuisines: ['belge'],
      occasions: ['quotidien'],
      dishTypes: ['plat complet'],
      difficulty: 'medium',
      prepTime: 30,
      cookTime: 45,
    ),
    ingredientsIndex: const ['farine', 'poireau'],
    createdBy: 'uid-1',
    createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
    updatedAt: DateTime.utc(2026, 2, 3, 4, 5, 6),
    sourceFileUrl: 'https://example.test/source.pdf',
    sourceFileName: 'source.pdf',
    additionalSourceFileUrls: const ['https://example.test/p2.jpg'],
    aiProcessedAt: DateTime.utc(2026, 1, 5),
    portions: 4,
    ingredients: const [
      RecipeIngredient(name: 'farine', qty: '200', unit: 'g', category: 'Pâte'),
      RecipeIngredient(name: 'poireau', qty: '3', unit: 'piece'),
    ],
    pageType: PageType.technique,
    importVersion: '0.19.37',
    shoppingProducts: const [
      RecipeShoppingProduct(name: 'farine T55', qty: '200', unit: 'g'),
    ],
    nutrition: const RecipeNutritionSnapshot(
      selectedPortions: 4,
      totalWeightG: 850,
      coverage: 0.92,
      coverageState: 'high',
      totals: {'kcal': 1800, 'proteines': 40},
      perPortion: {'kcal': 450, 'proteines': 10},
      per100g: {'kcal': 212},
      quality: RecipeNutritionQuality(
        score: 78,
        level: 'B',
        warnings: ['sel élevé'],
      ),
      missingIngredients: ['beurre demi-sel'],
    ),
    sourceRecipeId: 'r0',
  );
}

void main() {
  group('Recipe — aller-retour Firestore', () {
    test('tous les champs survivent à toFirestore → fromFirestore', () {
      final original = _fullRecipe();
      final reread = Recipe.fromFirestore(
        original.id,
        _asFirestoreDocument(original.toFirestore()),
      );

      expect(reread.titre, original.titre);
      expect(reread.bookId, original.bookId);
      expect(reread.bookTitre, original.bookTitre);
      expect(reread.pageNumber, original.pageNumber);
      expect(reread.langue, original.langue);
      expect(reread.rawCooklang, original.rawCooklang);
      expect(reread.draftCooklang, original.draftCooklang);
      expect(reread.imageUrls, original.imageUrls);
      expect(reread.thumbnailUrls, original.thumbnailUrls);
      expect(reread.reviewStatus, original.reviewStatus);
      expect(reread.tags.themes, original.tags.themes);
      expect(reread.tags.cuisines, original.tags.cuisines);
      expect(reread.tags.occasions, original.tags.occasions);
      expect(reread.tags.dishTypes, original.tags.dishTypes);
      expect(reread.tags.difficulty, original.tags.difficulty);
      expect(reread.tags.prepTime, original.tags.prepTime);
      expect(reread.tags.cookTime, original.tags.cookTime);
      expect(reread.ingredientsIndex, original.ingredientsIndex);
      expect(reread.createdBy, original.createdBy);
      expect(reread.createdAt, original.createdAt);
      expect(reread.updatedAt, original.updatedAt);
      expect(reread.sourceFileUrl, original.sourceFileUrl);
      expect(reread.sourceFileName, original.sourceFileName);
      expect(
        reread.additionalSourceFileUrls,
        original.additionalSourceFileUrls,
      );
      expect(reread.aiProcessedAt, original.aiProcessedAt);
      expect(reread.portions, original.portions);
      expect(reread.pageType, original.pageType);
      expect(reread.importVersion, original.importVersion);
      expect(reread.sourceRecipeId, original.sourceRecipeId);

      expect(reread.ingredients.length, original.ingredients.length);
      for (var i = 0; i < original.ingredients.length; i++) {
        expect(reread.ingredients[i].name, original.ingredients[i].name);
        expect(reread.ingredients[i].qty, original.ingredients[i].qty);
        expect(reread.ingredients[i].unit, original.ingredients[i].unit);
        expect(
          reread.ingredients[i].category,
          original.ingredients[i].category,
        );
      }

      expect(reread.shoppingProducts.length, 1);
      expect(reread.shoppingProducts.first.name, 'farine T55');

      expect(reread.nutrition, isNotNull);
      expect(reread.nutrition!.selectedPortions, 4);
      expect(reread.nutrition!.totalWeightG, 850);
      expect(reread.nutrition!.coverage, 0.92);
      expect(reread.nutrition!.coverageState, 'high');
      expect(reread.nutrition!.totals['kcal'], 1800);
      expect(reread.nutrition!.perPortion['kcal'], 450);
      expect(reread.nutrition!.per100g?['kcal'], 212);
      expect(reread.nutrition!.quality.score, 78);
      expect(reread.nutrition!.quality.level, 'B');
      expect(reread.nutrition!.quality.warnings, ['sel élevé']);
      expect(reread.nutrition!.missingIngredients, ['beurre demi-sel']);
    });

    test('une page de type recipe se relit sans champ page_type', () {
      final original = _fullRecipe().copyWith(pageType: PageType.recipe);
      final written = original.toFirestore();
      expect(written.containsKey('page_type'), isFalse);

      final reread = Recipe.fromFirestore(
        original.id,
        _asFirestoreDocument(written),
      );
      expect(reread.pageType, PageType.recipe);
    });
  });

  group('Recipe.copyWith', () {
    // Ce test est le filet qui manquait : `copyWith` oubliait `thumbnailUrls`,
    // et `updateRecipe` passe par `copyWith` avant `toFirestore`. Chaque
    // édition de recette effaçait donc les vignettes générées côté serveur,
    // sans erreur ni trace — l'UI retombant silencieusement sur `imageUrls`.
    test('sans argument, n\'altère aucun champ persisté', () {
      final original = _fullRecipe();
      expect(original.copyWith().toFirestore(), original.toFirestore());
    });

    test('conserve les vignettes quand on ne les touche pas', () {
      final original = _fullRecipe();
      final edited = original.copyWith(titre: 'Nouveau titre');

      expect(edited.titre, 'Nouveau titre');
      expect(edited.thumbnailUrls, original.thumbnailUrls);
      expect(edited.toFirestore()['thumbnail_urls'], original.thumbnailUrls);
    });

    test('remplace les vignettes quand on les fournit', () {
      final edited = _fullRecipe().copyWith(thumbnailUrls: const ['a.webp']);
      expect(edited.thumbnailUrls, const ['a.webp']);
    });
  });
}
