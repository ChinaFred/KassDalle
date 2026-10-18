import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../search/domain/explore_facets.dart';
import '../../search/domain/search_models.dart';
import '../../search/presentation/explore_filter_panel.dart';
import '../../search/presentation/search_widgets.dart';
import 'meal_suggestion_providers.dart';

/// Ce que la route `/planning/suggest/search` reçoit en `extra`.
class AdvancedDishSearchArgs {
  /// Le texte déjà saisi dans « Quel plat ? », repris comme texte de départ.
  final String initialQuery;

  /// La recette déjà choisie, repérée par une coche.
  final String? pickedId;

  const AdvancedDishSearchArgs({this.initialQuery = '', this.pickedId});
}

/// Ce que l'écran rend, par `pop` : une recette choisie, ou le texte tapé à
/// garder comme nom libre. `null` au retour par la flèche.
class AdvancedDishPick {
  final Recipe? recipe;
  final String? freeName;

  const AdvancedDishPick.recipe(Recipe this.recipe) : freeName = null;
  const AdvancedDishPick.freeName(String this.freeName) : recipe = null;
}

/// Les dimensions que cet écran ne sait pas alimenter : la note du lecteur
/// n'est pas lue ici.
const _kHiddenDimensions = {RecipeFilterDimension.minRating};

/// La recherche avancée d'un plat à suggérer : texte en sections et filtres de
/// l'Explorer, sur la liste de l'écran « Suggérer un plat ». Rien n'est
/// enregistré : les filtres vivent le temps de l'écran, hors des préférences
/// de l'Explorer. Aucun appel d'IA.
class AdvancedDishSearchScreen extends ConsumerStatefulWidget {
  final AdvancedDishSearchArgs args;

  const AdvancedDishSearchScreen({super.key, required this.args});

  @override
  ConsumerState<AdvancedDishSearchScreen> createState() =>
      _AdvancedDishSearchScreenState();
}

class _AdvancedDishSearchScreenState
    extends ConsumerState<AdvancedDishSearchScreen> {
  late final _queryCtrl = TextEditingController(text: widget.args.initialQuery);
  ExplorePreferences _prefs = const ExplorePreferences(sort: RecipeSort.title);
  final _closedSections = <RecipeQuerySection>{};

  /// La liste cherchée à la dernière construction, pour la feuille « Filtres ».
  List<Recipe> _corpus = const [];

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  RecipeFilter get _filter => _prefs.filter;

  /// Les recettes privées d'un autre membre n'ont que leur titre : les
  /// filtres ne peuvent pas les retenir.
  List<Recipe> _searchable(List<Recipe> corpus) => _filter.isEmpty
      ? corpus
      : corpus.where((r) => !r.isPrivate).toList(growable: false);

  ExploreFacets _facets(List<Recipe> corpus) => exploreFacets(
    corpus.where((r) => !r.isPrivate).toList(growable: false),
    myUid: '',
    context: RecipeFilterContext.forFilter(_filter),
  );

  void _setPrefs(ExplorePreferences next) => setState(() => _prefs = next);

  Widget _panel(
    List<Recipe> corpus, {
    ScrollController? scrollController,
    required ValueChanged<ExplorePreferences> onChanged,
  }) => ExploreFilterPanel(
    prefs: _prefs,
    facets: _facets(corpus),
    myUid: '',
    showDrafts: false,
    showSourcesAndSort: false,
    hiddenDimensions: _kHiddenDimensions,
    scrollController: scrollController,
    onChanged: onChanged,
  );

  Future<void> _openFilters() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheet) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          maxChildSize: 0.95,
          builder: (context, controller) => Column(
            children: [
              Expanded(
                child: _panel(
                  _corpus,
                  scrollController: controller,
                  onChanged: (next) {
                    _setPrefs(next);
                    setSheet(() {});
                  },
                ),
              ),
              const Divider(height: 1),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: _filter.isEmpty
                            ? null
                            : () {
                                _clearFilters();
                                setSheet(() {});
                              },
                        child: const Text('Effacer les filtres'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Voir les résultats'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _clearFilters() => _setPrefs(_prefs.copyWith(filter: _filter.cleared));

  void _choose(Recipe recipe) => context.pop(AdvancedDishPick.recipe(recipe));

  @override
  Widget build(BuildContext context) {
    final recipesAsync = ref.watch(suggestableRecipesProvider);
    final titlesAsync = ref.watch(suggestablePrivateTitlesProvider);
    final own = recipesAsync.value ?? const <Recipe>[];
    final known = {for (final r in own) r.id};
    _corpus = [
      ...own,
      ...?titlesAsync.value?.where((r) => !known.contains(r.id)),
    ];
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    final Widget body;
    if (recipesAsync.hasError) {
      body = AppErrorState(
        error: recipesAsync.error,
        onRetry: () => ref.invalidate(suggestableRecipesProvider),
      );
    } else if (!recipesAsync.hasValue) {
      body = const AppLoadingState();
    } else {
      body = _results(isWide);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Recherche avancée')),
      body: isWide && recipesAsync.hasValue
          ? Row(
              children: [
                SizedBox(
                  width: 320,
                  child: _panel(_corpus, onChanged: _setPrefs),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            )
          : Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: body,
              ),
            ),
    );
  }

  Widget _results(bool isWide) {
    final theme = Theme.of(context);
    final query = _queryCtrl.text;
    final outcome = applyRecipeFilter(
      _searchable(_corpus),
      query: query,
      filter: _filter,
      context: RecipeFilterContext.forFilter(_filter),
      sort: _prefs.sort,
    );
    final sectioned = outcome.sections.isNotEmpty;
    final rows = <({RecipeQuerySection? header, Recipe? recipe})>[];
    if (sectioned) {
      for (final MapEntry(key: section, value: inSection)
          in outcome.sections.entries) {
        rows.add((header: section, recipe: null));
        if (!_closedSections.contains(section)) {
          rows.addAll(inSection.map((r) => (header: null, recipe: r)));
        }
      }
    } else {
      rows.addAll(outcome.recipes.map((r) => (header: null, recipe: r)));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _queryCtrl,
            autofocus: widget.args.initialQuery.isEmpty,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Recherche',
              hintText: 'Un plat, un ingrédient, une cuisine',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Effacer',
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(_queryCtrl.clear),
                    ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  recipeCountLabel(outcome.recipes.length),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (!_filter.isEmpty)
                TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Effacer les filtres'),
                ),
              if (!isWide)
                ActionChip(
                  avatar: const Icon(Icons.tune, size: AppIconSize.inline),
                  label: Text(
                    _filter.isEmpty ? 'Filtres' : 'Filtres · ${_filter.count}',
                  ),
                  onPressed: _openFilters,
                ),
            ],
          ),
        ),
        Expanded(
          child: outcome.recipes.isEmpty
              ? _empty(query)
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final row = rows[i];
                    if (row.header case final section?) {
                      return QuerySectionHeader(
                        title: section.label,
                        count: outcome.sections[section]!.length,
                        open: !_closedSections.contains(section),
                        onToggle: () => setState(() {
                          if (!_closedSections.remove(section)) {
                            _closedSections.add(section);
                          }
                        }),
                      );
                    }
                    return _tile(
                      row.recipe!,
                      outcome.matchedIngredients[row.recipe!.id] ?? const [],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _tile(Recipe recipe, List<String> matched) {
    final theme = Theme.of(context);
    final selected = widget.args.pickedId == recipe.id;
    final subtitle = matched.isNotEmpty
        ? 'contient : ${matched.join(', ')}'
        : recipe.isPrivate
        ? 'Seul le titre est visible'
        : null;
    return ListTile(
      title: Text(recipe.titre),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: selected
          ? const Icon(Icons.check_circle, semanticLabel: 'Déjà choisie')
          : recipe.isPrivate
          ? Icon(
              Icons.lock_outline,
              size: AppIconSize.small,
              semanticLabel: 'Seul le titre est visible',
              color: theme.colorScheme.onSurfaceVariant,
            )
          : null,
      onTap: () => _choose(recipe),
    );
  }

  Widget _empty(String query) {
    final text = query.trim();
    return AppEmptyState(
      icon: Icons.search_off_rounded,
      title: 'Aucune recette trouvée.',
      message: text.isEmpty ? 'Modifiez les filtres.' : null,
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!_filter.isEmpty)
            OutlinedButton(
              onPressed: _clearFilters,
              child: const Text('Effacer les filtres'),
            ),
          if (text.isNotEmpty)
            FilledButton.tonal(
              onPressed: () => context.pop(AdvancedDishPick.freeName(text)),
              child: Text('Garder « $text » comme nom libre'),
            ),
        ],
      ),
    );
  }
}
