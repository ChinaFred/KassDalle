import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/cooklang_preview.dart';
import '../../recipes/presentation/edit/ingredient_list_editor.dart';
import '../../recipes/presentation/editor/hybrid_recipe_editor.dart';
import '../../recipes/presentation/edit/recipe_form_mixin.dart';
import '../../recipes/presentation/edit/recipe_meta_panel.dart';
import '../../../core/services/gemini_providers.dart';
import 'search_providers.dart';
import '../../../core/utils/context_extensions.dart';

// ── Écran de prévisualisation de la recette générée par l'IA ──────────────────

class GeneratedRecipeScreen extends ConsumerStatefulWidget {
  final Recipe recipe;
  final Future<String> Function(Recipe) onSave;
  final VoidCallback onSaved;
  final VoidCallback onCancel;

  const GeneratedRecipeScreen({
    super.key,
    required this.recipe,
    required this.onSave,
    required this.onSaved,
    required this.onCancel,
  });

  @override
  ConsumerState<GeneratedRecipeScreen> createState() =>
      _GeneratedRecipeScreenState();
}

class _GeneratedRecipeScreenState extends ConsumerState<GeneratedRecipeScreen>
    with RecipeFormMixin<GeneratedRecipeScreen> {
  bool _saving = false;
  bool _refining = false;
  late Recipe _currentRecipe;
  final _refineCtrl = TextEditingController();
  List<String>? _refineDiff;

  @override
  void initState() {
    super.initState();
    _currentRecipe = widget.recipe;
    initFormFromRecipe(widget.recipe);
  }

  @override
  void dispose() {
    _refineCtrl.dispose();
    super.dispose();
  }

  Recipe _buildCurrentRecipe() => Recipe(
    id: '',
    titre: titleCtrl.text.trim().isEmpty
        ? _currentRecipe.titre
        : titleCtrl.text.trim(),
    langue: _currentRecipe.langue,
    rawCooklang: cooklangCtrl.text,
    imageUrls: const [],
    reviewStatus: ReviewStatus.draft,
    tags: _currentRecipe.tags.copyWith(
      difficulty: difficultyCtrl.text.trim().isEmpty
          ? null
          : difficultyCtrl.text.trim(),
      prepTime: int.tryParse(prepTimeCtrl.text.trim()),
      cookTime: int.tryParse(cookTimeCtrl.text.trim()),
    ),
    ingredientsIndex: formIngredients.map((i) => i.name).toList(),
    createdBy: '',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    portions: int.tryParse(portionsCtrl.text.trim()),
    ingredients: formIngredients,
    bookId: selectedBookId,
    bookTitre: selectedBookTitre,
  );

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final id = await widget.onSave(_buildCurrentRecipe());
      if (mounted) {
        context.showSuccessSnackBar('Recette créée et validée !');
        widget.onSaved();
        Navigator.of(context).pop();
        context.go('${AppRoutes.recipes}/$id');
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _refine() async {
    final instruction = _refineCtrl.text.trim();
    if (instruction.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _refining = true);
    try {
      final gemini = ref.read(geminiServiceProvider);
      final raw = await gemini.refineRecipe(
        currentTitre: titleCtrl.text.trim().isEmpty
            ? _currentRecipe.titre
            : titleCtrl.text.trim(),
        currentCooklang: cooklangCtrl.text,
        currentIngredients: formIngredients
            .map((i) => {'name': i.name, 'qty': i.qty, 'unit': i.unit})
            .toList(),
        currentTags: {
          'themes': _currentRecipe.tags.themes,
          'cuisines': _currentRecipe.tags.cuisines,
          'difficulty': _currentRecipe.tags.difficulty,
          'prep_time': _currentRecipe.tags.prepTime,
          'cook_time': _currentRecipe.tags.cookTime,
        },
        currentPortions:
            int.tryParse(portionsCtrl.text.trim()) ?? _currentRecipe.portions,
        instruction: instruction,
      );

      final titre = raw['titre'] as String? ?? _currentRecipe.titre;
      final langue = raw['langue'] as String? ?? _currentRecipe.langue;
      final cooklang = raw['cooklang'] as String? ?? '';
      final ingredientsIndex = List<String>.from(
        raw['ingredients_index'] as List? ?? [],
      );
      final ingredientsRaw = raw['ingredients'] as List? ?? [];
      final ingredients = ingredientsRaw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return RecipeIngredient(
          name: m['name'] as String? ?? '',
          qty: m['qty'] as String? ?? '',
          unit: m['unit'] as String? ?? '',
        );
      }).toList();
      final tagsRaw = Map<String, dynamic>.from(raw['tags'] as Map? ?? {});
      final tags = RecipeTags(
        themes: List<String>.from(tagsRaw['themes'] as List? ?? []),
        cuisines: List<String>.from(tagsRaw['cuisines'] as List? ?? []),
        occasions: List<String>.from(tagsRaw['occasions'] as List? ?? []),
        dishTypes: List<String>.from(tagsRaw['dish_types'] as List? ?? []),
        difficulty: tagsRaw['difficulty'] as String?,
        prepTime: _toInt(tagsRaw['prep_time']),
        cookTime: _toInt(tagsRaw['cook_time']),
      );
      final portions = _toInt(raw['portions']);

      final refined = Recipe(
        id: '',
        titre: titre,
        langue: langue,
        rawCooklang: cooklang,
        imageUrls: const [],
        reviewStatus: ReviewStatus.draft,
        tags: tags,
        ingredientsIndex: ingredientsIndex,
        createdBy: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        portions: portions,
        ingredients: ingredients,
      );

      // Capturer l'état avant les modifications pour le diff
      final oldTitle = titleCtrl.text.trim();
      final oldCooklang = cooklangCtrl.text;
      final oldPortions = int.tryParse(portionsCtrl.text.trim());
      final oldDifficulty = difficultyCtrl.text.trim().isEmpty ? null : difficultyCtrl.text.trim();
      final oldPrepTime = int.tryParse(prepTimeCtrl.text.trim());
      final oldCookTime = int.tryParse(cookTimeCtrl.text.trim());
      final oldIngredientNames = formIngredients.map((i) => i.name.toLowerCase()).toSet();

      titleCtrl.text = refined.titre;
      cooklangCtrl.text = refined.rawCooklang;
      portionsCtrl.text = refined.portions?.toString() ?? '';
      difficultyCtrl.text = refined.tags.difficulty ?? '';
      prepTimeCtrl.text = refined.tags.prepTime?.toString() ?? '';
      cookTimeCtrl.text = refined.tags.cookTime?.toString() ?? '';

      // Calculer le diff
      final diffs = <String>[];
      final newTitle = refined.titre.trim();
      if (newTitle != oldTitle) diffs.add('Titre : "$oldTitle" → "$newTitle"');
      if (refined.rawCooklang != oldCooklang) diffs.add('Contenu de la recette modifié');
      final newIngredientNames = refined.ingredients.map((i) => i.name.toLowerCase()).toSet();
      final added = newIngredientNames.difference(oldIngredientNames);
      final removed = oldIngredientNames.difference(newIngredientNames);
      if (added.isNotEmpty) {
        final preview = added.take(3).join(', ');
        diffs.add('Ingrédient(s) ajouté(s) : $preview${added.length > 3 ? '…' : ''}');
      }
      if (removed.isNotEmpty) {
        final preview = removed.take(3).join(', ');
        diffs.add('Ingrédient(s) supprimé(s) : $preview${removed.length > 3 ? '…' : ''}');
      }
      if (refined.portions != oldPortions) diffs.add('Portions : ${oldPortions ?? '—'} → ${refined.portions ?? '—'}');
      if (refined.tags.difficulty != oldDifficulty) diffs.add('Difficulté : ${oldDifficulty ?? '—'} → ${refined.tags.difficulty ?? '—'}');
      if (refined.tags.prepTime != oldPrepTime) diffs.add('Préparation : ${oldPrepTime != null ? '${oldPrepTime}min' : '—'} → ${refined.tags.prepTime != null ? '${refined.tags.prepTime}min' : '—'}');
      if (refined.tags.cookTime != oldCookTime) diffs.add('Cuisson : ${oldCookTime != null ? '${oldCookTime}min' : '—'} → ${refined.tags.cookTime != null ? '${refined.tags.cookTime}min' : '—'}');

      setState(() {
        _currentRecipe = refined;
        formIngredients = List<RecipeIngredient>.from(refined.ingredients);
        formInitialized = true;
        _refineDiff = diffs.isEmpty ? ['Aucune modification détectée'] : diffs;
      });
      _refineCtrl.clear();
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Erreur lors du raffinement : $e');
      }
    } finally {
      if (mounted) setState(() => _refining = false);
    }
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 800;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          titleCtrl.text.isEmpty ? _currentRecipe.titre : titleCtrl.text,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Retour',
          onPressed: () {
            widget.onCancel(); // reset state AVANT le pop pour éviter le double-push
            Navigator.of(context).pop();
          },
        ),
        actions: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 4),
                Text(
                  'Générée par l\'IA',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: (_saving || _refining) ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Sauvegarder'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          if (_refineDiff != null) _buildDiffBanner(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: isWide ? _buildWide() : _buildNarrow(),
            ),
          ),
          _buildRefineBar(context),
        ],
      ),
    );
  }

  Widget _buildDiffBanner() {
    final theme = Theme.of(context);
    final diffs = _refineDiff ?? [];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.auto_awesome,
            size: 15,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Modifications apportées :',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                ...diffs.map(
                  (d) => Text(
                    '• $d',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            color: theme.colorScheme.onSecondaryContainer,
            onPressed: () => setState(() => _refineDiff = null),
          ),
        ],
      ),
    );
  }

  Widget _buildRefineBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _refining
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'L\'IA modifie la recette…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _refineCtrl,
                    enabled: !_saving,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _refine(),
                    decoration: InputDecoration(
                      hintText:
                          'Modifier la recette… (ex : "rendre végétarienne", "doubler les portions")',
                      hintStyle: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _saving ? null : _refine,
                  icon: const Icon(Icons.send_rounded),
                  tooltip: 'Demander à l\'IA',
                ),
              ],
            ),
    );
  }

  Widget _buildWide() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: RecipeMetaPanel(
              titleCtrl: titleCtrl,
              portionsCtrl: portionsCtrl,
              difficultyCtrl: difficultyCtrl,
              prepTimeCtrl: prepTimeCtrl,
              cookTimeCtrl: cookTimeCtrl,
              pageNumberCtrl: pageNumberCtrl,
              saving: _saving || _refining,
              selectedBookId: null,
              onBookChanged: (_, _) {},
              showBookSelector: false,
              infoBookLabel: "Mes créations Kass'Dalle ✨",
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: _buildTabs()),
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
                    saving: _saving || _refining,
                    selectedBookId: null,
                    onBookChanged: (_, _) {},
                    showBookSelector: false,
                    infoBookLabel: "Mes créations Kass'Dalle ✨",
                  ),
                ),
                HybridRecipeEditor(
                  ctrl: cooklangCtrl,
                  enabled: !_saving && !_refining,
                  showHelp: true,
                  previewWidget: CooklangPreview(
                    ctrl: cooklangCtrl,
                    overrideIngredients: formIngredients,
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !_saving && !_refining,
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

  Widget _buildTabs() {
    return DefaultTabController(
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
                  enabled: !_saving && !_refining,
                  showHelp: true,
                  previewWidget: CooklangPreview(
                    ctrl: cooklangCtrl,
                    overrideIngredients: formIngredients,
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !_saving && !_refining,
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
