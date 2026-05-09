import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/gemini_service.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/cooklang_preview.dart';
import '../../recipes/presentation/edit/ingredient_list_editor.dart';
import '../../recipes/presentation/edit/recipe_cooklang_editor.dart';
import '../../recipes/presentation/edit/recipe_form_mixin.dart';
import '../../recipes/presentation/edit/recipe_meta_panel.dart';
import '../../recipes/presentation/recipe_rating_widget.dart';
import '../domain/search_models.dart';
import 'search_providers.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  SearchParams _params = const SearchParams();
  bool _searchingWeb = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    ref
        .read(searchNotifierProvider.notifier)
        .search(query: query, params: _params);
  }

  void _generate() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final current = ref.read(searchNotifierProvider);
    final insight =
        current is SearchSuccess ? current.data.preferenceInsight : null;
    ref
        .read(searchNotifierProvider.notifier)
        .generateRecipe(query: query, preferenceInsight: insight);
  }

  Future<void> _searchOnWeb() async {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    setState(() => _searchingWeb = true);
    String optimizedQuery = query;
    try {
      final gemini = ref.read(geminiServiceProvider);
      optimizedQuery = await gemini.generateWebSearchQuery(query);
    } catch (_) {
      // Fallback silencieux : utiliser la query brute
      optimizedQuery = query;
    } finally {
      if (mounted) setState(() => _searchingWeb = false);
    }
    final encoded = Uri.encodeComponent('$optimizedQuery recette');
    final uri = Uri.parse('https://www.google.com/search?q=$encoded');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Recherche')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Filtres ────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Rechercher dans :',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              spacing: 8,
              children: [
                FilterChip(
                  label: const Text('Mes recettes'),
                  selected: _params.myRecipes,
                  onSelected: (v) =>
                      setState(() => _params = _params.copyWith(myRecipes: v)),
                ),
                FilterChip(
                  label: const Text('Recettes famille'),
                  selected: _params.familyRecipes,
                  onSelected: (v) => setState(
                    () => _params = _params.copyWith(familyRecipes: v),
                  ),
                ),
                FilterChip(
                  label: const Text('Inclure brouillons'),
                  selected: _params.includeDrafts,
                  onSelected: (v) => setState(
                    () => _params = _params.copyWith(includeDrafts: v),
                  ),
                ),
              ],
            ),
          ),
          // ── Champ de recherche ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText:
                          'Ex : une tarte aux pommes facile, des recettes avec du poulet…',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    maxLines: 2,
                    minLines: 1,
                  ),
                ),
                const SizedBox(width: 8),
                Builder(builder: (context) {
                  final isWide = MediaQuery.of(context).size.width >= 800;
                  final busy = state is SearchLoading || state is SearchGenerating;
                  if (isWide) {
                    return FilledButton.icon(
                      onPressed: busy ? null : _search,
                      icon: const Icon(Icons.search),
                      label: const Text('Chercher'),
                    );
                  }
                  return IconButton.filled(
                    onPressed: busy ? null : _search,
                    icon: const Icon(Icons.search),
                    tooltip: 'Chercher',
                  );
                }),
              ],
            ),
          ),
          const Divider(height: 1),
          // ── Résultats ──────────────────────────────────────────────────────
          Expanded(
            child: switch (state) {
              SearchIdle() => _buildIdleState(theme),
              SearchLoading() => _buildLoadingState(),
              SearchError(:final message) => _buildErrorState(message),
              SearchSuccess(:final data) => _buildResults(data, theme),
              SearchGenerating() => _buildGeneratingState(),
              SearchGenerated(:final generatedRecipe) =>
                _buildGeneratedWrapper(generatedRecipe),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildIdleState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 64,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Décrivez ce que vous cherchez\nen langage naturel',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Recherche en cours…'),
        ],
      ),
    );
  }

  Widget _buildErrorState(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () =>
                  ref.read(searchNotifierProvider.notifier).reset(),
              child: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResults(SearchResultData data, ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (data.preferenceInsight != null)
          _buildPreferenceInsightCard(data.preferenceInsight!, theme),
        if (data.isEmpty) ...[
          const SizedBox(height: 32),
          Center(
            child: Icon(
              Icons.search_off_rounded,
              size: 64,
              color: theme.colorScheme.outlineVariant,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Aucune recette ne correspond à votre recherche.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          if (data.suggestion != null && data.suggestion!.isNotEmpty) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline,
                            size: 18,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Suggestion',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        data.suggestion!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          _controller.text = data.suggestion!;
                          _search();
                        },
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('Lancer cette recherche'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ] else
          ...data.results.map((r) => _SearchResultTile(result: r)),
        _buildGenerateTile(theme),
        _buildWebSearchTile(theme),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildGenerateTile(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: InkWell(
        onTap: _generate,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.primary.withOpacity(0.35),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome,
                color: theme.colorScheme.primary,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Demander à l\'IA de créer cette recette',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Gemini génère une recette personnalisée selon vos goûts',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebSearchTile(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: InkWell(
        onTap: _searchingWeb ? null : _searchOnWeb,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: theme.colorScheme.outline.withOpacity(0.35),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              _searchingWeb
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : Icon(
                      Icons.public,
                      color: theme.colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rechercher sur le web',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _searchingWeb
                          ? 'Optimisation de la recherche par IA…'
                          : 'Google avec une requête optimisée par Gemini',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_new,
                color: theme.colorScheme.onSurfaceVariant,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreferenceInsightCard(String insight, ThemeData theme) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.psychology_outlined,
              size: 18,
              color: theme.colorScheme.onTertiaryContainer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                insight,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGeneratingState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Génération de la recette en cours…'),
          SizedBox(height: 6),
          Text(
            'Gemini crée une recette personnalisée',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildGeneratedWrapper(Recipe recipe) {
    // Pousse l'écran de prévisualisation au-dessus de la recherche.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context)
          .push<void>(
            MaterialPageRoute(
              builder: (_) => _GeneratedRecipeScreen(
                recipe: recipe,
                onSaved: () {
                  ref.read(searchNotifierProvider.notifier).reset();
                },
                onCancel: () {
                  ref.read(searchNotifierProvider.notifier).reset();
                },
                onSave: (r) => ref
                    .read(searchNotifierProvider.notifier)
                    .saveGeneratedRecipe(r),
              ),
            ),
          )
          .then((_) {
            // Si l'utilisateur fait Back sans sauvegarder, reset l'état.
            if (ref.read(searchNotifierProvider) is SearchGenerated) {
              ref.read(searchNotifierProvider.notifier).reset();
            }
          });
    });
    // En attendant le postFrameCallback, afficher un loading sobre.
    return const Center(child: CircularProgressIndicator());
  }
}

// ── Écran de prévisualisation de la recette générée par l'IA ──────────────────

class _GeneratedRecipeScreen extends ConsumerStatefulWidget {
  final Recipe recipe;
  final Future<void> Function(Recipe) onSave;
  final VoidCallback onSaved;
  final VoidCallback onCancel;

  const _GeneratedRecipeScreen({
    required this.recipe,
    required this.onSave,
    required this.onSaved,
    required this.onCancel,
  });

  @override
  ConsumerState<_GeneratedRecipeScreen> createState() =>
      _GeneratedRecipeScreenState();
}

class _GeneratedRecipeScreenState extends ConsumerState<_GeneratedRecipeScreen>
    with RecipeFormMixin<_GeneratedRecipeScreen> {
  bool _saving = false;
  bool _refining = false;
  late Recipe _currentRecipe;
  final _refineCtrl = TextEditingController();

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

  /// Reconstruit la recette en cours depuis les contrôleurs (pour save ou refine).
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
      await widget.onSave(_buildCurrentRecipe());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recette sauvegardée dans les brouillons !'),
          ),
        );
        widget.onSaved();
        Navigator.of(context).pop();
        context.go(AppRoutes.drafts);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Envoie la recette courante + l'instruction à Gemini pour raffinement.
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
        currentPortions: int.tryParse(portionsCtrl.text.trim()) ??
            _currentRecipe.portions,
        instruction: instruction,
      );

      // Parser la réponse brute (même logique que dans SearchNotifier).
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
      final tagsRaw =
          Map<String, dynamic>.from(raw['tags'] as Map? ?? {});
      final tags = RecipeTags(
        themes: List<String>.from(tagsRaw['themes'] as List? ?? []),
        cuisines: List<String>.from(tagsRaw['cuisines'] as List? ?? []),
        occasions: List<String>.from(tagsRaw['occasions'] as List? ?? []),
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

      // Mettre à jour les contrôleurs avec la recette raffinée.
      titleCtrl.text = refined.titre;
      cooklangCtrl.text = refined.rawCooklang;
      portionsCtrl.text = refined.portions?.toString() ?? '';
      difficultyCtrl.text = refined.tags.difficulty ?? '';
      prepTimeCtrl.text = refined.tags.prepTime?.toString() ?? '';
      cookTimeCtrl.text = refined.tags.cookTime?.toString() ?? '';
      setState(() {
        _currentRecipe = refined;
        formIngredients = List<RecipeIngredient>.from(refined.ingredients);
        formInitialized = true;
      });
      _refineCtrl.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur lors du raffinement : $e')),
        );
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
        title: Text(titleCtrl.text.isEmpty ? _currentRecipe.titre : titleCtrl.text),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Annuler',
          onPressed: () {
            Navigator.of(context).pop();
            widget.onCancel();
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
                        borderSide:
                            BorderSide(color: theme.colorScheme.outline),
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
              onBookChanged: (_, __) {},
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
      length: 4,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Informations'),
              Tab(text: 'CookLang'),
              Tab(text: 'Aperçu'),
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
                    onBookChanged: (_, __) {},
                    showBookSelector: false,
                    infoBookLabel: "Mes créations Kass'Dalle ✨",
                  ),
                ),
                RecipeCooklangEditor(
                  ctrl: cooklangCtrl,
                  enabled: !_saving && !_refining,
                  showHelp: true,
                ),
                CooklangPreview(
                  ctrl: cooklangCtrl,
                  overrideIngredients: formIngredients,
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
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'CookLang'),
              Tab(text: 'Aperçu'),
              Tab(text: 'Ingrédients'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                RecipeCooklangEditor(
                  ctrl: cooklangCtrl,
                  enabled: !_saving && !_refining,
                  showHelp: true,
                ),
                CooklangPreview(
                  ctrl: cooklangCtrl,
                  overrideIngredients: formIngredients,
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



class _SearchResultTile extends StatelessWidget {
  final RecipeSearchResult result;

  const _SearchResultTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final recipe = result.recipe;
    final theme = Theme.of(context);
    final isDraft = recipe.reviewStatus != ReviewStatus.validated;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (isDraft) {
            context.push('${AppRoutes.drafts}/${recipe.id}');
          } else {
            context.push('${AppRoutes.recipes}/${recipe.id}');
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Icône statut
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: isDraft
                      ? theme.colorScheme.tertiaryContainer
                      : theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isDraft ? Icons.edit_note : Icons.restaurant_menu,
                  size: 20,
                  color: isDraft
                      ? theme.colorScheme.onTertiaryContainer
                      : theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              // Contenu
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            recipe.titre,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        RecipeRatingBadge(recipeId: recipe.id),
                        if (isDraft)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Chip(
                              label: const Text('Brouillon'),
                              labelStyle: theme.textTheme.labelSmall,
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                      ],
                    ),
                    if ((recipe.bookTitre ?? '').isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        recipe.bookTitre!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 6),
                    // Raison
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            result.reason,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Tags
                    if (recipe.tags.themes.isNotEmpty ||
                        recipe.tags.cuisines.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          ...recipe.tags.themes
                              .take(3)
                              .map((t) => _TagChip(label: t)),
                          ...recipe.tags.cuisines
                              .take(2)
                              .map((c) => _TagChip(label: c)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  final String label;
  const _TagChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
