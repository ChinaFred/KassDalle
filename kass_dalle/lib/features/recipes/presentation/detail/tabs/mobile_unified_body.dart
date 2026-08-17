import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/utils/recipe_portion_scaler.dart';
import '../../../../auth/presentation/auth_providers.dart';
import '../../../domain/recipe.dart';
import '../../cooklang_preview.dart';
import '../../recipe_providers.dart';
import '../dressing_coach_section.dart';
import '../nutrition_details_section.dart';
import '../recipe_illustration_actions.dart';
import '../shopping_list_sheet.dart';
import 'community_summary.dart';
import '../../../../planning/domain/meal_prep_context.dart';
import '../../../../planning/presentation/meal_prep_banner.dart';
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

  /// Contexte du repas planifié, quand la recette se cuisine à l'avance.
  final MealPrepContext? prepContext;

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
    this.prepContext,
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
    final prepContext = widget.prepContext;
    // Le bandeau de préparation à l'avance passe devant le mode cuisine : c'est
    // la première chose à savoir quand on ouvre le plat qu'on cuisine pour un
    // autre jour.
    final prepBanner = prepContext != null && prepContext.isAhead
        ? MealPrepBanner(recipeId: widget.recipeId, prepContext: prepContext)
        : null;
    // En tête : ce qui décide comment on lit la suite — le repas préparé à
    // l'avance, puis le mode cuisine. La recette elle-même vient juste après ;
    // nutrition, dressage et communauté la suivent, dans cet ordre.
    final kitchenModeCard = Card(
      margin: EdgeInsets.zero,
      child: SwitchListTile.adaptive(
        value: widget.kitchenMode,
        onChanged: widget.onKitchenModeChanged,
        title: const Text('Mode cuisine'),
        secondary: const Icon(Icons.soup_kitchen_outlined),
      ),
    );
    final topContent = prepBanner == null
        ? kitchenModeCard
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [prepBanner, const SizedBox(height: 12), kitchenModeCard],
          );

    Widget preview = CooklangPreview(
      ctrl: widget.ctrl,
      topContent: topContent,
      bottomContent: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MobileSection(
            title: 'Nutrition',
            child: NutritionDetailsSection(
              recipe: recipe,
              selectedPortions: selectedPortions,
              onRecompute: () async {
                await ref
                    .read(recipeRepositoryProvider)
                    .recomputeNutrition(recipeId: widget.recipeId);
              },
            ),
          ),
          const SizedBox(height: 12),
          _MobileSection(
            title: 'Dressage',
            child: DressingCoachSection(
              recipe: recipe,
              canEdit: widget.canEdit,
            ),
          ),
          const SizedBox(height: 12),
          MobileCommunitySummary(
            recipeId: widget.recipeId,
            onOpenCommunity: widget.onOpenCommunity,
          ),
        ],
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

/// Section du corps mobile : une carte titrée.
///
/// Sur grand écran, chaque section a son onglet et le nom est sur l'onglet.
/// Empilées, elles ont besoin qu'on les nomme — sans quoi la nutrition et le
/// dressage se lisent comme la suite de la recette.
class _MobileSection extends StatelessWidget {
  final String title;
  final Widget child;

  const _MobileSection({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
