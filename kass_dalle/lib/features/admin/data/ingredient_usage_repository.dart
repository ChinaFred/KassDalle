import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/ingredient_recipe_usage.dart';

/// Les recettes qui citent un ingrédient du référentiel nutrition.
///
/// Lecture seule, réservée à Admin › Ingrédients nutrition : un
/// administrateur lit toutes les recettes (règles Firestore), privées
/// comprises, et la requête ne filtre donc pas `is_private`.
class IngredientUsageRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  IngredientUsageRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Une seule requête : `ingredients_index` contient l'une des [values],
  /// au plus [kIngredientUsageDisplayLimit] + 1 documents.
  ///
  /// Ni tri ni autre filtre : `array-contains-any` seul se sert de l'index
  /// automatique du champ, sans index composite. Un `orderBy` en exigerait
  /// un. Le titre du livre est lu sur la recette (`book_titre`) : aucune
  /// lecture de plus par recette.
  Future<IngredientRecipeUsage> fetchRecipesUsing(List<String> values) async {
    if (values.isEmpty) return IngredientRecipeUsage.empty;
    final searched = values.length > kIngredientUsageMaxValues
        ? values.sublist(0, kIngredientUsageMaxValues)
        : values;
    try {
      final snap = await _firestore
          .collection('recipes')
          .where('ingredients_index', arrayContainsAny: searched)
          .limit(kIngredientUsageDisplayLimit + 1)
          .get();
      final recipes = snap.docs
          .map((d) => IngredientRecipeRef.fromFirestore(d.id, d.data()))
          .toList(growable: false);
      final hasMore = recipes.length > kIngredientUsageDisplayLimit;
      return IngredientRecipeUsage(
        recipes: hasMore
            ? recipes.sublist(0, kIngredientUsageDisplayLimit)
            : recipes,
        hasMore: hasMore,
      );
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'ingredientUsage.fetchRecipesUsing',
        error: error,
        stackTrace: stackTrace,
        context: {'values': searched},
      );
      rethrow;
    }
  }
}
