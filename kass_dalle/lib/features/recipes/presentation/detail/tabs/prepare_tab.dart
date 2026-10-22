import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/utils/recipe_portion_scaler.dart';
import '../../../../auth/presentation/auth_providers.dart';
import '../../../domain/recipe.dart';
import '../../../domain/recipe_filter.dart' show recipeShownEstimate;
import '../../cooklang_preview.dart';
import '../recipe_illustration_actions.dart';
import '../shopping_list_sheet.dart';
import '../../url_import/recipe_source_link.dart';
import '../../../../planning/domain/meal_prep_context.dart';
import '../../../../planning/presentation/meal_prep_banner.dart';
import '../../../../planning/presentation/schedule_recipe_sheet.dart';
import '../../../../planning/presentation/suggest_meal_screen.dart';
import '../recipe_allergens_block.dart';

/// Onglet « Préparer » : illustrations, ingrédients et étapes de la recette.
///
/// Extrait de recipe_detail_screen.dart.

/// Ce qui précède la recette : le repas préparé à l'avance, puis la page
/// d'origine d'une recette importée depuis un lien. `null` quand il n'y a ni
/// l'un ni l'autre.
Widget? recipeTopContent({required Recipe recipe, Widget? banner}) {
  final sourceUrl = recipe.sourceUrl;
  final hasSource = sourceUrl != null && sourceUrl.isNotEmpty;
  if (!hasSource) return banner;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      ?banner,
      RecipeSourceLink(
        url: sourceUrl,
        site: recipe.sourceSite,
        author: recipe.sourceAuthor,
      ),
    ],
  );
}

class PrepareTab extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;
  final bool canEdit;

  /// Propriétaire ET éditeur (`AppUser.canEnrichRecipe`) : ajouter une
  /// illustration. Un propriétaire lecteur garde la suppression ([canEdit]).
  final bool canEnrich;
  final int? basePortions;
  final int? selectedPortions;
  final ValueChanged<int>? onSelectedPortionsChanged;

  /// Contexte du repas planifié, quand la recette se cuisine à l'avance.
  final MealPrepContext? prepContext;

  const PrepareTab({
    super.key,
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEdit,
    required this.canEnrich,
    this.basePortions,
    this.selectedPortions,
    this.onSelectedPortionsChanged,
    this.prepContext,
  });

  @override
  ConsumerState<PrepareTab> createState() => PrepareTabState();
}

class PrepareTabState extends ConsumerState<PrepareTab>
    with RecipeIllustrationActions<PrepareTab> {
  @override
  bool uploadingIllustration = false;

  @override
  String get recipeId => widget.recipeId;

  @override
  Widget build(BuildContext context) {
    final recipe = widget.recipe;
    final basePortions = widget.basePortions;
    final selectedPortions = widget.selectedPortions;
    final scaleFactor =
        basePortions != null &&
            selectedPortions != null &&
            basePortions > 0 &&
            selectedPortions > 0
        ? portionScaleFactor(
            basePortions: basePortions,
            targetPortions: selectedPortions,
          )
        : 1.0;
    final scaledIngredients = scaleRecipeIngredients(
      recipe.ingredients,
      scaleFactor,
    );
    final prepContext = widget.prepContext;

    return SingleChildScrollView(
      child: Stack(
        children: [
          Column(
            children: [
              CooklangPreview(
                ctrl: widget.ctrl,
                topContent: recipeTopContent(
                  recipe: recipe,
                  banner: prepContext != null && prepContext.isAhead
                      ? MealPrepBanner(
                          recipeId: widget.recipeId,
                          prepContext: prepContext,
                        )
                      : null,
                ),
                overrideIngredients: recipe.ingredients,
                estimatedTimes: recipeShownEstimate(recipe),
                ingredientsFooter: recipe.allergens == null
                    ? null
                    : RecipeAllergensBlock(allergens: recipe.allergens!),
                basePortions: basePortions,
                selectedPortions: selectedPortions,
                onSelectedPortionsChanged: widget.onSelectedPortionsChanged,
                illustrationUrls: recipe.imageUrls.isNotEmpty
                    ? recipe.imageUrls
                    : null,
                onAddIllustration: widget.canEnrich ? addIllustration : null,
                onTapIllustration: recipe.imageUrls.isNotEmpty
                    ? (i) => showGallery(recipe.imageUrls, i)
                    : null,
                onDeleteIllustration: widget.canEdit
                    ? deleteIllustration
                    : null,
                onCreateShoppingList: recipe.ingredients.isNotEmpty
                    ? () => addRecipeToShoppingList(
                        context,
                        ref,
                        products: scaleShoppingProducts(
                          recipe.shoppingProducts,
                          scaleFactor,
                        ),
                        fallbackIngredients: scaledIngredients,
                        recipeTitre: recipe.titre,
                      )
                    : null,
                // Planifier est un geste d'éditeur : le lecteur ne planifie plus.
                onSchedule:
                    ref.watch(canEditProvider) && recipe.ingredients.isNotEmpty
                    ? () => showScheduleRecipeSheet(
                        context,
                        titre: recipe.titre,
                        recipeId: recipe.id,
                        prepTimeMin: recipe.tags.prepTime,
                        cookTimeMin: recipe.tags.cookTime,
                        portions: recipe.portions,
                        ingredients: recipe.ingredients,
                        recipe: recipe,
                      )
                    : null,
                onSuggest: suggestRecipeAction(context, ref, recipe),
                recipeTags: recipe.tags,
              ),
            ],
          ),
          if (uploadingIllustration)
            Positioned.fill(
              child: Container(
                color: Colors.black26,
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}
