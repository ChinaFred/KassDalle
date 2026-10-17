import 'package:flutter/material.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/meal_idea.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../../recipes/presentation/recipe_filter_widgets.dart';
import 'meal_ideas_sheet.dart';
import '../../../core/theme/app_icon_size.dart';

/// Le sélecteur de recette, commun au planning et au nouveau planning.
///
/// Une recherche par titre, une icône de filtre en bout de ligne — types de
/// plat et cuisines lus dans le corpus —, et les recettes déjà écartées
/// masquées derrière une puce. Le corpus reçu ne contient que des pages de
/// type recette : le tri se fait au chargement, voir [pickableRecipes].
class RecipePickerSheet extends StatefulWidget {
  final List<Recipe> recipes;

  /// Recettes déjà écartées : masquées, sauf demande expresse.
  final Set<String> dismissedRecipeIds;

  /// Ce dont elles ont été écartées : « repas » ou « créneau ».
  final String dismissedFrom;

  final String hintText;

  /// Vrai pour proposer la saisie d'un nom libre même sans recherche ; sinon
  /// la saisie n'apparaît qu'une fois un nom tapé.
  final bool freeNameAlways;

  /// Génère des idées de repas sur une consigne. Absent, l'entrée « Générer
  /// avec l'IA » n'apparaît pas. Elle suit la saisie libre : même place, même
  /// résultat — un repas sans recette liée.
  final MealIdeasGenerator? onGenerateIdeas;

  /// Rédige et enregistre la recette de l'idée retenue. Absent, l'idée sort
  /// en repas libre, sans recette.
  final MealIdeaConceiver? onConceiveIdea;

  /// Recherche pré-remplie à l'ouverture : le titre d'une suggestion de
  /// repas à planifier.
  final String initialQuery;

  const RecipePickerSheet({
    super.key,
    required this.recipes,
    this.dismissedRecipeIds = const {},
    this.dismissedFrom = 'repas',
    this.hintText = 'Rechercher une recette…',
    this.freeNameAlways = false,
    this.onGenerateIdeas,
    this.onConceiveIdea,
    this.initialQuery = '',
  });

  @override
  State<RecipePickerSheet> createState() => _RecipePickerSheetState();
}

class _RecipePickerSheetState extends State<RecipePickerSheet> {
  late String _query = widget.initialQuery;
  late final _searchCtrl = TextEditingController(text: widget.initialQuery);
  bool _showDismissed = false;
  RecipeFilter _filter = RecipeFilter.none;
  late final _facets = recipeTagFacets(widget.recipes);

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _isDismissed(Recipe r) => widget.dismissedRecipeIds.contains(r.id);

  int get _dismissedCount => widget.recipes.where(_isDismissed).length;

  List<Recipe> get _filtered => filterPickerRecipes(
    widget.recipes,
    query: _query,
    filter: _filter,
    dismissedRecipeIds: widget.dismissedRecipeIds,
    showDismissed: _showDismissed,
  );

  bool get _hasFreeTile => widget.freeNameAlways || _query.trim().isNotEmpty;

  bool get _hasAiTile => _hasFreeTile && widget.onGenerateIdeas != null;

  /// Lignes fixes en tête de liste : la saisie libre, puis l'IA.
  int get _headOffset => (_hasFreeTile ? 1 : 0) + (_hasAiTile ? 1 : 0);

  bool get _hasFacets =>
      _facets.dishTypes.isNotEmpty || _facets.cuisines.isNotEmpty;

  Recipe _freeRecipe(String name) => Recipe(
    id: '',
    titre: name,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: '',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );

  Future<void> _askFreeName(BuildContext sheetContext) async {
    final ctrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Nom du repas'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'ex: Tartines, Restes…'),
          onSubmitted: (v) => Navigator.pop(dCtx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (result == null || result.isEmpty) return;
    if (sheetContext.mounted) Navigator.pop(sheetContext, _freeRecipe(result));
  }

  /// Ouvre la feuille d'idées ; ce qui est tapé dans la recherche sert de
  /// première consigne. La recette retenue sort du sélecteur : enregistrée
  /// quand [RecipePickerSheet.onConceiveIdea] est fourni, libre sinon.
  Future<void> _askAiIdeas(BuildContext sheetContext) async {
    final generate = widget.onGenerateIdeas;
    if (generate == null) return;
    final recipe = await showMealIdeasSheet(
      context,
      generate: generate,
      conceive: widget.onConceiveIdea,
      initialPrompt: _query.trim(),
    );
    if (recipe == null) return;
    if (sheetContext.mounted) Navigator.pop(sheetContext, recipe);
  }

  /// La feuille des filtres : deux groupes de puces, cochables à plusieurs.
  Future<void> _openFilters() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          void apply(RecipeFilter next) {
            setSheetState(() {});
            setState(() => _filter = next);
          }

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Filtrer les recettes',
                          style: Theme.of(ctx).textTheme.titleMedium,
                        ),
                      ),
                      TextButton(
                        onPressed: _filter.isEmpty
                            ? null
                            : () => apply(RecipeFilter.none),
                        child: const Text('Effacer'),
                      ),
                    ],
                  ),
                ),
                RecipeFacetChipGroup(
                  title: 'Type de plat',
                  facets: _facets.dishTypes,
                  selected: _filter.dishTypes,
                  onToggle: (key) => apply(_filter.toggleDishType(key)),
                ),
                RecipeFacetChipGroup(
                  title: 'Cuisine',
                  facets: _facets.cuisines,
                  selected: _filter.cuisines,
                  onToggle: (key) => apply(_filter.toggleCuisine(key)),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Voir les recettes'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        final filtered = _filtered;
        final headOffset = _headOffset;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.hintText,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _hasFacets
                      ? IconButton(
                          tooltip: 'Filtrer par type de plat ou cuisine',
                          onPressed: _openFilters,
                          icon: Badge.count(
                            count: _filter.count,
                            isLabelVisible: !_filter.isEmpty,
                            child: Icon(
                              _filter.isEmpty
                                  ? Icons.filter_alt_outlined
                                  : Icons.filter_alt,
                            ),
                          ),
                        )
                      : null,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (!_filter.isEmpty || _dismissedCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final facet in _facets.dishTypes)
                      if (_filter.dishTypes.contains(facet.key))
                        InputChip(
                          label: Text(facet.label),
                          onDeleted: () => setState(
                            () => _filter = _filter.toggleDishType(facet.key),
                          ),
                        ),
                    for (final facet in _facets.cuisines)
                      if (_filter.cuisines.contains(facet.key))
                        InputChip(
                          label: Text(facet.label),
                          onDeleted: () => setState(
                            () => _filter = _filter.toggleCuisine(facet.key),
                          ),
                        ),
                    if (_dismissedCount > 0)
                      FilterChip(
                        label: Text(
                          'Écartées pour ce ${widget.dismissedFrom} '
                          '($_dismissedCount)',
                        ),
                        selected: _showDismissed,
                        onSelected: (v) => setState(() => _showDismissed = v),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: filtered.isEmpty && !_hasFreeTile
                  ? Center(
                      child: Text(
                        'Aucune recette ne correspond.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: scrollController,
                      itemCount: filtered.length + headOffset,
                      itemBuilder: (_, i) {
                        if (_hasFreeTile && i == 0) {
                          final name = _query.trim();
                          return ListTile(
                            leading: const CircleAvatar(
                              child: Icon(
                                Icons.edit_outlined,
                                size: AppIconSize.small,
                              ),
                            ),
                            title: Text(
                              name.isEmpty
                                  ? 'Saisir un nom libre…'
                                  : '« $name »',
                            ),
                            subtitle: const Text(
                              'Repas libre (sans recette liée)',
                            ),
                            onTap: name.isEmpty
                                ? () => _askFreeName(ctx)
                                : () => Navigator.pop(ctx, _freeRecipe(name)),
                          );
                        }
                        if (_hasAiTile && i == 1) {
                          return ListTile(
                            leading: const CircleAvatar(
                              child: Icon(
                                Icons.auto_awesome,
                                size: AppIconSize.small,
                              ),
                            ),
                            title: const Text('Générer avec l\'IA…'),
                            subtitle: Text(
                              widget.onConceiveIdea == null
                                  ? 'Trois idées sur une consigne, à affiner'
                                  : 'Trois idées sur une consigne ; la recette '
                                        'retenue est rédigée et enregistrée',
                            ),
                            onTap: () => _askAiIdeas(ctx),
                          );
                        }
                        final r = filtered[i - headOffset];
                        final prep = r.tags.prepTime;
                        final cook = r.tags.cookTime;
                        final times = [
                          if (prep != null) '${prep}min prép',
                          if (cook != null) '${cook}min cuisson',
                        ].join(' + ');
                        final subtitle = [
                          if (r.isPrivate && r.bookTitre != null) r.bookTitre!,
                          if (times.isNotEmpty) times,
                          if (_isDismissed(r))
                            'écartée pour ce ${widget.dismissedFrom}',
                        ].join(' · ');
                        return ListTile(
                          title: Text(r.titre),
                          subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
                          trailing: r.isPrivate
                              ? Tooltip(
                                  message: 'Seul le titre est visible',
                                  child: Icon(
                                    Icons.lock_outline,
                                    size: AppIconSize.small,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, r),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
