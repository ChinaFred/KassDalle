import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../recipes/domain/recipe.dart';
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

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

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
                FilledButton(
                  onPressed: (state is SearchLoading || state is SearchGenerating)
                      ? null
                      : _search,
                  child: const Text('Chercher'),
                ),
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Demander à l\'IA de créer cette recette',
                  child: FilledButton.tonal(
                    onPressed: (_controller.text.trim().isEmpty ||
                            state is SearchLoading ||
                            state is SearchGenerating)
                        ? null
                        : _generate,
                    child: const Icon(Icons.auto_awesome, size: 20),
                  ),
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
              SearchGenerated(:final generatedRecipe) =>
                _buildGeneratedRecipe(generatedRecipe, theme),
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
    if (data.isEmpty) {
      return _buildNoResults(data.suggestion, data.preferenceInsight, theme);
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: data.results.length + (data.preferenceInsight != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (data.preferenceInsight != null && index == 0) {
          return _buildPreferenceInsightCard(data.preferenceInsight!, theme);
        }
        final resultIndex =
            data.preferenceInsight != null ? index - 1 : index;
        return _SearchResultTile(result: data.results[resultIndex]);
      },
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

  Widget _buildNoResults(String? suggestion, String? preferenceInsight, ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 64,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'Aucune recette ne correspond à votre recherche.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (suggestion != null && suggestion.isNotEmpty) ...[
              const SizedBox(height: 24),
              Card(
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
                        suggestion,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          _controller.text = suggestion;
                          _search();
                        },
                        icon: const Icon(Icons.search, size: 18),
                        label: const Text('Lancer cette recherche'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (preferenceInsight != null && preferenceInsight.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildPreferenceInsightCard(preferenceInsight, theme),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Utilisez ✨ pour que Gemini génère cette recette.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
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

  Widget _buildGeneratedRecipe(Recipe recipe, ThemeData theme) {
    final steps = recipe.rawCooklang
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('>>'))
        .toList();

    return Column(
      children: [
        // ── Header ─────────────────────────────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          color: theme.colorScheme.primaryContainer,
          child: Row(
            children: [
              Icon(
                Icons.auto_awesome,
                size: 20,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Recette générée par l\'IA — non vérifiée',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: () =>
                    ref.read(searchNotifierProvider.notifier).reset(),
                child: Text(
                  'Annuler',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
        // ── Contenu scrollable ──────────────────────────────────────────────
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                recipe.titre,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              if (recipe.tags.cuisines.isNotEmpty ||
                  recipe.tags.themes.isNotEmpty ||
                  recipe.tags.difficulty != null) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    if (recipe.tags.difficulty != null)
                      _TagChip(label: recipe.tags.difficulty!),
                    ...recipe.tags.cuisines.map((c) => _TagChip(label: c)),
                    ...recipe.tags.themes.map((t) => _TagChip(label: t)),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (recipe.tags.prepTime != null ||
                  recipe.tags.cookTime != null ||
                  recipe.portions != null) ...[
                Wrap(
                  spacing: 16,
                  children: [
                    if (recipe.tags.prepTime != null)
                      _InfoChip(
                        icon: Icons.timer_outlined,
                        label: 'Prép. ${recipe.tags.prepTime} min',
                        theme: theme,
                      ),
                    if (recipe.tags.cookTime != null)
                      _InfoChip(
                        icon: Icons.local_fire_department_outlined,
                        label: 'Cuisson ${recipe.tags.cookTime} min',
                        theme: theme,
                      ),
                    if (recipe.portions != null)
                      _InfoChip(
                        icon: Icons.people_outline,
                        label: '${recipe.portions} portions',
                        theme: theme,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              const Divider(),
              if (recipe.ingredients.isNotEmpty) ...[
                Text(
                  'Ingrédients',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                ...recipe.ingredients.map(
                  (ing) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('• '),
                        Expanded(
                          child: Text(
                            [
                              if (ing.qty.isNotEmpty) ing.qty,
                              if (ing.unit.isNotEmpty) ing.unit,
                              ing.name,
                            ].join(' '),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(),
              ],
              if (steps.isNotEmpty) ...[
                Text(
                  'Préparation',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                ...steps.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 22,
                          height: 22,
                          margin: const EdgeInsets.only(right: 8, top: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.secondaryContainer,
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              '${e.key + 1}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ),
                        Expanded(child: Text(e.value)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
              FilledButton.icon(
                onPressed: () async {
                  try {
                    await ref
                        .read(searchNotifierProvider.notifier)
                        .saveGeneratedRecipe(recipe);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Recette sauvegardée dans les brouillons !',
                          ),
                        ),
                      );
                      context.go('/drafts');
                    }
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Erreur : $e')),
                      );
                    }
                  }
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('Sauvegarder comme brouillon'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () =>
                    ref.read(searchNotifierProvider.notifier).reset(),
                child: const Text('Annuler'),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final ThemeData theme;

  const _InfoChip({
    required this.icon,
    required this.label,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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
