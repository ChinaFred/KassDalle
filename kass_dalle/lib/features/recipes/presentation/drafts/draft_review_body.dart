import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import '../edit/ingredient_list_editor.dart';
import '../edit/recipe_meta_panel.dart';
import '../ai/ai_ui_copy.dart';
import '../editor/hybrid_recipe_editor.dart';
import '../editor/markdown_editor.dart';
import 'draft_illustrations_tab.dart';

/// Données du formulaire et callbacks nécessaires aux layouts de révision.
class DraftReviewFormData {
  // Contrôleurs de formulaire
  final TextEditingController titleCtrl;
  final TextEditingController portionsCtrl;
  final TextEditingController difficultyCtrl;
  final TextEditingController prepTimeCtrl;
  final TextEditingController cookTimeCtrl;
  final TextEditingController restTimeCtrl;
  final TextEditingController pageNumberCtrl;
  final TextEditingController cooklangCtrl;

  // État
  final bool saving;
  final bool aiRefining;
  final int? enhancingAiIndex;
  final String? selectedBookId;
  final List<String> selectedCuisines;
  final List<String> selectedDishTypes;
  final String? selectedMealRole;
  final String? selectedMainProtein;
  final String? selectedMainStarch;
  final bool suggestingTags;
  final List<RecipeIngredient> formIngredients;

  // Callbacks
  final void Function(String?, String?) onBookChanged;
  final void Function(List<String>) onCuisinesChanged;
  final void Function(List<String>) onDishTypesChanged;
  final void Function(String?) onMealRoleChanged;
  final void Function(String?) onMainProteinChanged;
  final void Function(String?) onMainStarchChanged;
  final VoidCallback? onSuggestTags;
  final void Function(List<RecipeIngredient>) onIngredientsChanged;
  final Future<String?> Function(Uint8List, String)? onUploadImage;
  final VoidCallback onExtractIllustrations;
  final VoidCallback? onExtractFromOriginal;
  final void Function(int, EnhancerMode)? onEnhanceIllustration;
  final void Function(int)? onEnhanceAi;
  final VoidCallback onShowRefineDialog;
  final void Function(List<String>, int) onShowGallery;
  final void Function(String)? onDeleteIllustration;
  final PageType pageType;
  final void Function(PageType)? onPageTypeChanged;

  const DraftReviewFormData({
    required this.titleCtrl,
    required this.portionsCtrl,
    required this.difficultyCtrl,
    required this.prepTimeCtrl,
    required this.cookTimeCtrl,
    required this.restTimeCtrl,
    required this.pageNumberCtrl,
    required this.cooklangCtrl,
    required this.saving,
    required this.aiRefining,
    required this.enhancingAiIndex,
    required this.selectedBookId,
    required this.selectedCuisines,
    required this.selectedDishTypes,
    required this.selectedMealRole,
    required this.selectedMainProtein,
    required this.selectedMainStarch,
    required this.suggestingTags,
    required this.formIngredients,
    required this.onBookChanged,
    required this.onCuisinesChanged,
    required this.onDishTypesChanged,
    required this.onMealRoleChanged,
    required this.onMainProteinChanged,
    required this.onMainStarchChanged,
    this.onSuggestTags,
    required this.onIngredientsChanged,
    this.onUploadImage,
    required this.onExtractIllustrations,
    required this.onExtractFromOriginal,
    required this.onEnhanceIllustration,
    required this.onEnhanceAi,
    required this.onShowRefineDialog,
    required this.onShowGallery,
    required this.onDeleteIllustration,
    required this.pageType,
    this.onPageTypeChanged,
  });
}

// ── Layout large (≥800px) ─────────────────────────────────────────────────────

class DraftReviewWideBody extends StatelessWidget {
  final Recipe recipe;
  final bool isOwner;
  final bool isAdmin;
  final DraftReviewFormData data;

  const DraftReviewWideBody({
    super.key,
    required this.recipe,
    required this.isOwner,
    required this.isAdmin,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    // Page non-recette : vue simplifiée (Markdown + Photos)
    if (recipe.pageType != PageType.recipe) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: RecipeMetaPanel(
                titleCtrl: data.titleCtrl,
                portionsCtrl: data.portionsCtrl,
                difficultyCtrl: data.difficultyCtrl,
                prepTimeCtrl: data.prepTimeCtrl,
                cookTimeCtrl: data.cookTimeCtrl,
                restTimeCtrl: data.restTimeCtrl,
                pageNumberCtrl: data.pageNumberCtrl,
                saving: data.saving,
                selectedBookId: data.selectedBookId,
                onBookChanged: data.onBookChanged,
                recipe: recipe,
                cuisines: data.selectedCuisines,
                onCuisinesChanged: data.onCuisinesChanged,
                dishTypes: data.selectedDishTypes,
                onDishTypesChanged: data.onDishTypesChanged,
                mealRole: data.selectedMealRole,
                onMealRoleChanged: data.onMealRoleChanged,
                mainProtein: data.selectedMainProtein,
                onMainProteinChanged: data.onMainProteinChanged,
                mainStarch: data.selectedMainStarch,
                onMainStarchChanged: data.onMainStarchChanged,
                suggestingTags: data.suggestingTags,
                onSuggestTags: data.onSuggestTags,
                pageType: data.pageType,
                onPageTypeChanged: data.onPageTypeChanged,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(text: 'Éditeur'),
                      Tab(text: 'Photos'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        MarkdownEditor(
                          ctrl: data.cooklangCtrl,
                          enabled: !data.saving && !data.aiRefining,
                          illustrationUrls: recipe.imageUrls,
                          onUploadImage: data.onUploadImage,
                        ),
                        _illustrationsTab(isOwner: isOwner, isAdmin: isAdmin),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    // Recette : Métadonnées + Éditeur + Ingrédients + Photos
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: RecipeMetaPanel(
              titleCtrl: data.titleCtrl,
              portionsCtrl: data.portionsCtrl,
              difficultyCtrl: data.difficultyCtrl,
              prepTimeCtrl: data.prepTimeCtrl,
              cookTimeCtrl: data.cookTimeCtrl,
              restTimeCtrl: data.restTimeCtrl,
              pageNumberCtrl: data.pageNumberCtrl,
              saving: data.saving,
              selectedBookId: data.selectedBookId,
              onBookChanged: data.onBookChanged,
              recipe: recipe,
              cuisines: data.selectedCuisines,
              onCuisinesChanged: data.onCuisinesChanged,
              dishTypes: data.selectedDishTypes,
              onDishTypesChanged: data.onDishTypesChanged,
              mealRole: data.selectedMealRole,
              onMealRoleChanged: data.onMealRoleChanged,
              mainProtein: data.selectedMainProtein,
              onMainProteinChanged: data.onMainProteinChanged,
              mainStarch: data.selectedMainStarch,
              onMainStarchChanged: data.onMainStarchChanged,
              suggestingTags: data.suggestingTags,
              onSuggestTags: data.onSuggestTags,
              pageType: data.pageType,
              onPageTypeChanged: data.onPageTypeChanged,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: DefaultTabController(
            length: 3,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'Ingrédients'),
                    Tab(text: 'Recette'),
                    Tab(text: 'Photos'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: IngredientListEditor(
                          initialIngredients: data.formIngredients,
                          enabled: !data.saving,
                          onChanged: data.onIngredientsChanged,
                        ),
                      ),
                      HybridRecipeEditor(
                        ctrl: data.cooklangCtrl,
                        enabled: !data.saving && !data.aiRefining,
                        showHelp: true,
                        illustrationUrls: recipe.imageUrls,
                        onProcessWithAI: data.onShowRefineDialog,
                        aiTooltip: RecipeAiUiCopy.cooklangRefineTooltip,
                        aiProcessing: data.aiRefining,
                        onUploadImage: data.onUploadImage,
                        startInPreview: true,
                        previewWidget: CooklangPreview(
                          ctrl: data.cooklangCtrl,
                          overrideIngredients: data.formIngredients,
                          illustrationUrls: recipe.imageUrls.isNotEmpty
                              ? recipe.imageUrls
                              : null,
                          onTapIllustration: recipe.imageUrls.isNotEmpty
                              ? (i) => data.onShowGallery(recipe.imageUrls, i)
                              : null,
                          onDeleteIllustration: isOwner
                              ? data.onDeleteIllustration
                              : null,
                        ),
                      ),
                      _illustrationsTab(isOwner: isOwner, isAdmin: isAdmin),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  DraftIllustrationsTab _illustrationsTab({
    required bool isOwner,
    required bool isAdmin,
  }) {
    return DraftIllustrationsTab(
      recipe: recipe,
      isOwner: isOwner,
      aiRefining: data.aiRefining,
      saving: data.saving,
      onUploadImage: data.onUploadImage,
      onShowGallery: data.onShowGallery,
      onExtract: data.onExtractIllustrations,
      onExtractFromOriginal: isOwner ? data.onExtractFromOriginal : null,
      onEdit: isOwner
          ? (i) => data.onEnhanceIllustration?.call(i, EnhancerMode.studio)
          : null,
      onEnhance: (isOwner && isAdmin) ? data.onEnhanceAi : null,
      enhancingIndex: data.enhancingAiIndex,
    );
  }
}

// ── Layout étroit (<800px) ────────────────────────────────────────────────────

class DraftReviewNarrowBody extends StatelessWidget {
  final Recipe recipe;
  final bool isOwner;
  final bool isAdmin;
  final DraftReviewFormData data;

  const DraftReviewNarrowBody({
    super.key,
    required this.recipe,
    required this.isOwner,
    required this.isAdmin,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    // Page non-recette : Informations / Éditeur / Photos
    if (recipe.pageType != PageType.recipe) {
      return DefaultTabController(
        length: 3,
        child: Column(
          children: [
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(text: 'Informations'),
                Tab(text: 'Éditeur'),
                Tab(text: 'Photos'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 16),
                    child: _metaPanel(),
                  ),
                  MarkdownEditor(
                    ctrl: data.cooklangCtrl,
                    enabled: !data.saving && !data.aiRefining,
                    illustrationUrls: recipe.imageUrls,
                    onUploadImage: data.onUploadImage,
                  ),
                  _illustrationsTab(isOwner: isOwner, isAdmin: isAdmin),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Recette : Informations / Ingrédients / Recette / Photos
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Informations'),
              Tab(text: 'Ingrédients'),
              Tab(text: 'Recette'),
              Tab(text: 'Photos'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 16),
                  child: _metaPanel(),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: data.formIngredients,
                    enabled: !data.saving,
                    onChanged: data.onIngredientsChanged,
                  ),
                ),
                HybridRecipeEditor(
                  ctrl: data.cooklangCtrl,
                  enabled: !data.saving && !data.aiRefining,
                  showHelp: true,
                  illustrationUrls: recipe.imageUrls,
                  onProcessWithAI: data.onShowRefineDialog,
                  aiTooltip: RecipeAiUiCopy.cooklangRefineTooltip,
                  aiProcessing: data.aiRefining,
                  onUploadImage: data.onUploadImage,
                  startInPreview: true,
                  previewWidget: CooklangPreview(
                    ctrl: data.cooklangCtrl,
                    overrideIngredients: data.formIngredients,
                    illustrationUrls: recipe.imageUrls.isNotEmpty
                        ? recipe.imageUrls
                        : null,
                    onTapIllustration: recipe.imageUrls.isNotEmpty
                        ? (i) => data.onShowGallery(recipe.imageUrls, i)
                        : null,
                    onDeleteIllustration: isOwner
                        ? data.onDeleteIllustration
                        : null,
                  ),
                ),
                _illustrationsTab(isOwner: isOwner, isAdmin: isAdmin),
              ],
            ),
          ),
        ],
      ),
    );
  }

  RecipeMetaPanel _metaPanel() => RecipeMetaPanel(
    titleCtrl: data.titleCtrl,
    portionsCtrl: data.portionsCtrl,
    difficultyCtrl: data.difficultyCtrl,
    prepTimeCtrl: data.prepTimeCtrl,
    cookTimeCtrl: data.cookTimeCtrl,
    restTimeCtrl: data.restTimeCtrl,
    pageNumberCtrl: data.pageNumberCtrl,
    saving: data.saving,
    selectedBookId: data.selectedBookId,
    onBookChanged: data.onBookChanged,
    recipe: recipe,
    cuisines: data.selectedCuisines,
    onCuisinesChanged: data.onCuisinesChanged,
    dishTypes: data.selectedDishTypes,
    onDishTypesChanged: data.onDishTypesChanged,
    mealRole: data.selectedMealRole,
    onMealRoleChanged: data.onMealRoleChanged,
    mainProtein: data.selectedMainProtein,
    onMainProteinChanged: data.onMainProteinChanged,
    mainStarch: data.selectedMainStarch,
    onMainStarchChanged: data.onMainStarchChanged,
    suggestingTags: data.suggestingTags,
    onSuggestTags: data.onSuggestTags,
    pageType: data.pageType,
    onPageTypeChanged: data.onPageTypeChanged,
  );

  DraftIllustrationsTab _illustrationsTab({
    required bool isOwner,
    required bool isAdmin,
  }) {
    return DraftIllustrationsTab(
      recipe: recipe,
      isOwner: isOwner,
      aiRefining: data.aiRefining,
      saving: data.saving,
      onUploadImage: data.onUploadImage,
      onShowGallery: data.onShowGallery,
      onExtract: data.onExtractIllustrations,
      onExtractFromOriginal: isOwner ? data.onExtractFromOriginal : null,
      onEdit: isOwner
          ? (i) => data.onEnhanceIllustration?.call(i, EnhancerMode.studio)
          : null,
      onEnhance: (isOwner && isAdmin) ? data.onEnhanceAi : null,
      enhancingIndex: data.enhancingAiIndex,
    );
  }
}
