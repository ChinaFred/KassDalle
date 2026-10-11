import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/search_models.dart';
import 'generated_recipe_screen.dart';
import 'search_providers.dart';
import 'search_widgets.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/presentation/url_import/url_import_dialog.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _controller = TextEditingController();
  SearchParams _params = const SearchParams();
  ExploreSource _source = ExploreSource.all;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _explore() {
    final query = _controller.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    ref
        .read(searchNotifierProvider.notifier)
        .explore(query: query, params: _params, source: _source);
  }

  Future<void> _openGeneratedSuggestion(GeneratedRecipeSuggestion suggestion) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => GeneratedRecipeScreen(
          recipe: suggestion.recipe,
          onSaved: () {},
          onCancel: () {},
          onSave: (recipe) => ref
              .read(searchNotifierProvider.notifier)
              .saveGeneratedRecipe(recipe),
        ),
      ),
    );
  }

  Future<void> _openWebSuggestion(WebSearchSuggestion suggestion) async {
    final uri = Uri.parse(suggestion.url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  String _sourceLabel(ExploreSource source) {
    return switch (source) {
      ExploreSource.all => 'Tout',
      ExploreSource.library => 'Bibliothèque',
      ExploreSource.ai => 'IA',
      ExploreSource.web => 'Web',
    };
  }

  String _sourceSubtitle(ExploreSource source) {
    return switch (source) {
      ExploreSource.all => 'Recherche + 3 idées IA + ouverture web',
      ExploreSource.library => 'Uniquement dans votre bibliothèque',
      ExploreSource.ai => '3 propositions IA à comparer',
      ExploreSource.web => 'Une suggestion de requête Google optimisée',
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchNotifierProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Explorer'),
        actions: [
          // Importer coûte des appels d'IA : éditeurs et administrateurs.
          if (ref.watch(canEditProvider))
            IconButton(
              tooltip: 'Importer depuis un lien',
              icon: const Icon(Icons.link),
              onPressed: () => showUrlImportDialog(context),
            ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Mode d'exploration ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              'Mode d\'exploration',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
            child: Wrap(
              spacing: 6,
              children: ExploreSource.values
                  .map(
                    (source) => ChoiceChip(
                      label: Text(_sourceLabel(source)),
                      selected: _source == source,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _source = source),
                    ),
                  )
                  .toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _sourceSubtitle(_source),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_source != ExploreSource.web) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Text(
                'Inclure dans la bibliothèque',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Wrap(
                spacing: 6,
                children: [
                  FilterChip(
                    label: const Text('Mes recettes'),
                    selected: _params.myRecipes,
                    visualDensity: VisualDensity.compact,
                    onSelected: (value) => setState(
                      () => _params = _params.copyWith(myRecipes: value),
                    ),
                  ),
                  FilterChip(
                    label: const Text('Ma famille'),
                    selected: _params.familyRecipes,
                    visualDensity: VisualDensity.compact,
                    onSelected: (value) => setState(
                      () => _params = _params.copyWith(familyRecipes: value),
                    ),
                  ),
                  FilterChip(
                    label: const Text('Mes brouillons'),
                    selected: _params.includeDrafts,
                    visualDensity: VisualDensity.compact,
                    onSelected: (value) => setState(
                      () => _params = _params.copyWith(includeDrafts: value),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 1),
          // ── Titre / description ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Text(
              'Decrivez votre envie culinaire',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // ── Champ de saisie ───────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: StylusPadTextField(
              controller: _controller,
              padTitle: 'Votre envie culinaire',
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _explore(),
              decoration: InputDecoration(
                hintText: 'Ex : une tarte aux pommes facile, poulet rôti…',
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
          Builder(
            builder: (context) {
              final busy = state is SearchLoading;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: FilledButton.icon(
                  onPressed: busy ? null : _explore,
                  icon: const Icon(
                    Icons.travel_explore,
                    size: AppIconSize.small,
                  ),
                  label: Text(
                    _source == ExploreSource.ai
                        ? 'Explorer 3 idées IA'
                        : 'Explorer',
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: switch (state) {
              SearchIdle() => _buildIdleState(theme),
              SearchLoading() => _buildLoadingState(),
              SearchError(:final message) => _buildErrorState(message),
              SearchSuccess(:final data) => _buildResults(data, theme),
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
            size: AppIconSize.hero,
            color: theme.colorScheme.outlineVariant,
          ),
          const SizedBox(height: 16),
          Text(
            'Decrivez votre envie culinaire',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Un seul flux pour fouiller votre bibliothèque, comparer 3 idées IA et ouvrir le web si besoin.',
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
          Text('Exploration en cours…'),
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
            const Icon(
              Icons.error_outline,
              size: AppIconSize.hero,
              color: Colors.red,
            ),
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
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (data.preferenceInsight != null)
            _buildPreferenceInsightCard(data.preferenceInsight!, theme),
          const SizedBox(height: 32),
          Center(
            child: Icon(
              Icons.search_off_rounded,
              size: AppIconSize.hero,
              color: theme.colorScheme.outlineVariant,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Aucun résultat à afficher pour ce mode.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (data.preferenceInsight != null)
          _buildPreferenceInsightCard(data.preferenceInsight!, theme),
        if (data.libraryResults.isNotEmpty ||
            (data.librarySuggestion != null &&
                data.librarySuggestion!.isNotEmpty)) ...[
          const SearchSectionHeader(
            title: 'Bibliothèque',
            subtitle: 'Recettes existantes dans votre périmètre sélectionné',
          ),
          if (data.libraryResults.isNotEmpty)
            ...data.libraryResults.map(
              (result) => SearchResultTile(result: result),
            )
          else
            _buildLibrarySuggestionCard(data.librarySuggestion!, theme),
        ],
        if (data.generatedResults.isNotEmpty) ...[
          const SearchSectionHeader(
            title: 'Idées IA',
            subtitle:
                'Trois alternatives a comparer avant d\'ouvrir l\'editeur',
          ),
          ...data.generatedResults.map(
            (suggestion) => GeneratedRecipeSuggestionTile(
              suggestion: suggestion,
              onTap: () => _openGeneratedSuggestion(suggestion),
            ),
          ),
        ],
        if (data.webSuggestion != null) ...[
          const SearchSectionHeader(
            title: 'Web',
            subtitle: 'Poursuivre l\'exploration en dehors de Kass\'Dalle',
          ),
          WebSearchSuggestionTile(
            suggestion: data.webSuggestion!,
            onTap: () => _openWebSuggestion(data.webSuggestion!),
          ),
        ],
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildLibrarySuggestionCard(String suggestion, ThemeData theme) {
    return Padding(
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
                    size: AppIconSize.small,
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
              Icons.smart_toy_outlined,
              size: AppIconSize.small,
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
}
