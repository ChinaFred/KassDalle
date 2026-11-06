/// La recette en mémoire que rend `generateRecipeFn`, et avec elle
/// `mealWorkshopRecipeFn` : « Imaginer 3 recettes » et l'atelier repas la
/// lisent avec le même code.
library;

import '../../recipes/domain/recipe.dart';

/// Recette en mémoire à partir de la réponse de `generateRecipeFn`.
Recipe recipeFromGeneratedRaw(
  Map<String, dynamic> raw, {
  required String fallbackTitle,
}) {
  final ingredients = (raw['ingredients'] as List? ?? const [])
      .map((entry) {
        final map = Map<String, dynamic>.from(entry as Map);
        return RecipeIngredient(
          name: map['name'] as String? ?? '',
          qty: map['qty'] as String? ?? '',
          unit: map['unit'] as String? ?? '',
        );
      })
      .toList(growable: false);
  final tagsRaw = Map<String, dynamic>.from(raw['tags'] as Map? ?? {});
  final now = DateTime.now();
  return Recipe(
    id: '',
    titre: raw['titre'] as String? ?? fallbackTitle,
    langue: raw['langue'] as String? ?? 'fr',
    rawCooklang: raw['cooklang'] as String? ?? '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.draft,
    tags: RecipeTags(
      themes: List<String>.from(tagsRaw['themes'] as List? ?? []),
      cuisines: List<String>.from(tagsRaw['cuisines'] as List? ?? []),
      occasions: List<String>.from(tagsRaw['occasions'] as List? ?? []),
      dishTypes: List<String>.from(tagsRaw['dish_types'] as List? ?? []),
      difficulty: tagsRaw['difficulty'] as String?,
      prepTime: (tagsRaw['prep_time'] as num?)?.toInt(),
      cookTime: (tagsRaw['cook_time'] as num?)?.toInt(),
    ),
    ingredientsIndex: List<String>.from(
      raw['ingredients_index'] as List? ?? [],
    ),
    createdBy: '',
    createdAt: now,
    updatedAt: now,
    portions: (raw['portions'] as num?)?.toInt(),
    ingredients: ingredients,
  );
}
