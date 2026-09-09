import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Le sous-titre d'un brouillon : d'où il vient.
///
/// Il disait « issu d'un scan » à tout brouillon sans recette source, les
/// recettes conçues par l'IA comprises. Un libellé faux ne lève rien : le
/// lecteur cherche une page de livre qui n'existe pas.
void main() {
  Recipe recipe({
    RecipeOrigin? origin,
    String? sourceRecipeId,
    String? sourceFileUrl,
  }) => Recipe(
    id: 'r1',
    titre: 'Parmentier de canard',
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.draft,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'u1',
    createdAt: DateTime(2026, 9, 1),
    updatedAt: DateTime(2026, 9, 1),
    origin: origin,
    sourceRecipeId: sourceRecipeId,
    sourceFileUrl: sourceFileUrl,
  );

  group('libellé', () {
    test('chaque origine a le sien', () {
      expect(draftOriginLabel(RecipeOrigin.scan), 'Brouillon issu d\'un scan');
      expect(draftOriginLabel(RecipeOrigin.ai), 'Brouillon conçu par l\'IA');
      expect(
        draftOriginLabel(RecipeOrigin.manual),
        'Brouillon saisi à la main',
      );
      expect(draftOriginLabel(RecipeOrigin.copy), contains('Copie de travail'));
    });

    test('une origine absente ne se fait pas passer pour un scan', () {
      expect(draftOriginLabel(null), isNot(contains('scan')));
    });
  });

  group('origine effective', () {
    test('le champ écrit prime', () {
      expect(
        recipe(origin: RecipeOrigin.ai, sourceFileUrl: 'x').effectiveOrigin,
        RecipeOrigin.ai,
      );
    });

    test('sans champ, une recette source fait une copie', () {
      expect(recipe(sourceRecipeId: 'r0').effectiveOrigin, RecipeOrigin.copy);
    });

    test('sans champ, un fichier source fait un scan', () {
      expect(
        recipe(sourceFileUrl: 'https://x/scan.jpg').effectiveOrigin,
        RecipeOrigin.scan,
      );
    });

    test('sans champ ni source, on ne sait pas', () {
      expect(recipe().effectiveOrigin, isNull);
    });
  });

  group('aller-retour Firestore', () {
    test('l\'origine s\'écrit sous son nom et se relit', () {
      final written = recipe(origin: RecipeOrigin.manual).toFirestore();
      expect(written['origin'], 'manual');
      expect(recipeOriginFrom(written['origin']), RecipeOrigin.manual);
    });

    test('absente, elle ne s\'écrit pas', () {
      expect(recipe().toFirestore().containsKey('origin'), isFalse);
    });

    test('une valeur inconnue se lit comme absente', () {
      expect(recipeOriginFrom('telepathie'), isNull);
      expect(recipeOriginFrom(null), isNull);
    });
  });
}
