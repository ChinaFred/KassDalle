import '../../recipes/domain/recipe.dart';

/// Une idée de repas rendue par l'IA sur une consigne libre.
///
/// Ce n'est pas une recette : un nom, une phrase, deux durées estimées.
/// Retenue, elle devient un repas libre du planning, sans recette liée —
/// rien n'est écrit dans les livres.
class MealIdea {
  final String titre;
  final String description;
  final int? prepMinutes;
  final int? cookMinutes;

  const MealIdea({
    required this.titre,
    this.description = '',
    this.prepMinutes,
    this.cookMinutes,
  });

  /// Le repas libre que le sélecteur rend : même forme que « Saisir un nom
  /// libre », avec en plus les durées estimées, pour que le planning affiche
  /// une durée et que le calendrier réserve le bon créneau.
  Recipe toFreeRecipe() {
    final now = DateTime.now();
    return Recipe(
      id: '',
      titre: titre,
      langue: 'fr',
      rawCooklang: '',
      imageUrls: const [],
      reviewStatus: ReviewStatus.validated,
      tags: RecipeTags(prepTime: prepMinutes, cookTime: cookMinutes),
      ingredientsIndex: const [],
      createdBy: '',
      createdAt: now,
      updatedAt: now,
    );
  }

  /// « 10min prép + 25min cuisson », ou vide sans durée.
  String get timesLabel => [
    if (prepMinutes != null) '${prepMinutes}min prép',
    if (cookMinutes != null) '${cookMinutes}min cuisson',
  ].join(' + ');
}

/// Ce que le sélecteur appelle pour obtenir des idées : la consigne, et les
/// titres déjà rendus pour que la relance en propose d'autres.
typedef MealIdeasGenerator =
    Future<List<MealIdea>> Function({
      required String prompt,
      required List<String> previousTitles,
    });
