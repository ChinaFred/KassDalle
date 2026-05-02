import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import 'ingredient_list_editor.dart';
import 'recipe_form_mixin.dart';
import 'recipe_meta_panel.dart';
import 'recipe_cooklang_editor.dart';

class RecipeEditScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const RecipeEditScreen({super.key, required this.recipeId});

  @override
  ConsumerState<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _RecipeEditScreenState extends ConsumerState<RecipeEditScreen>
    with RecipeFormMixin<RecipeEditScreen> {
  Future<void> _save(Recipe recipe) async {
    final titre = titleCtrl.text.trim();
    if (titre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le titre est obligatoire')),
      );
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
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Recette mise a jour')));
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur : $e')));
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

        return Scaffold(
          appBar: AppBar(
            title: const Text('Modifier la recette'),
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
            child: isWide ? _buildWide() : _buildNarrow(),
          ),
        );
      },
    );
  }

  Widget _buildWide() {
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
                    Tab(text: 'CookLang'),
                    Tab(text: 'Apercu'),
                    Tab(text: 'Ingredients'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      RecipeCooklangEditor(
                        ctrl: cooklangCtrl,
                        enabled: !saving,
                      ),
                      CooklangPreview(ctrl: cooklangCtrl),
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

  Widget _buildNarrow() {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Informations'),
              Tab(text: 'CookLang'),
              Tab(text: 'Apercu'),
              Tab(text: 'Ingredients'),
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
                  ),
                ),
                RecipeCooklangEditor(
                  ctrl: cooklangCtrl,
                  enabled: !saving,
                ),
                CooklangPreview(ctrl: cooklangCtrl),
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