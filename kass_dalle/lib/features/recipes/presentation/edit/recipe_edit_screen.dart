import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import 'ingredient_list_editor.dart';
import 'recipe_form_mixin.dart';
import 'recipe_meta_panel.dart';
import '../editor/hybrid_recipe_editor.dart';
import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/services/gemini_service.dart';
import '../../../../features/admin/data/token_usage_repository.dart';
import '../../../../features/admin/presentation/admin_providers.dart';

class RecipeEditScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const RecipeEditScreen({super.key, required this.recipeId});

  @override
  ConsumerState<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _RecipeEditScreenState extends ConsumerState<RecipeEditScreen>
    with RecipeFormMixin<RecipeEditScreen> {
  bool _aiProcessing = false;
  bool _suggestingTags = false;
  Recipe? _currentRecipe;

  Future<void> _suggestTags() async {
    final recipe = _currentRecipe;
    if (recipe == null) return;
    setState(() => _suggestingTags = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final result = await GeminiService(
        '',
        onTokenUsage: TokenUsageRepository.makeCallback(
          uid,
          ref.read(tokenUsageRepositoryProvider),
        ),
      ).suggestRecipeTags(titre: recipe.titre, cooklang: cooklangCtrl.text);
      if (!mounted) return;
      setCuisines(result.cuisines);
      setDishTypes(result.dishTypes);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Tags suggérés par l\'IA ✓'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur IA : $e')));
      }
    } finally {
      if (mounted) setState(() => _suggestingTags = false);
    }
  }

  Future<void> _polishWithAI() async {
    final text = cooklangCtrl.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le contenu CookLang est vide')),
      );
      return;
    }
    setState(() => _aiProcessing = true);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final cooklang = await GeminiService(
        '',
        onTokenUsage: TokenUsageRepository.makeCallback(
          uid,
          ref.read(tokenUsageRepositoryProvider),
        ),
      ).polishCooklang(text);
      if (!mounted) return;
      if (cooklang == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('L\'IA n\'a pas pu corriger la recette'),
          ),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recette corrigée et mise en forme !')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur IA : $e')));
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
    final ts = DateTime.now().millisecondsSinceEpoch;
    final ext = fileName.contains('.') ? fileName.split('.').last : 'jpg';
    final ref = FirebaseStorage.instance.ref(
      'illustrations/$uid/${ts}_editor.$ext',
    );
    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: 'image/$ext'),
    );
    return await task.ref.getDownloadURL();
  }

  Future<void> _save(Recipe recipe) async {
    final titre = titleCtrl.text.trim();
    if (titre.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Le titre est obligatoire')));
      return;
    }
    setSaving(true);
    final syncedCooklang = syncAllMetaFields(cooklangCtrl.text);
    try {
      final updated = recipe.copyWith(
        titre: titre,
        rawCooklang: syncedCooklang,
        portions: int.tryParse(portionsCtrl.text.trim()),
        bookId: selectedBookId,
        bookTitre: selectedBookTitre,
        pageNumber: int.tryParse(pageNumberCtrl.text.trim()),
        tags: buildTagsFromForm(recipe.tags),
        ingredients: formIngredients,
        updatedAt: DateTime.now(),
      );
      await ref.read(recipeRepositoryProvider).updateRecipe(updated);
      ref.invalidate(recipeDetailProvider(widget.recipeId));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recette mise a jour')));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setSaving(false);
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

        return Scaffold(
          appBar: AppBar(
            title: Text(screenTitle),
            actions: [
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
                ? _buildWide(isPage: isPage)
                : _buildNarrow(isPage: isPage),
          ),
        );
      },
    );
  }

  Widget _buildWide({bool isPage = false}) {
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
              suggestingTags: _suggestingTags,
              onSuggestTags: _suggestTags,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: DefaultTabController(
            length: isPage ? 1 : 2,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    const Tab(text: 'Éditeur'),
                    if (!isPage) const Tab(text: 'Ingrédients'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      HybridRecipeEditor(
                        ctrl: cooklangCtrl,
                        enabled: !saving,
                        onProcessWithAI: _polishWithAI,
                        aiTooltip: 'Corriger et mettre en forme via IA',
                        aiProcessing: _aiProcessing,
                        onUploadImage: _uploadImageFromGallery,
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

  Widget _buildNarrow({bool isPage = false}) {
    return DefaultTabController(
      length: isPage ? 2 : 3,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Informations'),
              const Tab(text: 'Éditeur'),
              if (!isPage) const Tab(text: 'Ingrédients'),
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
                    suggestingTags: _suggestingTags,
                    onSuggestTags: _suggestTags,
                  ),
                ),
                HybridRecipeEditor(
                  ctrl: cooklangCtrl,
                  enabled: !saving,
                  onProcessWithAI: _polishWithAI,
                  aiTooltip: 'Corriger et mettre en forme via IA',
                  aiProcessing: _aiProcessing,
                  onUploadImage: _uploadImageFromGallery,
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}
