import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/search_models.dart';
import 'generated_recipe_screen.dart';
import 'search_providers.dart';
import 'search_widgets.dart';

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
    final insight = current is SearchSuccess
        ? current.data.preferenceInsight
        : null;
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
                Builder(
                  builder: (context) {
                    final isWide = MediaQuery.of(context).size.width >= 800;
                    final busy =
                        state is SearchLoading || state is SearchGenerating;
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
                  },
                ),
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
              SearchGenerated(:final generatedRecipe) => _buildGeneratedWrapper(
                generatedRecipe,
              ),
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
          ...data.results.map((r) => SearchResultTile(result: r)),
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
              Icon(Icons.chevron_right, color: theme.colorScheme.primary),
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
              builder: (_) => GeneratedRecipeScreen(
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

