import 'dart:async';

import '../../../core/services/error_report_service.dart';
import '../../books/data/book_repository.dart';
import '../../recipes/data/recipe_repository.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_workshop_freeze.dart';

/// Ce que « Figer le repas » écrit et relit dans Firestore : le livre des
/// brouillons, un brouillon par plat rédigé, et la relecture d'une recette
/// liée. Une recette liée n'est ni copiée ni modifiée.
class MealWorkshopDraftRepository {
  final RecipeRepository _recipes;
  final BookRepository _books;
  final ErrorReportService _errorReportService;

  MealWorkshopDraftRepository({
    required RecipeRepository recipes,
    BookRepository? books,
    ErrorReportService? errorReportService,
  }) : _recipes = recipes,
       _books = books ?? BookRepository(),
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Le livre choisi dans la boîte, trouvé ou créé pour le compte.
  Future<({String id, String titre})> findOrCreateBook(
    MealWorkshopBook book, {
    required String uid,
    required String displayName,
  }) => switch (book) {
    MealWorkshopBook.kassDalle => _books.findOrCreateKassDalleBook(uid),
    MealWorkshopBook.libres => _books.findOrCreateLibresBook(uid, displayName),
  };

  /// Crée le brouillon d'un plat rédigé, comme « Imaginer 3 recettes »
  /// (`saveGeneratedRecipe`) : `review_status: draft`, `origin: ai`, le livre
  /// choisi, les parts du menu, et `ai_source: "meal_workshop"`. Rend son
  /// identifiant.
  Future<String> createDraft({
    required Recipe recipe,
    required String uid,
    required ({String id, String titre}) book,
    required int portions,
  }) {
    final now = DateTime.now();
    final toSave = Recipe(
      id: '',
      titre: recipe.titre,
      langue: recipe.langue,
      rawCooklang: recipe.rawCooklang,
      draftCooklang: recipe.rawCooklang,
      imageUrls: recipe.imageUrls,
      reviewStatus: ReviewStatus.draft,
      tags: recipe.tags,
      ingredientsIndex: recipe.ingredientsIndex,
      createdBy: uid,
      createdAt: now,
      updatedAt: now,
      portions: portions,
      ingredients: recipe.ingredients,
      origin: RecipeOrigin.ai,
      bookId: book.id,
      bookTitre: book.titre,
      aiSource: kAiSourceMealWorkshop,
    );
    return _recipes.createRecipe(toSave);
  }

  /// Relit une recette liée au moment de figer : `null` si elle n'est plus
  /// lisible (supprimée, ou devenue privée pendant la conversation). Le
  /// refus est rapporté : c'est un événement à tracer, pas une panne.
  Future<Recipe?> readLinked(String recipeId) async {
    try {
      return await _recipes.getById(recipeId);
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'mealWorkshop.freeze.readLinked',
          error: e,
          stackTrace: st,
          context: {'recipe_id': recipeId},
        ),
      );
      return null;
    }
  }
}
