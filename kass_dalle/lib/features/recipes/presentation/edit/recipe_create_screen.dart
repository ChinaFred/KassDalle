import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import 'ingredient_list_editor.dart';
import 'recipe_form_mixin.dart';
import 'recipe_meta_panel.dart';
import '../ai/ai_ui_copy.dart';
import '../editor/hybrid_recipe_editor.dart';
import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/services/gemini_providers.dart';

/// Manual recipe creation screen (no AI/scan source).
///
/// The user enters CookLang content and metadata directly. On save the recipe
/// is stored as a draft and the user is taken to the draft review screen.
/// On "Créer et valider" the recipe is immediately validated and the user is
/// taken to the detail view.
///
/// When [initialBookId] is provided the book is pre-selected (used when the
/// user taps "Saisie manuelle" from within a book's recipe list).
class RecipeCreateScreen extends ConsumerStatefulWidget {
  final String? initialBookId;
  final String? initialBookTitre;

  const RecipeCreateScreen({
    super.key,
    this.initialBookId,
    this.initialBookTitre,
  });

  @override
  ConsumerState<RecipeCreateScreen> createState() => _RecipeCreateScreenState();
}

class _RecipeCreateScreenState extends ConsumerState<RecipeCreateScreen>
    with RecipeFormMixin<RecipeCreateScreen> {
  bool _aiProcessing = false;

  /// Texte original collé par l'utilisateur avant la mise en forme IA.
  /// Sauvegardé dans Firebase Storage lors du premier enregistrement.
  String? _originalPastedText;
  String? _sourceFileUrl;
  String? _sourceFileName;

  @override
  void initState() {
    super.initState();
    formInitialized = true;
    // Pre-select book when navigating from a book's recipe list.
    if (widget.initialBookId != null) {
      setBook(widget.initialBookId, widget.initialBookTitre);
    }
  }

  Future<void> _processWithAI() async {
    final text = cooklangCtrl.text.trim();
    if (text.isEmpty) {
      context.showSnackBar('Saisissez du texte avant de lancer l\'IA');
      return;
    }
    setState(() => _aiProcessing = true);
    try {
      // Sauvegarde le texte original avant transformation
      _originalPastedText ??= text;

      final cooklang = await ref
          .read(geminiServiceProvider)
          .extractRecipeFromText(text);
      if (!mounted) return;
      if (cooklang == null) {
        context.showSnackBar('L\'IA n\'a pas trouvé de recette dans ce texte');
        return;
      }
      // Update CookLang editor
      cooklangCtrl.text = cooklang;
      // Populate form fields from extracted meta
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
      // Extract structured ingredients
      setIngredients(extractIngredientsStructured(cooklang));
      if (mounted) {
        context.showSuccessSnackBar(RecipeAiUiCopy.successRecipeTransformed);
      }
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Erreur IA : $e');
    } finally {
      if (mounted) setState(() => _aiProcessing = false);
    }
  }

  /// Upload le texte original comme .txt sur Firebase Storage.
  /// Retourne (url, filename) ou null si déjà uploadé ou si pas de texte.
  Future<(String, String)?> _uploadOriginalText(String uid) async {
    if (_sourceFileUrl != null) return (_sourceFileUrl!, _sourceFileName!);
    final text = _originalPastedText;
    if (text == null || text.isEmpty) return null;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final filename = 'texte_colle_$ts.txt';
      final url = await ref
          .read(recipeRepositoryProvider)
          .uploadScanFile(
            uid,
            utf8.encode(text),
            filename,
            'text/plain; charset=utf-8',
          );
      _sourceFileUrl = url;
      _sourceFileName = filename;
      return (url, filename);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveDraft() async {
    final titre = titleCtrl.text.trim();
    if (titre.isEmpty) {
      context.showSnackBar('Le titre est obligatoire');
      return;
    }
    setSaving(true);
    final synced = syncAllMetaFields(cooklangCtrl.text);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final now = DateTime.now();
      final source = await _uploadOriginalText(uid);
      final recipe = Recipe(
        id: '',
        titre: titre,
        bookId: selectedBookId,
        bookTitre: selectedBookTitre,
        pageNumber: int.tryParse(pageNumberCtrl.text.trim()),
        langue: 'fr',
        rawCooklang: synced,
        imageUrls: const [],
        reviewStatus: ReviewStatus.draft,
        tags: buildTagsFromForm(
          RecipeTags(themes: const [], cuisines: const [], occasions: const []),
        ),
        ingredientsIndex: formIngredients.map((i) => i.name).toList(),
        createdBy: uid,
        createdAt: now,
        updatedAt: now,
        portions: int.tryParse(portionsCtrl.text.trim()),
        ingredients: formIngredients,
        sourceFileUrl: source?.$1,
        sourceFileName: source?.$2,
        aiProcessedAt: _originalPastedText != null ? now : null,
      );
      final id = await ref.read(recipeRepositoryProvider).createRecipe(recipe);
      if (mounted) {
        context.go('/drafts/$id');
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setSaving(false);
    }
  }

  Future<void> _saveAndValidate() async {
    final titre = titleCtrl.text.trim();
    if (titre.isEmpty) {
      context.showSnackBar('Le titre est obligatoire');
      return;
    }
    if (cooklangCtrl.text.trim().isEmpty) {
      context.showSnackBar('Le contenu CookLang est vide');
      return;
    }
    setSaving(true);
    final synced = syncAllMetaFields(cooklangCtrl.text);
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      final now = DateTime.now();
      final source = await _uploadOriginalText(uid);
      final recipe = Recipe(
        id: '',
        titre: titre,
        bookId: selectedBookId,
        bookTitre: selectedBookTitre,
        pageNumber: int.tryParse(pageNumberCtrl.text.trim()),
        langue: 'fr',
        rawCooklang: synced,
        imageUrls: const [],
        reviewStatus: ReviewStatus.validated,
        tags: buildTagsFromForm(
          RecipeTags(themes: const [], cuisines: const [], occasions: const []),
        ),
        ingredientsIndex: formIngredients.map((i) => i.name).toList(),
        createdBy: uid,
        createdAt: now,
        updatedAt: now,
        portions: int.tryParse(portionsCtrl.text.trim()),
        ingredients: formIngredients,
        sourceFileUrl: source?.$1,
        sourceFileName: source?.$2,
        aiProcessedAt: _originalPastedText != null ? now : null,
      );
      final id = await ref.read(recipeRepositoryProvider).createRecipe(recipe);
      if (mounted) {
        context.showSuccessSnackBar('Recette créée !');
        context.go('/recipes/$id');
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setSaving(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 800;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nouvelle recette'),
        actions: [
          TextButton.icon(
            onPressed: saving ? null : _saveDraft,
            icon: saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Brouillon'),
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: saving ? null : _saveAndValidate,
            icon: const Icon(Icons.check),
            label: const Text('Créer et valider'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: isWide ? _buildWide() : _buildNarrow(),
      ),
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
            length: 2,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'CookLang'),
                    Tab(text: 'Ingrédients'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      HybridRecipeEditor(
                        ctrl: cooklangCtrl,
                        enabled: !saving && !_aiProcessing,
                        showHelp: true,
                        onProcessWithAI: _processWithAI,
                        aiTooltip: RecipeAiUiCopy.cooklangTransformTooltip,
                        aiProcessing: _aiProcessing,
                        previewWidget: CooklangPreview(
                          ctrl: cooklangCtrl,
                          overrideIngredients: formIngredients,
                        ),
                      ),
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
      length: 3,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Informations'),
              Tab(text: 'CookLang'),
              Tab(text: 'Ingrédients'),
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
                HybridRecipeEditor(
                  ctrl: cooklangCtrl,
                  enabled: !saving && !_aiProcessing,
                  showHelp: true,
                  onProcessWithAI: _processWithAI,
                  aiTooltip: RecipeAiUiCopy.cooklangTransformTooltip,
                  aiProcessing: _aiProcessing,
                  previewWidget: CooklangPreview(
                    ctrl: cooklangCtrl,
                    overrideIngredients: formIngredients,
                  ),
                ),
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
