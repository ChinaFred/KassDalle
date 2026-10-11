import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../recipes/presentation/recipe_filter_widgets.dart';
import '../domain/explore_facets.dart';
import '../domain/search_models.dart';

/// Les filtres de l'écran Explorer : panneau de gauche sur grand écran,
/// contenu de la feuille « Filtres » sur téléphone.
///
/// Visibles d'emblée : Recettes, Tri, Type de plat, Temps total, Cuisine.
/// Le reste sous « Plus de filtres ».
class ExploreFilterPanel extends ConsumerStatefulWidget {
  final ExplorePreferences prefs;
  final ExploreFacets facets;
  final String myUid;

  /// Faux pour un lecteur : la puce « Mes brouillons » n'apparaît pas.
  final bool showDrafts;
  final ValueChanged<ExplorePreferences> onChanged;

  /// Contrôleur de défilement fourni par une feuille ; absent, le panneau
  /// défile seul.
  final ScrollController? scrollController;

  const ExploreFilterPanel({
    super.key,
    required this.prefs,
    required this.facets,
    required this.myUid,
    this.showDrafts = true,
    required this.onChanged,
    this.scrollController,
  });

  @override
  ConsumerState<ExploreFilterPanel> createState() => _ExploreFilterPanelState();
}

class _ExploreFilterPanelState extends ConsumerState<ExploreFilterPanel> {
  final _ingredientCtrl = TextEditingController();

  @override
  void dispose() {
    _ingredientCtrl.dispose();
    super.dispose();
  }

  RecipeFilter get _filter => widget.prefs.filter;

  void _toggle(RecipeFilterDimension d, String key) =>
      widget.onChanged(widget.prefs.copyWith(filter: _filter.toggle(d, key)));

  void _addExcludedIngredient() {
    final term = _ingredientCtrl.text.trim();
    if (term.isEmpty) return;
    _ingredientCtrl.clear();
    if (_filter.excludedIngredients.contains(term)) return;
    _toggle(RecipeFilterDimension.excludedIngredient, term);
  }

  Widget _group(
    String title,
    RecipeFilterDimension d, {
    String? help,
    List<RecipeFacet>? facets,
  }) => RecipeFacetChipGroup(
    title: title,
    help: help,
    facets: facets ?? widget.facets.of(d),
    selected: _filter.keysOf(d),
    onToggle: (key) => _toggle(d, key),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources = widget.prefs.sources;
    final authors = [
      for (final f in widget.facets.authors)
        RecipeFacet(
          key: f.key,
          label: f.key == widget.myUid
              ? 'Moi'
              : (ref.watch(memberNameProvider(f.key)) ?? '…'),
          count: f.count,
        ),
    ];

    void setSources(SearchParams next) =>
        widget.onChanged(widget.prefs.copyWith(sources: next));

    return ListView(
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Recettes', style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                label: const Text('Mes recettes'),
                selected: sources.myRecipes,
                onSelected: (v) => setSources(sources.copyWith(myRecipes: v)),
              ),
              FilterChip(
                label: const Text('Ma famille'),
                selected: sources.familyRecipes,
                onSelected: (v) =>
                    setSources(sources.copyWith(familyRecipes: v)),
              ),
              if (widget.showDrafts)
                FilterChip(
                  label: const Text('Mes brouillons'),
                  selected: sources.includeDrafts,
                  onSelected: (v) =>
                      setSources(sources.copyWith(includeDrafts: v)),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text('Trier par', style: theme.textTheme.titleSmall),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final sort in RecipeSort.values)
                ChoiceChip(
                  label: Text(sort.label),
                  selected: widget.prefs.sort == sort,
                  onSelected: (_) =>
                      widget.onChanged(widget.prefs.copyWith(sort: sort)),
                ),
            ],
          ),
        ),
        _group('Type de plat', RecipeFilterDimension.dishType),
        _group(
          'Temps total',
          RecipeFilterDimension.totalTime,
          help: 'Préparation + cuisson ; le repos n\'est pas compté.',
        ),
        SwitchListTile(
          title: const Text('Compter les durées estimées'),
          subtitle: const Text(
            'Durées estimées par l\'IA pour les recettes qui n\'en donnent '
            'pas. Comptent aussi dans le tri « Plus rapides ».',
          ),
          value: _filter.countEstimatedTimes,
          onChanged: (v) => widget.onChanged(
            widget.prefs.copyWith(
              filter: _filter.copyWith(countEstimatedTimes: v),
            ),
          ),
        ),
        _group('Cuisine', RecipeFilterDimension.cuisine),
        const SizedBox(height: 8),
        ExpansionTile(
          title: const Text('Plus de filtres'),
          initiallyExpanded: _hasHiddenActive,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          children: [
            _group('Rôle dans le repas', RecipeFilterDimension.mealRole),
            _group('Protéine', RecipeFilterDimension.protein),
            _group('Féculent', RecipeFilterDimension.starch),
            _group('Difficulté', RecipeFilterDimension.difficulty),
            _group('Thème ou occasion', RecipeFilterDimension.theme),
            _excludedIngredients(theme),
            _group(
              'Sans allergène…',
              RecipeFilterDimension.excludedAllergen,
              help:
                  'Écarte les recettes qui en contiennent. Une recette dont '
                  'l\'analyse est incomplète est écartée aussi.',
            ),
            _group('Livre', RecipeFilterDimension.book),
            _group('Auteur', RecipeFilterDimension.author, facets: authors),
            _group('Ma note minimale', RecipeFilterDimension.minRating),
            _group(
              'Calories par portion max',
              RecipeFilterDimension.maxCalories,
            ),
          ],
        ),
      ],
    );
  }

  bool get _hasHiddenActive => _filter.activeDimensions.any(
    (d) =>
        d != RecipeFilterDimension.dishType &&
        d != RecipeFilterDimension.totalTime &&
        d != RecipeFilterDimension.cuisine,
  );

  Widget _excludedIngredients(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Sans l\'ingrédient…', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _ingredientCtrl,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'Ex. : coriandre',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Ajouter',
                icon: const Icon(Icons.add),
                onPressed: _addExcludedIngredient,
              ),
            ),
            onSubmitted: (_) => _addExcludedIngredient(),
          ),
          if (_filter.excludedIngredients.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final term in _filter.excludedIngredients)
                  InputChip(
                    label: Text('Sans $term'),
                    onDeleted: () =>
                        _toggle(RecipeFilterDimension.excludedIngredient, term),
                    deleteButtonTooltipMessage: 'Retirer',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Le libellé d'une valeur cochée, pour les puces de la barre téléphone.
String activeValueLabel(
  RecipeFilterDimension d,
  String key,
  ExploreFacets facets, {
  required String Function(String uid) authorLabel,
}) {
  if (d == RecipeFilterDimension.excludedIngredient) return 'Sans $key';
  if (d == RecipeFilterDimension.author) return authorLabel(key);
  final label = facets
      .of(d)
      .where((f) => f.key == key)
      .map((f) => f.label)
      .firstOrNull;
  final shown = label ?? key;
  return switch (d) {
    RecipeFilterDimension.excludedAllergen => 'Sans $shown',
    RecipeFilterDimension.minRating => 'Note $shown',
    _ => shown,
  };
}
