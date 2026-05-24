import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/search_models.dart';
import 'generated_recipe_screen.dart';
import '../../../core/services/gemini_providers.dart';
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
      appBar: AppBar(title: const Text('Explorer')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Champ de saisie ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
              decoration: InputDecoration(
                hintText:
                    'Ex : une tarte aux pommes facile, poulet rôti facile…',
                prefixIcon: const Icon(Icons.edit_outlined),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
              maxLines: 2,
              minLines: 1,
            ),
          ),
          // ── Deux actions principales ───────────────────────────────────────
          Builder(
            builder: (context) {
              final busy = state is SearchLoading || state is SearchGenerating;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: busy ? null : _generate,
                        icon: const Icon(Icons.auto_awesome, size: 18),
                        label: const Text('Créer avec Gemini'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.secondaryContainer,
                          foregroundColor:
                              theme.colorScheme.onSecondaryContainer,
                        ),
                        onPressed: busy ? null : _search,
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('Chercher'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          // ── Filtres (pertinents pour la recherche) ─────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Wrap(
              spacing: 6,
              children: [
                FilterChip(
                  label: const Text('Mes recettes'),
                  selected: _params.myRecipes,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) =>
                      setState(() => _params = _params.copyWith(myRecipes: v)),
                ),
                FilterChip(
                  label: const Text('Recettes famille'),
                  selected: _params.familyRecipes,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setState(
                    () => _params = _params.copyWith(familyRecipes: v),
                  ),
                ),
                FilterChip(
                  label: const Text('Inclure brouillons'),
                  selected: _params.includeDrafts,
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) => setState(
                    () => _params = _params.copyWith(includeDrafts: v),
                  ),
                ),
              ],
            ),
          ),
          // ── Web (tertiaire) ────────────────────────────────────────────────
          Center(
            child: TextButton.icon(
              onPressed: _searchingWeb ? null : _searchOnWeb,
              icon: _searchingWeb
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.public, size: 16),
              label: Text(
                _searchingWeb
                    ? 'Optimisation en cours…'
                    : 'Rechercher sur le web',
                style: const TextStyle(fontSize: 13),
              ),
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
            Icons.auto_awesome_outlined,
            size: 56,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Décrivez votre envie culinaire',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Créez une recette avec Gemini\nou cherchez dans votre bibliothèque',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outlineVariant,
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
        const SizedBox(height: 8),
      ],
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
