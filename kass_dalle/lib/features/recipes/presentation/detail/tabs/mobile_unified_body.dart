import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/utils/recipe_portion_scaler.dart';
import '../../../../auth/presentation/auth_providers.dart';
import '../../../domain/recipe.dart';
import '../../../domain/recipe_filter.dart' show recipeShownEstimate;
import '../../cooklang_preview.dart';
import '../../cooklang_preview_sections.dart';
import '../../recipe_providers.dart';
import '../dressing_coach_section.dart';
import '../nutrition_details_section.dart';
import '../recipe_illustration_actions.dart';
import '../shopping_list_sheet.dart';
import 'community_summary.dart';
import 'prepare_tab.dart' show recipeTopContent;
import '../../../../planning/domain/meal_prep_context.dart';
import '../../../../planning/presentation/meal_prep_banner.dart';
import '../../../../planning/presentation/schedule_recipe_sheet.dart';
import '../../../../planning/presentation/suggest_meal_screen.dart';
import '../recipe_allergens_block.dart';

/// Corps unifié de l'écran de détail sur mobile : illustrations, méta,
/// ingrédients, préparation et résumé communauté sur une seule page.
///
/// Extrait de recipe_detail_screen.dart.

class MobileUnifiedBody extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;

  /// Propriétaire ET éditeur (`AppUser.canEnrichRecipe`) : ajouter ou
  /// supprimer une illustration, recalculer la nutrition, demander un conseil
  /// de dressage. Un propriétaire lecteur n'a aucun de ces gestes.
  final bool canEnrich;
  final int? basePortions;
  final int? selectedPortions;
  final ValueChanged<int>? onSelectedPortionsChanged;
  final Future<void> Function() onOpenCommunity;

  /// Contexte du repas planifié, quand la recette se cuisine à l'avance.
  final MealPrepContext? prepContext;

  const MobileUnifiedBody({
    super.key,
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEnrich,
    this.basePortions,
    this.selectedPortions,
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
    // En tête : ce qui décide comment on lit la suite — le repas préparé à
    // l'avance est la première chose à savoir quand on ouvre le plat qu'on
    // cuisine pour un autre jour. La recette elle-même vient juste après ;
    // nutrition, dressage et communauté la suivent, dans cet ordre.
    final topContent = recipeTopContent(
      recipe: recipe,
      banner: prepContext != null && prepContext.isAhead
          ? MealPrepBanner(recipeId: widget.recipeId, prepContext: prepContext)
          : null,
    );

    final preview = CooklangPreview(
      ctrl: widget.ctrl,
      topContent: topContent,
      estimatedTimes: recipeShownEstimate(recipe),
      ingredientsFooter: recipe.allergens == null
          ? null
          : RecipeAllergensBlock(allergens: recipe.allergens!),
      bottomContent: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MobileSection(
            icon: Icons.monitor_heart_outlined,
            title: 'Nutrition',
            child: NutritionDetailsSection(
              recipe: recipe,
              selectedPortions: selectedPortions,
              // Le calcul appelle l'IA et s'écrit sur la recette : créateur
              // éditeur ou administrateur (`computeRecipeNutritionFn`,
              // `requireEditor`).
              onRecompute: widget.canEnrich
                  ? () async {
                      await ref
                          .read(recipeRepositoryProvider)
                          .recomputeNutrition(recipeId: widget.recipeId);
                    }
                  : null,
            ),
          ),
          const SizedBox(height: 12),
          _MobileSection(
            icon: Icons.style_outlined,
            title: 'Dressage',
            // Le conseil appelle l'IA (`suggestPlatingFn`, `requireEditor`) :
            // créateur éditeur ou administrateur ; un conseil enregistré reste
            // lisible par tous.
            child: DressingCoachSection(
              recipe: recipe,
              canEdit: widget.canEnrich,
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
      onAddIllustration: widget.canEnrich ? addIllustration : null,
      onTapIllustration: recipe.imageUrls.isNotEmpty
          ? (i) => showGallery(recipe.imageUrls, i)
          : null,
      onDeleteIllustration: widget.canEnrich ? deleteIllustration : null,
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
      onSchedule: ref.watch(canEditProvider) && recipe.ingredients.isNotEmpty
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
    );

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

/// Section du corps mobile : une carte titrée, qui se replie.
///
/// Sur grand écran, chaque section a son onglet et le nom est sur l'onglet.
/// Empilées, elles ont besoin qu'on les nomme — sans quoi la nutrition et le
/// dressage se lisent comme la suite de la recette — et qu'on puisse les
/// replier, comme les ingrédients et la préparation au-dessus d'elles : quatre
/// sections dépliées sur un téléphone, c'est un écran qu'on parcourt au pouce.
class _MobileSection extends StatefulWidget {
  final IconData icon;
  final String title;
  final Widget child;

  const _MobileSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  @override
  State<_MobileSection> createState() => _MobileSectionState();
}

class _MobileSectionState extends State<_MobileSection> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CooklangSectionHeader(
              icon: widget.icon,
              title: widget.title,
              expanded: _expanded,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            if (_expanded) ...[
              const SizedBox(height: 4),
              widget.child,
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}
