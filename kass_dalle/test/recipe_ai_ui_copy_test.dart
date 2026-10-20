import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/presentation/ai/ai_ui_copy.dart';

void main() {
  group('RecipeAiUiCopy.illustrationsExtracted', () {
    test('accorde au singulier pour une illustration', () {
      expect(
        RecipeAiUiCopy.illustrationsExtracted(1),
        '1 illustration extraite ✓',
      );
    });

    test('accorde au pluriel au-delà', () {
      expect(
        RecipeAiUiCopy.illustrationsExtracted(2),
        '2 illustrations extraites ✓',
      );
      expect(
        RecipeAiUiCopy.illustrationsExtracted(12),
        '12 illustrations extraites ✓',
      );
    });
  });

  test('aucune illustration : phrase terminée par un point', () {
    expect(
      RecipeAiUiCopy.noIllustrationFound,
      'Aucune illustration trouvée dans le scan.',
    );
  });
}
