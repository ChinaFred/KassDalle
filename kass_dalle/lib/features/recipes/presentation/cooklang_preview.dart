import 'package:flutter/material.dart';
import '../../../core/utils/recipe_portion_scaler.dart';
import '../../../core/utils/recipe_tag_sections.dart';
import '../domain/recipe.dart';
import 'cooklang_preview_model.dart';
import 'cooklang_preview_sections.dart';
import 'cooklang_preview_steps.dart';
import '../../../core/theme/app_icon_size.dart';

/// Widget d'aperçu CookLang — partagé entre DraftReviewScreen et l'ecran detail recette.
///
/// Quand [overrideIngredients] est fourni et non vide, la section "Ingrédients"
/// utilise ces données structurées plutôt que celles extraites du texte CookLang.
/// Cela permet de refléter immédiatement les modifications faites dans l'éditeur
/// structuré sans avoir à modifier le texte CookLang.
///
/// [illustrationUrls] : URLs des illustrations de la recette.
/// [onAddIllustration] : callback pour ajouter une illustration (null → bouton masqué).
/// [onTapIllustration] : callback appelé avec l'index cliqué pour la visionneuse.
class CooklangPreview extends StatefulWidget {
  final TextEditingController ctrl;
  final Widget? topContent;
  final Widget? bottomContent;

  /// Liste d'ingrédients structurés à utiliser pour l'affichage.
  /// Quand null ou vide, les ingrédients sont extraits du texte CookLang.
  final List<RecipeIngredient>? overrideIngredients;

  /// URLs des illustrations attachées à la recette.
  final List<String>? illustrationUrls;

  /// Callback pour déclencher l'ajout d'une illustration.
  final VoidCallback? onAddIllustration;

  /// Callback appelé avec l'index de la miniature cliquée.
  final void Function(int index)? onTapIllustration;

  /// Callback appelé avec l'URL de la miniature à supprimer.
  final void Function(String url)? onDeleteIllustration;

  /// Callback optionnel pour déclencher la création de la liste de courses.
  /// Si null, le bouton n'est pas affiché dans la section ingrédients.
  final VoidCallback? onCreateShoppingList;

  /// Callback optionnel pour planifier la recette dans Google Calendar.
  /// Si null, le bouton calendrier n'est pas affiché.
  final VoidCallback? onSchedule;

  /// Types de plat à afficher (viande, dessert, etc.)
  /// Optionnel — si null ou vide, la section n'est pas affichée.
  /// Déprécié: préférer [recipeTags] pour afficher la catégorisation complète.
  final List<String>? dishTypes;

  /// Tags recette complets pour afficher la catégorisation uniforme
  /// (Cuisine, Type de plat, Thème, Occasion).
  final RecipeTags? recipeTags;

  /// Portions source (recette originale) pour calculer le coefficient.
  final int? basePortions;

  /// Portions actuellement affichées (version redimensionnée locale).
  final int? selectedPortions;

  /// Callback de mise à jour des portions affichées.
  final ValueChanged<int>? onSelectedPortionsChanged;

  /// Bornes de saisie/ajustement des portions.
  final int minPortions;
  final int maxPortions;

  const CooklangPreview({
    super.key,
    required this.ctrl,
    this.topContent,
    this.bottomContent,
    this.overrideIngredients,
    this.illustrationUrls,
    this.onAddIllustration,
    this.onTapIllustration,
    this.onDeleteIllustration,
    this.onCreateShoppingList,
    this.onSchedule,
    this.recipeTags,
    this.dishTypes,
    this.basePortions,
    this.selectedPortions,
    this.onSelectedPortionsChanged,
    this.minPortions = 1,
    this.maxPortions = 99,
  });

  @override
  State<CooklangPreview> createState() => _CooklangPreviewState();
}

class _CooklangPreviewState extends State<CooklangPreview> {
  bool _categorizationExpanded = true;
  bool _ingredientsExpanded = true;
  bool _preparationExpanded = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.ctrl,
      builder: (context, _) => _buildPreview(context, widget.ctrl.text),
    );
  }

  Widget _buildPreview(BuildContext context, String text) {
    if (text.trim().isEmpty) {
      return const Center(child: Text('Aucun contenu à afficher'));
    }

    final overrideIngredients = widget.overrideIngredients;
    final illustrationUrls = widget.illustrationUrls;
    final onAddIllustration = widget.onAddIllustration;
    final onTapIllustration = widget.onTapIllustration;
    final onDeleteIllustration = widget.onDeleteIllustration;
    final onCreateShoppingList = widget.onCreateShoppingList;
    final onSchedule = widget.onSchedule;
    final topContent = widget.topContent;
    final bottomContent = widget.bottomContent;
    final dishTypes = widget.dishTypes;
    final basePortions = widget.basePortions;
    final selectedPortions = widget.selectedPortions;
    final onSelectedPortionsChanged = widget.onSelectedPortionsChanged;
    final tagSections = widget.recipeTags != null
        ? buildRecipeTagSections(widget.recipeTags!)
        : (dishTypes != null && dishTypes.isNotEmpty
              ? buildRecipeTagSections(RecipeTags(dishTypes: dishTypes))
              : const <RecipeTagSection>[]);

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

    // La lecture du texte vit dans `cooklang_preview_model.dart` : elle ne
    // dépend d'aucun contexte de rendu, et se teste sans monter d'écran.
    final model = parseCooklangPreview(text);
    final meta = model.meta;
    final stepGroups = model.stepGroups;
    final steps = model.steps;
    final hasSections = model.hasSections;

    // Liste unifiée pour l'affichage : overrideIngredients si fourni, sinon
    // construit depuis le parsing CookLang (avec catégories de sections).
    final List<RecipeIngredient> displayIngredients =
        (overrideIngredients != null && overrideIngredients.isNotEmpty)
        ? overrideIngredients
        : model.ingredients;

    final scaledDisplayIngredients = scaleRecipeIngredients(
      displayIngredients,
      scaleFactor,
    );

    // Le groupement par catégorie appartient désormais à
    // `CooklangIngredientsList` : c'est lui qui l'affiche, c'est à lui de
    // décider comment.
    final theme = Theme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (topContent != null) ...[topContent, const SizedBox(height: 12)],
          // ── Chips méta + illustrations ────────────────────────────────────
          CooklangMetaRow(
            meta: meta,
            selectedPortions: selectedPortions,
            onSelectedPortionsChanged: onSelectedPortionsChanged,
            minPortions: widget.minPortions,
            maxPortions: widget.maxPortions,
            illustrationUrls: illustrationUrls ?? const <String>[],
            onAddIllustration: onAddIllustration,
            onTapIllustration: onTapIllustration,
            onDeleteIllustration: onDeleteIllustration,
          ),
          if (meta.isNotEmpty) const SizedBox(height: 8),
          if (tagSections.isNotEmpty) ...[
            CooklangSectionHeader(
              icon: Icons.category_outlined,
              title: 'Catégorisation',
              expanded: _categorizationExpanded,
              onTap: () => setState(
                () => _categorizationExpanded = !_categorizationExpanded,
              ),
            ),
            if (_categorizationExpanded)
              CooklangTagSections(sections: tagSections),
            const Divider(height: 16),
          ],
          if (scaledDisplayIngredients.isNotEmpty) ...[
            CooklangSectionHeader(
              icon: Icons.format_list_bulleted,
              title: 'Ingrédients',
              expanded: _ingredientsExpanded,
              onTap: () =>
                  setState(() => _ingredientsExpanded = !_ingredientsExpanded),
              action: (onCreateShoppingList != null || onSchedule != null)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (onSchedule != null)
                          IconButton(
                            onPressed: onSchedule,
                            icon: const Icon(Icons.calendar_month_outlined),
                            tooltip: 'Planifier',
                            iconSize: AppIconSize.small,
                            visualDensity: VisualDensity.compact,
                            color: theme.colorScheme.primary,
                          ),
                        if (onCreateShoppingList != null)
                          IconButton(
                            onPressed: onCreateShoppingList,
                            icon: const Icon(Icons.shopping_cart_outlined),
                            tooltip: 'Liste de courses',
                            iconSize: AppIconSize.small,
                            visualDensity: VisualDensity.compact,
                            color: theme.colorScheme.primary,
                          ),
                      ],
                    )
                  : null,
            ),
            if (_ingredientsExpanded) ...[
              const SizedBox(height: 8),
              CooklangIngredientsList(ingredients: scaledDisplayIngredients),
              // Le bloc « À savoir sur les ingrédients » a été retiré : les
              // notes se lisent maintenant dans la puce, sous l'ingrédient.
              // Les répéter en dessous obligeait à les lire deux fois.
            ], // _ingredientsExpanded
            const Divider(height: 16),
          ],
          if (steps.isNotEmpty) ...[
            CooklangSectionHeader(
              icon: Icons.menu_book_outlined,
              title: 'Préparation',
              expanded: _preparationExpanded,
              onTap: () =>
                  setState(() => _preparationExpanded = !_preparationExpanded),
            ),
            if (_preparationExpanded) ...[
              const SizedBox(height: 8),
              if (hasSections)
                ...cooklangBuildSectionedSteps(
                  context,
                  stepGroups,
                  scaleFactor: scaleFactor,
                )
              else
                ...cooklangBuildFlatSteps(
                  context,
                  steps,
                  scaleFactor: scaleFactor,
                ),
            ], // _preparationExpanded
          ],
          if (bottomContent != null) ...[
            const SizedBox(height: 16),
            bottomContent,
          ],
        ],
      ),
    );
  }
}
