import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../books/domain/book.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import 'recipe_list_widgets.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../../core/theme/app_icon_size.dart';

enum RecipeListSortMode { page, cuisine, dishType }

enum RecipeListPageFilter { recipes, contents, all }

// ── Book Body ─────────────────────────────────────────────────────────────────

class RecipeListBookBody extends StatefulWidget {
  final Book? book;
  final String? bookId;
  final String? bookTitre;
  final String? bookCoverUrl;
  final bool showUnattached;
  final AsyncValue<List<Recipe>> recipesAsync;
  final bool canEdit;

  /// Recette par recette : le lecteur peut-il la modifier ? Une recette d'un
  /// autre membre rangée dans le livre ne se modifie, ne se supprime ni ne se
  /// sélectionne que par son créateur ou un administrateur.
  final bool Function(Recipe) canModifyRecipe;
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String) onItemSelect;

  /// Relance le chargement des recettes — bouton Réessayer et geste de
  /// rafraîchissement partagent le même chemin.
  final Future<void> Function() onRetry;

  const RecipeListBookBody({
    super.key,
    required this.book,
    this.bookId,
    this.bookTitre,
    this.bookCoverUrl,
    this.showUnattached = false,
    required this.recipesAsync,
    required this.canEdit,
    required this.canModifyRecipe,
    required this.selectionMode,
    required this.selectedIds,
    required this.onItemSelect,
    required this.onRetry,
  });

  @override
  State<RecipeListBookBody> createState() => _RecipeListBookBodyState();
}

class _RecipeListBookBodyState extends State<RecipeListBookBody> {
  bool _recipesExpanded = true;
  RecipeListSortMode _sortMode = RecipeListSortMode.page;
  bool _pageAsc = true;
  RecipeListPageFilter _pageFilter = RecipeListPageFilter.all;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allRecipes = widget.recipesAsync.value ?? [];
    final pageFiltered = switch (_pageFilter) {
      RecipeListPageFilter.recipes =>
        allRecipes.where((r) => r.pageType == PageType.recipe).toList(),
      RecipeListPageFilter.contents =>
        allRecipes.where((r) => r.pageType != PageType.recipe).toList(),
      RecipeListPageFilter.all => allRecipes,
    };
    final query = _searchQuery.trim().toLowerCase();
    final recipes = query.isEmpty
        ? pageFiltered
        : pageFiltered
              .where((r) => r.titre.toLowerCase().contains(query))
              .toList();
    final theme = Theme.of(context);

    return CustomScrollView(
      slivers: [
        // ── Section "À propos" ────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('À propos'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedAlignment: Alignment.topLeft,
              children: [
                if (widget.book == null)
                  const Center(child: CircularProgressIndicator())
                else
                  BookAboutContent(book: widget.book!),
              ],
            ),
          ),
        ),

        const SliverToBoxAdapter(child: Divider(height: 1)),

        // ── En-tête section Recettes ────────────────────────────────────
        SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () =>
                      setState(() => _recipesExpanded = !_recipesExpanded),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 0, 14),
                    child: Row(
                      children: [
                        const Icon(Icons.restaurant_menu_outlined),
                        const SizedBox(width: 8),
                        Text(
                          'Recettes',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (recipes.isNotEmpty)
                          Chip(
                            label: Text('${recipes.length}'),
                            labelStyle: theme.textTheme.labelSmall,
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        const Spacer(),
                        Icon(
                          _recipesExpanded
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Sélecteur de tri + filtre cyclant ───────────────────────────
        if (_recipesExpanded)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final mode in RecipeListSortMode.values)
                        ChoiceChip(
                          label: Text(
                            mode == RecipeListSortMode.page &&
                                    _sortMode == RecipeListSortMode.page
                                ? '${_sortModeLabel(mode)} ${_pageAsc ? '↑' : '↓'}'
                                : _sortModeLabel(mode),
                          ),
                          avatar: Icon(
                            _sortModeIcon(mode),
                            size: AppIconSize.inline,
                          ),
                          selected: _sortMode == mode,
                          onSelected: (_) => setState(() {
                            if (_sortMode == mode &&
                                mode == RecipeListSortMode.page) {
                              _pageAsc = !_pageAsc;
                            } else {
                              _sortMode = mode;
                            }
                          }),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
                  ),
                  const Spacer(),
                  Tooltip(
                    message: _pageFilterLabel(_pageFilter),
                    child: IconButton(
                      icon: Icon(_pageFilterIcon(_pageFilter)),
                      onPressed: () => setState(
                        () => _pageFilter = _nextPageFilter(_pageFilter),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // ── Filtre texte sur les titres ─────────────────────────────────
        if (_recipesExpanded)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _searchQuery = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filtrer par titre\u2026',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Effacer',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),

        // ── Chargement / erreur ─────────────────────────────────────────
        if (widget.recipesAsync.isLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: AppLoadingState(),
            ),
          ),
        if (widget.recipesAsync.hasError)
          SliverToBoxAdapter(
            child: AppErrorState(
              error: widget.recipesAsync.error,
              onRetry: widget.onRetry,
            ),
          ),

        // ── Liste des recettes (si section ouverte) ─────────────────────
        if (_recipesExpanded && !widget.recipesAsync.isLoading)
          ..._buildRecipeSlivers(recipes, widget.canEdit),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  // ── Helpers tri / groupement ──────────────────────────────────────────────

  String _sortModeLabel(RecipeListSortMode mode) => switch (mode) {
    RecipeListSortMode.page => 'Page',
    RecipeListSortMode.cuisine => 'Cuisine',
    RecipeListSortMode.dishType => 'Type de plat',
  };

  IconData _sortModeIcon(RecipeListSortMode mode) => switch (mode) {
    RecipeListSortMode.page => Icons.format_list_numbered,
    RecipeListSortMode.cuisine => Icons.public_outlined,
    RecipeListSortMode.dishType => Icons.restaurant_outlined,
  };

  String _pageFilterLabel(RecipeListPageFilter f) => switch (f) {
    RecipeListPageFilter.recipes => 'Recettes seulement',
    RecipeListPageFilter.contents => 'Contenus seulement',
    RecipeListPageFilter.all => 'Tout afficher',
  };

  IconData _pageFilterIcon(RecipeListPageFilter f) => switch (f) {
    RecipeListPageFilter.all => Icons.layers,
    RecipeListPageFilter.recipes => Icons.restaurant_outlined,
    RecipeListPageFilter.contents => Icons.auto_stories_outlined,
  };

  RecipeListPageFilter _nextPageFilter(RecipeListPageFilter f) => switch (f) {
    RecipeListPageFilter.all => RecipeListPageFilter.recipes,
    RecipeListPageFilter.recipes => RecipeListPageFilter.contents,
    RecipeListPageFilter.contents => RecipeListPageFilter.all,
  };

  List<Widget> _buildRecipeSlivers(List<Recipe> recipes, bool canEdit) {
    final theme = Theme.of(context);
    bool editable(Recipe r) => canEdit && widget.canModifyRecipe(r);
    // En mode sélection, la page d'un autre est grisée et ne réagit pas : elle
    // ne se sélectionne pas, et l'ouvrir ferait perdre la sélection.
    Widget lockedInSelection(Recipe r, Widget child) =>
        widget.selectionMode && !editable(r)
        ? IgnorePointer(child: Opacity(opacity: 0.38, child: child))
        : child;

    if (recipes.isEmpty) {
      final emptyText = _searchQuery.trim().isEmpty
          ? 'Aucune recette dans ce livre'
          : 'Aucun titre ne correspond à « ${_searchQuery.trim()} »';
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: Text(
                emptyText,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ];
    }

    if (_sortMode == RecipeListSortMode.page) {
      final sorted = [...recipes]
        ..sort((a, b) {
          if (a.pageNumber == null && b.pageNumber == null) {
            return a.titre.compareTo(b.titre);
          }
          if (a.pageNumber == null) return 1;
          if (b.pageNumber == null) return -1;
          return _pageAsc
              ? a.pageNumber!.compareTo(b.pageNumber!)
              : b.pageNumber!.compareTo(a.pageNumber!);
        });
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          sliver: SliverList.separated(
            itemCount: sorted.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => lockedInSelection(
              sorted[i],
              sorted[i].pageType != PageType.recipe
                  ? BookPageTile(
                      recipe: sorted[i],
                      bookId: widget.bookId,
                      bookTitre: widget.bookTitre,
                      bookCoverUrl: widget.bookCoverUrl,
                      showUnattached: widget.showUnattached,
                      selectionMode:
                          editable(sorted[i]) && widget.selectionMode,
                      isSelected: widget.selectedIds.contains(sorted[i].id),
                      onSelect: editable(sorted[i])
                          ? () => widget.onItemSelect(sorted[i].id)
                          : null,
                    )
                  : RecipeCard(
                      recipe: sorted[i],
                      inBookContext: true,
                      bookId: widget.bookId,
                      bookTitre: widget.bookTitre,
                      bookCoverUrl: widget.bookCoverUrl,
                      showUnattached: widget.showUnattached,
                      canEdit: editable(sorted[i]),
                      selectionMode:
                          editable(sorted[i]) && widget.selectionMode,
                      isSelected: widget.selectedIds.contains(sorted[i].id),
                      onSelect: editable(sorted[i])
                          ? () => widget.onItemSelect(sorted[i].id)
                          : null,
                    ),
            ),
          ),
        ),
      ];
    }

    // Groupement par cuisine ou type de plat
    final Map<String, List<Recipe>> groups = {};
    for (final recipe in recipes) {
      final List<String> keys;
      if (_sortMode == RecipeListSortMode.cuisine) {
        keys = recipe.tags.cuisines.isEmpty ? ['Autre'] : recipe.tags.cuisines;
      } else {
        keys = recipe.tags.themes.isEmpty ? ['Autre'] : recipe.tags.themes;
      }
      for (final key in keys) {
        (groups[key] ??= []).add(recipe);
      }
    }

    final sortedKeys = groups.keys.toList()
      ..sort((a, b) {
        if (a == 'Autre') return 1;
        if (b == 'Autre') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final slivers = <Widget>[];
    for (final key in sortedKeys) {
      final groupRecipes = [...groups[key]!]
        ..sort((a, b) => a.titre.compareTo(b.titre));
      slivers.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              key.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          sliver: SliverList.separated(
            itemCount: groupRecipes.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => lockedInSelection(
              groupRecipes[i],
              groupRecipes[i].pageType != PageType.recipe
                  ? BookPageTile(
                      recipe: groupRecipes[i],
                      bookId: widget.bookId,
                      bookTitre: widget.bookTitre,
                      bookCoverUrl: widget.bookCoverUrl,
                      showUnattached: widget.showUnattached,
                      selectionMode:
                          editable(groupRecipes[i]) && widget.selectionMode,
                      isSelected: widget.selectedIds.contains(
                        groupRecipes[i].id,
                      ),
                      onSelect: editable(groupRecipes[i])
                          ? () => widget.onItemSelect(groupRecipes[i].id)
                          : null,
                    )
                  : RecipeCard(
                      recipe: groupRecipes[i],
                      inBookContext: true,
                      bookId: widget.bookId,
                      bookTitre: widget.bookTitre,
                      bookCoverUrl: widget.bookCoverUrl,
                      showUnattached: widget.showUnattached,
                      canEdit: editable(groupRecipes[i]),
                      selectionMode:
                          editable(groupRecipes[i]) && widget.selectionMode,
                      isSelected: widget.selectedIds.contains(
                        groupRecipes[i].id,
                      ),
                      onSelect: editable(groupRecipes[i])
                          ? () => widget.onItemSelect(groupRecipes[i].id)
                          : null,
                    ),
            ),
          ),
        ),
      );
    }
    return slivers;
  }
}

// ── Free Recipes Body ─────────────────────────────────────────────────────────

class RecipeListFreeBody extends ConsumerStatefulWidget {
  final AsyncValue<List<Recipe>> myRecipesAsync;
  final bool canEdit;
  final bool selectionMode;
  final Set<String> selectedIds;
  final void Function(String) onItemSelect;

  /// Voir [RecipeListBookBody.onRetry].
  final Future<void> Function() onRetry;

  const RecipeListFreeBody({
    super.key,
    required this.myRecipesAsync,
    required this.canEdit,
    required this.selectionMode,
    required this.selectedIds,
    required this.onItemSelect,
    required this.onRetry,
  });

  @override
  ConsumerState<RecipeListFreeBody> createState() => _RecipeListFreeBodyState();
}

class _RecipeListFreeBodyState extends ConsumerState<RecipeListFreeBody> {
  final Set<String> _hiddenOwnerUids = {};

  void _toggleSection(String uid) {
    setState(() {
      if (_hiddenOwnerUids.contains(uid)) {
        _hiddenOwnerUids.remove(uid);
      } else {
        _hiddenOwnerUids.add(uid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';
    final groupRecipesAsync = ref.watch(groupMemberUnattachedRecipesProvider);

    // Group member recipes by ownerUid
    final recipesByOwner = <String, List<Recipe>>{};
    for (final r in groupRecipesAsync.value ?? []) {
      (recipesByOwner[r.createdBy] ??= []).add(r);
    }

    return widget.myRecipesAsync.when(
      loading: () => const AppLoadingState(),
      error: (e, _) => AppErrorState(error: e, onRetry: widget.onRetry),
      data: (myRecipes) {
        if (myRecipes.isEmpty && recipesByOwner.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.restaurant_menu_outlined,
                  size: AppIconSize.hero,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  'Aucune recette libre\nValidez un brouillon sans livre pour en créer',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        return CustomScrollView(
          slivers: [
            // ── Mes recettes libres ──────────────────────────────────────────
            RecipeSectionHeader(
              title: 'Mes recettes libres',
              count: myRecipes.length,
              expanded: !_hiddenOwnerUids.contains(myUid),
              onToggle: () => _toggleSection(myUid),
            ),
            if (!_hiddenOwnerUids.contains(myUid))
              myRecipes.isEmpty
                  ? const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text('Aucune recette libre'),
                      ),
                    )
                  : SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      sliver: SliverList.separated(
                        itemCount: myRecipes.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => RecipeCard(
                          recipe: myRecipes[i],
                          inBookContext: false,
                          canEdit: widget.canEdit,
                          selectionMode: widget.canEdit && widget.selectionMode,
                          isSelected: widget.selectedIds.contains(
                            myRecipes[i].id,
                          ),
                          onSelect: widget.canEdit
                              ? () => widget.onItemSelect(myRecipes[i].id)
                              : null,
                        ),
                      ),
                    ),

            // ── Recettes des membres ─────────────────────────────────────────
            for (final entry in recipesByOwner.entries) ...[
              RecipeMemberSectionHeader(
                ownerUid: entry.key,
                count: entry.value.length,
                expanded: !_hiddenOwnerUids.contains(entry.key),
                onToggle: () => _toggleSection(entry.key),
              ),
              if (!_hiddenOwnerUids.contains(entry.key))
                SliverPadding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  sliver: SliverList.separated(
                    itemCount: entry.value.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => RecipeCard(
                      recipe: entry.value[i],
                      inBookContext: false,
                      canEdit: false,
                    ),
                  ),
                ),
            ],

            const SliverToBoxAdapter(child: SizedBox(height: 80)),
          ],
        );
      },
    );
  }
}
