import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/utils/recipe_portion_scaler.dart';
import '../../../../auth/presentation/auth_providers.dart';
import '../../../domain/recipe.dart';
import '../../cooklang_preview.dart';
import '../../recipe_providers.dart';
import '../dressing_coach_screen.dart';
import '../nutrition_details_section.dart';
import '../recipe_illustration_actions.dart';
import '../shopping_list_sheet.dart';
import 'community_summary.dart';
import '../../../../planning/presentation/schedule_recipe_sheet.dart';

/// Corps unifié de l'écran de détail sur mobile : illustrations, méta,
/// ingrédients, préparation et résumé communauté sur une seule page.
///
/// Extrait de recipe_detail_screen.dart.

class MobileUnifiedBody extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;
  final bool canEdit;
  final int? basePortions;
  final int? selectedPortions;
  final bool kitchenMode;
  final ValueChanged<bool> onKitchenModeChanged;
  final ValueChanged<int>? onSelectedPortionsChanged;
  final Future<void> Function() onOpenCommunity;

  const MobileUnifiedBody({
    super.key,
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEdit,
    this.basePortions,
    this.selectedPortions,
    required this.kitchenMode,
    required this.onKitchenModeChanged,
    this.onSelectedPortionsChanged,
    required this.onOpenCommunity,
  });

  @override
  ConsumerState<MobileUnifiedBody> createState() => MobileUnifiedBodyState();
}

class MobileUnifiedBodyState extends ConsumerState<MobileUnifiedBody>
    with RecipeIllustrationActions<MobileUnifiedBody> {
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
    final topContent = Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          SwitchListTile.adaptive(
            value: widget.kitchenMode,
            onChanged: widget.onKitchenModeChanged,
            title: const Text('Mode cuisine'),
            secondary: const Icon(Icons.soup_kitchen_outlined),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: NutritionDetailsSection(
              recipe: recipe,
              selectedPortions: selectedPortions,
              onRecompute: () async {
                final portions = selectedPortions ?? basePortions ?? 1;
                await ref
                    .read(recipeRepositoryProvider)
                    .recomputeNutrition(
                      recipeId: widget.recipeId,
                      selectedPortions: portions,
                    );
              },
            ),
          ),
        ],
      ),
    );

    Widget preview = CooklangPreview(
      ctrl: widget.ctrl,
      topContent: topContent,
      bottomContent: widget.kitchenMode
          ? Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: DressingGuidanceSection(
                  recipe: recipe,
                  basePortions: basePortions,
                  selectedPortions: selectedPortions,
                ),
              ),
            )
          : MobileCommunitySummary(
              recipeId: widget.recipeId,
              onOpenCommunity: widget.onOpenCommunity,
            ),
      overrideIngredients: recipe.ingredients,
      basePortions: basePortions,
      selectedPortions: selectedPortions,
      onSelectedPortionsChanged: widget.onSelectedPortionsChanged,
      illustrationUrls: recipe.imageUrls.isNotEmpty ? recipe.imageUrls : null,
      onAddIllustration: widget.canEdit && !widget.kitchenMode
          ? addIllustration
          : null,
      onTapIllustration: recipe.imageUrls.isNotEmpty
          ? (i) => showGallery(recipe.imageUrls, i)
          : null,
      onDeleteIllustration: widget.canEdit && !widget.kitchenMode
          ? deleteIllustration
          : null,
      onCreateShoppingList: recipe.ingredients.isNotEmpty
          ? () {
              final uid = ref.read(appUserProvider).value?.uid ?? '';
              final scaledProducts = scaleShoppingProducts(
                recipe.shoppingProducts,
                scaleFactor,
              );
              showShoppingListSheet(
                context,
                scaledProducts,
                scaledIngredients,
                recipe.titre,
                uid,
              );
            }
          : null,
      onSchedule: recipe.ingredients.isNotEmpty
          ? () => showScheduleRecipeSheet(
              context,
              titre: recipe.titre,
              recipeId: recipe.id,
              prepTimeMin: recipe.tags.prepTime,
              cookTimeMin: recipe.tags.cookTime,
              ingredients: recipe.ingredients,
            )
          : null,
      recipeTags: recipe.tags,
    );

    if (widget.kitchenMode) {
      preview = MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.1)),
        child: preview,
      );
    }

    return Stack(
      children: [
        preview,
        if (uploadingIllustration)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}
