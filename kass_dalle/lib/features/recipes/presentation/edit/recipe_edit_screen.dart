import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../../data/draft_review_service.dart';
import '../cooklang_preview.dart';
import 'ingredient_list_editor.dart';
import 'recipe_form_mixin.dart';
import 'recipe_meta_panel.dart';
import '../ai/ai_processing_overlay.dart';
import '../ai/ai_ui_copy.dart';
import '../editor/hybrid_recipe_editor.dart';
import '../editor/markdown_editor.dart';
import '../drafts/draft_review_widgets.dart';
import '../detail/recipe_detail_illustrations.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/services/gemini_providers.dart';
import '../../../../core/services/error_reporting.dart';

class RecipeEditScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const RecipeEditScreen({super.key, required this.recipeId});

  @override
  ConsumerState<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _RecipeEditScreenState extends ConsumerState<RecipeEditScreen>
    with RecipeFormMixin<RecipeEditScreen> {
  bool _aiProcessing = false;
  Recipe? _currentRecipe;

  // Enhancer inline pour les illustrations
  Uint8List? _enhancerBytes;
  bool _showingIllEnhancer = false;
  EnhancerMode _enhancerMode = EnhancerMode.studio;
  int?
  _enhancingIndex; // null = ajout depuis source, int = remplacement d'une illustration existante

  Future<void> _polishWithAI() async {
    final text = cooklangCtrl.text.trim();
    if (text.isEmpty) {
      context.showSnackBar('Le contenu CookLang est vide');
      return;
    }
    setState(() => _aiProcessing = true);
    try {
      final cooklang = await ref
          .read(geminiServiceProvider)
          .polishCooklang(text);
      if (!mounted) return;
      if (cooklang == null) {
        context.showSnackBar('L\'IA n\'a pas pu corriger la recette');
        return;
      }
      cooklangCtrl.text = cooklang;
      // Mettre à jour les champs méta depuis le CookLang corrigé
      final meta = parseCooklangMeta(cooklang);
      if ((meta['titre'] ?? '').isNotEmpty) titleCtrl.text = meta['titre']!;
      if ((meta['portions'] ?? '').isNotEmpty) {
        portionsCtrl.text = meta['portions']!.split(' ').first;
      }
      final diff = meta['difficulté'] ?? meta['difficulte'];
      if ((diff ?? '').isNotEmpty) difficultyCtrl.text = diff!;
      final prep =
          meta['temps_préparation'] ??
          meta['temps_preparation'] ??
          meta['prep_time'];
      if ((prep ?? '').isNotEmpty) prepTimeCtrl.text = prep!;
      final cook = meta['temps_cuisson'] ?? meta['cook_time'];
      if ((cook ?? '').isNotEmpty) cookTimeCtrl.text = cook!;
      setIngredients(extractIngredientsStructured(cooklang));
      if (mounted) {
        context.showSuccessSnackBar(RecipeAiUiCopy.successRecipePolished);
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.polishWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Erreur IA : $e');
    } finally {
      if (mounted) setState(() => _aiProcessing = false);
    }
  }

  Future<String?> _uploadImageFromGallery(
    Uint8List bytes,
    String fileName,
  ) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    return await ref
        .read(recipeRepositoryProvider)
        .uploadIllustration(uid, bytes, fileName);
  }

  Future<void> _doExtractIllustrations(Recipe recipe) async {
    final url = recipe.sourceFileUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _aiProcessing = true);
    try {
      final uid = currentUid;
      final gemini = ref.read(geminiServiceProvider);
      final result = await DraftReviewService.extractAndUploadIllustrations(
        sourceUrl: url,
        sourceFileName: recipe.sourceFileName,
        uid: uid,
        gemini: gemini,
      );
      if (!mounted) return;
      if (result.urls.isNotEmpty) {
        await ref
            .read(recipeRepositoryProvider)
            .updateRecipeIllustrations(recipe.id, result.urls);
        if (mounted) {
          context.showSuccessSnackBar(
            '${result.urls.length} illustration(s) extraite(s) ✓',
          );
        }
      } else {
        if (mounted) {
          context.showSuccessSnackBar(
            'Aucune illustration trouvée dans le scan',
          );
        }
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.doExtractIllustrations',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showSnackBar('Erreur extraction : $e');
    } finally {
      if (mounted) setState(() => _aiProcessing = false);
    }
  }

  Future<void> _startExtractFromOriginal(Recipe recipe) async {
    final url = recipe.sourceFileUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _aiProcessing = true);
    try {
      final bytes = await DraftReviewService.downloadImageBytes(url);
      if (bytes == null || !mounted) return;
      setState(() {
        _enhancerBytes = bytes;
        _enhancingIndex = null; // ajout d'une nouvelle illustration
        _showingIllEnhancer = true;
        _enhancerMode = EnhancerMode.studio;
        _aiProcessing = false;
      });
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.startExtractFromOriginal',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _aiProcessing = false);
        context.showSnackBar('Erreur chargement source : $e');
      }
    }
  }

  Future<void> _onEnhanceExistingIllustration(
    Recipe recipe,
    int index,
    EnhancerMode mode,
  ) async {
    if (index >= recipe.imageUrls.length) return;
    setState(() => _aiProcessing = true);
    try {
      final bytes = await DraftReviewService.downloadImageBytes(
        recipe.imageUrls[index],
      );
      if (bytes == null || !mounted) return;
      setState(() {
        _enhancerBytes = bytes;
        _enhancingIndex = index; // remplacement
        _showingIllEnhancer = true;
        _enhancerMode = mode;
        _aiProcessing = false;
      });
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.onEnhanceExistingIllustration',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _aiProcessing = false);
        context.showSnackBar('Erreur chargement image : $e');
      }
    }
  }

  Future<void> _onIllustrationEnhancerResult(
    Recipe recipe,
    Uint8List? result,
  ) async {
    setState(() => _showingIllEnhancer = false);
    if (result == null) return;
    final index = _enhancingIndex; // null = ajout, int = remplacement
    setState(() => _aiProcessing = true);
    try {
      final uid = currentUid;
      final newUrl = await DraftReviewService.uploadEnhancedIllustration(
        uid,
        result,
      );
      final newUrls = List<String>.from(recipe.imageUrls);
      final newThumbs = List<String>.from(recipe.thumbnailUrls);
      if (index != null && index < newUrls.length) {
        newUrls[index] = newUrl; // Remplacement
        if (index < newThumbs.length) {
          newThumbs[index] = newUrl;
        }
      } else {
        newUrls.add(newUrl); // Ajout
        newThumbs.add(newUrl);
      }
      await ref
          .read(recipeRepositoryProvider)
          .updateRecipeIllustrations(
            recipe.id,
            newUrls,
            thumbnailUrls: newThumbs.isEmpty ? null : newThumbs,
          );
      if (mounted) {
        context.showSuccessSnackBar(
          index != null ? 'Photo recadrée ✓' : 'Illustration extraite ✓',
        );
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.onIllustrationEnhancerResult',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showSnackBar('Erreur : $e');
    } finally {
      if (mounted) setState(() => _aiProcessing = false);
    }
  }

  void _showIllustrationGallery(List<String> urls, int startIndex) {
    showDialog<void>(
      context: context,
      builder: (ctx) =>
          IllustrationGallery(urls: urls, initialIndex: startIndex),
    );
  }

  Future<void> _save(Recipe recipe) async {
    final titre = titleCtrl.text.trim();
    if (titre.isEmpty) {
      context.showSnackBar('Le titre est obligatoire');
      return;
    }
    setSaving(true);
    // Pour les pages non-recettes (Markdown pur), ne pas injecter les
    // métadonnées CookLang dans le contenu - elles sont gérées séparément.
    final savedContent = recipe.pageType != PageType.recipe
        ? cooklangCtrl.text.trim()
        : syncAllMetaFields(cooklangCtrl.text);
    try {
      final updated = recipe.copyWith(
        titre: titre,
        rawCooklang: savedContent,
        // Effacer le draftCooklang pour que le détail affiche rawCooklang
        draftCooklang: '',
        portions: int.tryParse(portionsCtrl.text.trim()),
        bookId: selectedBookId,
        bookTitre: selectedBookTitre,
        pageNumber: int.tryParse(pageNumberCtrl.text.trim()),
        tags: buildTagsFromForm(recipe.tags),
        ingredients: formIngredients,
        updatedAt: DateTime.now(),
      );
      await ref
          .read(recipeRepositoryProvider)
          .updateRecipe(
            updated,
            onNormalizationApplied:
                ({
                  required normalizedCooklang,
                  required normalizedIngredients,
                  required renamedUnits,
                  required renamedIngredients,
                }) {
                  cooklangCtrl.text = normalizedCooklang;
                  setIngredients(normalizedIngredients);
                  if (renamedUnits > 0 || renamedIngredients > 0) {
                    context.showSuccessSnackBar(
                      'Normalisation appliquée : '
                      '$renamedIngredients ingrédient(s), $renamedUnits unité(s).',
                    );
                  }
                },
          );
      ref.invalidate(recipeDetailProvider(widget.recipeId));
      ref.invalidate(recipeByIdProvider(widget.recipeId));
      if (mounted) {
        context.showSuccessSnackBar('Recette mise a jour');
        context.pop();
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.save',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setSaving(false);
    }
  }

  Future<void> _delete(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer cette page ?'),
        content: Text('« ${recipe.titre} » sera supprimée définitivement.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setSaving(true);
    final repo = ref.read(recipeRepositoryProvider);
    try {
      await repo.deleteRecipe(recipe.id);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeEditScreen.delete',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setSaving(false);
      context.showErrorSnackBar('Erreur suppression : $e');
      return;
    }
    if (!mounted) return;
    final bookId = recipe.bookId;
    final bookTitre = selectedBookTitre ?? recipe.bookTitre;
    if (bookId != null && bookId.isNotEmpty) {
      final titleParam = bookTitre != null && bookTitre.isNotEmpty
          ? '&bookTitre=${Uri.encodeQueryComponent(bookTitre)}'
          : '';
      context.go('/recipes?bookId=$bookId$titleParam');
    } else {
      context.go('/recipes');
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipeAsync = ref.watch(recipeDetailProvider(widget.recipeId));
    final isWide = MediaQuery.of(context).size.width >= 800;

    return recipeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Erreur')),
        body: Center(child: Text('$e')),
      ),
      data: (recipe) {
        if (recipe == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Recette introuvable')),
          );
        }

        initFormFromRecipe(recipe);
        _currentRecipe = recipe;

        final isPage = recipe.pageType != PageType.recipe;
        final screenTitle = isPage ? 'Modifier la page' : 'Modifier la recette';

        final scaffold = Scaffold(
          appBar: AppBar(
            title: Text(screenTitle),
            actions: [
              if (isPage)
                IconButton(
                  onPressed: saving ? null : () => _delete(recipe),
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Supprimer',
                  color: Theme.of(context).colorScheme.error,
                ),
              FilledButton.icon(
                onPressed: saving ? null : () => _save(recipe),
                icon: saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Enregistrer'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: isWide
                ? _buildWide(recipe, isPage: isPage)
                : _buildNarrow(recipe, isPage: isPage),
          ),
        );

        // Overlay l'enhancer d'image sans démonter le DefaultTabController
        return Stack(
          children: [
            scaffold,
            if (_aiProcessing)
              const AiProcessingOverlay(
                title: RecipeAiUiCopy.processingTitle,
                message: RecipeAiUiCopy.processingMessage,
              ),
            if (_showingIllEnhancer && _enhancerBytes != null)
              Positioned.fill(
                child: ImageEnhancerScreen(
                  imageBytes: _enhancerBytes!,
                  title: _enhancerMode == EnhancerMode.studio
                      ? 'Atelier de retouche'
                      : _enhancerMode == EnhancerMode.crop
                      ? 'Recadrer la photo'
                      : 'Améliorer les couleurs',
                  mode: _enhancerMode,
                  onResult: (result) =>
                      _onIllustrationEnhancerResult(recipe, result),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildWide(Recipe recipe, {bool isPage = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 300,
          child: SingleChildScrollView(
            child: RecipeMetaPanel(
              titleCtrl: titleCtrl,
              portionsCtrl: portionsCtrl,
              difficultyCtrl: difficultyCtrl,
              prepTimeCtrl: prepTimeCtrl,
              cookTimeCtrl: cookTimeCtrl,
              pageNumberCtrl: pageNumberCtrl,
              saving: saving,
              selectedBookId: selectedBookId,
              onBookChanged: setBook,
              cuisines: selectedCuisines,
              onCuisinesChanged: setCuisines,
              dishTypes: selectedDishTypes,
              onDishTypesChanged: setDishTypes,
              suggestingTags: suggestingTags,
              onSuggestTags: () =>
                  suggestTagsWithAI(_currentRecipe?.titre ?? ''),
              pageType: recipe.pageType,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: DefaultTabController(
            length: isPage ? 2 : 3,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    const Tab(text: 'Éditeur'),
                    if (!isPage) const Tab(text: 'Ingrédients'),
                    const Tab(text: 'Photos'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      if (isPage)
                        MarkdownEditor(
                          ctrl: cooklangCtrl,
                          enabled: !saving,
                          illustrationUrls: recipe.imageUrls,
                          onUploadImage: _uploadImageFromGallery,
                        )
                      else
                        HybridRecipeEditor(
                          ctrl: cooklangCtrl,
                          enabled: !saving,
                          onProcessWithAI: _polishWithAI,
                          aiTooltip: RecipeAiUiCopy.cooklangPolishTooltip,
                          aiProcessing: _aiProcessing,
                          onUploadImage: _uploadImageFromGallery,
                          illustrationUrls: recipe.imageUrls,
                          previewWidget: CooklangPreview(
                            ctrl: cooklangCtrl,
                            overrideIngredients: formIngredients,
                          ),
                        ),
                      if (!isPage)
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: IngredientListEditor(
                            initialIngredients: formIngredients,
                            enabled: !saving,
                            onChanged: setIngredients,
                          ),
                        ),
                      DraftIllustrationsTab(
                        recipe: recipe,
                        isOwner: true,
                        aiRefining: _aiProcessing,
                        saving: saving,
                        onUploadImage: _uploadImageFromGallery,
                        onShowGallery: _showIllustrationGallery,
                        onExtract: () => _doExtractIllustrations(recipe),
                        onExtractFromOriginal: recipe.sourceFileUrl != null
                            ? () => _startExtractFromOriginal(recipe)
                            : null,
                        onEdit: (i) => _onEnhanceExistingIllustration(
                          recipe,
                          i,
                          EnhancerMode.studio,
                        ),
                      ),
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

  Widget _buildNarrow(Recipe recipe, {bool isPage = false}) {
    return DefaultTabController(
      length: isPage ? 3 : 4,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Informations'),
              if (!isPage) const Tab(text: 'Ingrédients'),
              if (!isPage)
                const Tab(text: 'Recette')
              else
                const Tab(text: 'Éditeur'),
              const Tab(text: 'Photos'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 16),
                  child: RecipeMetaPanel(
                    titleCtrl: titleCtrl,
                    portionsCtrl: portionsCtrl,
                    difficultyCtrl: difficultyCtrl,
                    prepTimeCtrl: prepTimeCtrl,
                    cookTimeCtrl: cookTimeCtrl,
                    pageNumberCtrl: pageNumberCtrl,
                    saving: saving,
                    selectedBookId: selectedBookId,
                    onBookChanged: setBook,
                    cuisines: selectedCuisines,
                    onCuisinesChanged: setCuisines,
                    dishTypes: selectedDishTypes,
                    onDishTypesChanged: setDishTypes,
                    suggestingTags: suggestingTags,
                    onSuggestTags: () =>
                        suggestTagsWithAI(_currentRecipe?.titre ?? ''),
                    pageType: recipe.pageType,
                  ),
                ),
                if (!isPage)
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: IngredientListEditor(
                      initialIngredients: formIngredients,
                      enabled: !saving,
                      onChanged: setIngredients,
                    ),
                  ),
                if (isPage)
                  MarkdownEditor(
                    ctrl: cooklangCtrl,
                    enabled: !saving,
                    illustrationUrls: recipe.imageUrls,
                    onUploadImage: _uploadImageFromGallery,
                  )
                else
                  HybridRecipeEditor(
                    ctrl: cooklangCtrl,
                    enabled: !saving,
                    onProcessWithAI: _polishWithAI,
                    aiTooltip: RecipeAiUiCopy.cooklangPolishTooltip,
                    aiProcessing: _aiProcessing,
                    onUploadImage: _uploadImageFromGallery,
                    illustrationUrls: recipe.imageUrls,
                    previewWidget: CooklangPreview(
                      ctrl: cooklangCtrl,
                      overrideIngredients: formIngredients,
                    ),
                  ),
                DraftIllustrationsTab(
                  recipe: recipe,
                  isOwner: true,
                  aiRefining: _aiProcessing,
                  saving: saving,
                  onUploadImage: _uploadImageFromGallery,
                  onShowGallery: _showIllustrationGallery,
                  onExtract: () => _doExtractIllustrations(recipe),
                  onExtractFromOriginal: recipe.sourceFileUrl != null
                      ? () => _startExtractFromOriginal(recipe)
                      : null,
                  onEdit: (i) => _onEnhanceExistingIllustration(
                    recipe,
                    i,
                    EnhancerMode.studio,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
