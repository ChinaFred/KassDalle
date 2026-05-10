import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/domain/book.dart';
import '../../../books/presentation/book_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../source_viewer.dart';
import '../recipe_rating_widget.dart';

enum _SortMode { page, cuisine, dishType }

class RecipeListScreen extends ConsumerStatefulWidget {
  final String? bookId;
  final String? bookTitre;
  final String? bookCoverUrl;
  const RecipeListScreen({
    super.key,
    this.bookId,
    this.bookTitre,
    this.bookCoverUrl,
  });

  @override
  ConsumerState<RecipeListScreen> createState() => _RecipeListScreenState();
}

class _RecipeListScreenState extends ConsumerState<RecipeListScreen> {
  final Set<String> _hiddenOwnerUids = {};
  bool _recipesExpanded = true;
  _SortMode _sortMode = _SortMode.page;

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
    final canEdit = ref.watch(canEditProvider);
    final inBookContext = (widget.bookId ?? '').isNotEmpty;

    // Badge "à valider" selon le contexte
    final draftCount = inBookContext
        ? ref.watch(draftsByBookCountProvider(widget.bookId!)).value ?? 0
        : ref.watch(draftsUnattachedCountProvider).value ?? 0;

    final AsyncValue<List<Recipe>> recipesAsync = inBookContext
        ? ref.watch(recipesByBookProvider(widget.bookId!))
        : ref.watch(unattachedRecipesProvider);

    // Chargement des métadonnées du livre pour la section "À propos"
    final bookAsync = inBookContext
        ? ref.watch(bookByIdProvider(widget.bookId!))
        : const AsyncData<Book?>(null);

    final hasCover = inBookContext && (widget.bookCoverUrl ?? '').isNotEmpty;

    final titleWidget = inBookContext
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasCover) ...[
                GestureDetector(
                  onTap: () => _showCoverZoom(context, widget.bookCoverUrl!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      widget.bookCoverUrl!,
                      width: 32,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(widget.bookTitre ?? 'Recettes du livre'),
            ],
          )
        : const Text('Recettes libres');

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: titleWidget,
        actions: [
          if (draftCount > 0)
            IconButton(
              tooltip: 'Recettes à valider',
              onPressed: () => context.push('/drafts'),
              icon: Badge(
                label: Text('$draftCount'),
                child: const Icon(Icons.edit_note_outlined),
              ),
            ),
          if (inBookContext && canEdit) ...[
            IconButton(
              tooltip: 'Modifier le livre',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/books/${widget.bookId}/edit'),
            ),
            IconButton(
              tooltip: 'Scanner des pages dans ce livre',
              icon: const Icon(Icons.photo_camera_outlined),
              onPressed: () => _goToScan(context),
            ),
            IconButton(
              tooltip: 'Attacher des recettes validées',
              icon: const Icon(Icons.link_outlined),
              onPressed: () => _showAttachDialog(context),
            ),
          ],
          if (inBookContext &&
              (bookAsync.value?.sourceFileUrl ?? '').isNotEmpty)
            SourceViewerButton(
              sourceFileUrl: bookAsync.value?.sourceFileUrl,
              sourceFileName: bookAsync.value?.sourceFileName,
            ),
        ],
      ),
      body: inBookContext
          ? _buildBookBody(
              context,
              bookAsync.value,
              recipesAsync,
              canEdit,
              hasCover,
            )
          : _buildFreeRecipesBody(context, recipesAsync, canEdit),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => inBookContext
                  ? _showAddActions(context)
                  : _showAddFreeActions(context),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter'),
            )
          : null,
    );
  }

  // ── Livre : corps avec sections rétractables ─────────────────────────────

  Widget _buildBookBody(
    BuildContext context,
    Book? book,
    AsyncValue<List<Recipe>> recipesAsync,
    bool canEdit,
    bool hasCover,
  ) {
    final recipes = recipesAsync.value ?? [];
    final theme = Theme.of(context);

    return CustomScrollView(
      slivers: [
        // ── Section "À propos" ────────────────────────────────────────────
        SliverToBoxAdapter(
          child: Theme(
            // Supprime le padding par défaut de ExpansionTile en mode MaterialApp
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('À propos'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              expandedAlignment: Alignment.topLeft,
              children: [
                if (book == null)
                  const Center(child: CircularProgressIndicator())
                else
                  _BookAboutContent(book: book),
              ],
            ),
          ),
        ),

        const SliverToBoxAdapter(child: Divider(height: 1)),

        // ── En-tête section Recettes ────────────────────────────────────
        SliverToBoxAdapter(
          child: InkWell(
            onTap: () => setState(() => _recipesExpanded = !_recipesExpanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
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

        // ── Sélecteur de tri ─────────────────────────────────────────────
        if (_recipesExpanded)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final mode in _SortMode.values)
                    ChoiceChip(
                      label: Text(_sortModeLabel(mode)),
                      avatar: Icon(_sortModeIcon(mode), size: 16),
                      selected: _sortMode == mode,
                      onSelected: (_) => setState(() => _sortMode = mode),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
          ),

        // ── Chargement / erreur ─────────────────────────────────────────
        if (recipesAsync.isLoading)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
        if (recipesAsync.hasError)
          SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Erreur : ${recipesAsync.error}'),
              ),
            ),
          ),

        // ── Liste des recettes (si section ouverte) ─────────────────────
        if (_recipesExpanded && !recipesAsync.isLoading)
          ..._buildRecipeSlivers(recipes, canEdit),

        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }

  // ── Helpers tri / groupement ────────────────────────────────────────────────

  String _sortModeLabel(_SortMode mode) => switch (mode) {
    _SortMode.page => 'Page',
    _SortMode.cuisine => 'Cuisine',
    _SortMode.dishType => 'Type de plat',
  };

  IconData _sortModeIcon(_SortMode mode) => switch (mode) {
    _SortMode.page => Icons.format_list_numbered,
    _SortMode.cuisine => Icons.public_outlined,
    _SortMode.dishType => Icons.restaurant_outlined,
  };

  List<Widget> _buildRecipeSlivers(List<Recipe> recipes, bool canEdit) {
    final theme = Theme.of(context);

    if (recipes.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: Center(
              child: Text(
                'Aucune recette dans ce livre',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ];
    }

    if (_sortMode == _SortMode.page) {
      final sorted = [...recipes]
        ..sort((a, b) {
          if (a.pageNumber == null && b.pageNumber == null) {
            return a.titre.compareTo(b.titre);
          }
          if (a.pageNumber == null) return 1;
          if (b.pageNumber == null) return -1;
          return a.pageNumber!.compareTo(b.pageNumber!);
        });
      return [
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          sliver: SliverList.separated(
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _RecipeCard(
              recipe: sorted[i],
              inBookContext: true,
              canEdit: canEdit,
            ),
          ),
        ),
      ];
    }

    // Groupement par cuisine ou type de plat
    final Map<String, List<Recipe>> groups = {};
    for (final recipe in recipes) {
      final List<String> keys;
      if (_sortMode == _SortMode.cuisine) {
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
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) => _RecipeCard(
              recipe: groupRecipes[i],
              inBookContext: true,
              canEdit: canEdit,
            ),
          ),
        ),
      );
    }
    return slivers;
  }

  // ── Ancien corps livre (supprimé, remplacé par _buildBookBody) ─────────────
  // ignore: unused_element
  Widget _buildBookRecipesBody(
    BuildContext context,
    AsyncValue<List<Recipe>> recipesAsync,
    bool canEdit,
  ) {
    return _buildBookBody(
      context,
      null,
      recipesAsync,
      canEdit,
      (widget.bookCoverUrl ?? '').isNotEmpty,
    );
  }

  Widget _buildFreeRecipesBody(
    BuildContext context,
    AsyncValue<List<Recipe>> myRecipesAsync,
    bool canEdit,
  ) {
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';
    final groupRecipesAsync = ref.watch(groupMemberUnattachedRecipesProvider);

    // Group member recipes by ownerUid
    final recipesByOwner = <String, List<Recipe>>{};
    for (final r in groupRecipesAsync.value ?? []) {
      (recipesByOwner[r.createdBy] ??= []).add(r);
    }

    return myRecipesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Erreur : $e')),
      data: (myRecipes) {
        if (myRecipes.isEmpty && recipesByOwner.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.restaurant_menu_outlined,
                  size: 64,
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
            _RecipeSectionHeader(
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
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _RecipeCard(
                          recipe: myRecipes[i],
                          inBookContext: false,
                          canEdit: canEdit,
                        ),
                      ),
                    ),

            // ── Recettes des membres ─────────────────────────────────────────
            for (final entry in recipesByOwner.entries) ...[
              _RecipeMemberSectionHeader(
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
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _RecipeCard(
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

  void _showCoverZoom(BuildContext context, String coverUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                child: CachedNetworkImage(
                  imageUrl: coverUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, __) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorWidget: (_, __, ___) => const Icon(
                    Icons.broken_image,
                    size: 64,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filled(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goToScan(BuildContext context) {
    context.go(
      '/scan?mode=recipe&bookId=${widget.bookId}&bookTitre=${Uri.encodeQueryComponent(widget.bookTitre ?? '')}',
    );
  }

  void _goToScanFree(BuildContext context) {
    context.go('/scan?mode=recipe');
  }

  void _showAddFreeActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Scanner / importer un fichier'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _goToScanFree(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Saisie manuelle'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go('/recipes/new');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAttachDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _AttachRecipesDialog(
        bookId: widget.bookId!,
        bookTitre: widget.bookTitre ?? 'Livre',
      ),
    );
  }

  void _showAddActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Scanner des pages'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _goToScan(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Saisie manuelle'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go(
                  '/recipes/new'
                  '?bookId=${Uri.encodeQueryComponent(widget.bookId!)}'
                  '&bookTitre=${Uri.encodeQueryComponent(widget.bookTitre ?? '')}',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: const Text('Attacher des recettes validées'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showAttachDialog(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── En-têtes de section recettes libres ───────────────────────────────────────

class _RecipeSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _RecipeSectionHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Chip(
                label: Text('$count'),
                labelStyle: theme.textTheme.labelSmall,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              Icon(
                expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipeMemberSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _RecipeMemberSectionHeader({
    required this.ownerUid,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userByUidProvider(ownerUid));
    final name = userAsync.value?.displayName ?? '…';
    return _RecipeSectionHeader(
      title: 'Recettes libres de $name',
      count: count,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

// ── Contenu "À propos" du livre ────────────────────────────────────────────────

class _BookAboutContent extends StatelessWidget {
  final Book book;
  const _BookAboutContent({required this.book});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget infoRow(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        infoRow('Auteur', book.auteur),
        if ((book.sousTitre ?? '').isNotEmpty)
          infoRow('Sous-titre', book.sousTitre!),
        if ((book.editeur ?? '').isNotEmpty) infoRow('Éditeur', book.editeur!),
        if ((book.serie ?? '').isNotEmpty) infoRow('Série', book.serie!),
        if (book.annee != null) infoRow('Année', '${book.annee}'),
        infoRow('Langue', book.langue),
        if ((book.isbn ?? '').isNotEmpty) infoRow('ISBN', book.isbn!),
        if ((book.description ?? '').isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Description',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(book.description!, style: theme.textTheme.bodyMedium),
        ],
        if (book.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: book.tags
                .map(
                  (t) => Chip(
                    label: Text(t),
                    labelStyle: theme.textTheme.labelSmall,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                )
                .toList(),
          ),
        ],
      ],
    );
  }
}

class _AttachRecipesDialog extends ConsumerStatefulWidget {
  final String bookId;
  final String bookTitre;

  const _AttachRecipesDialog({required this.bookId, required this.bookTitre});

  @override
  ConsumerState<_AttachRecipesDialog> createState() =>
      _AttachRecipesDialogState();
}

class _AttachRecipesDialogState extends ConsumerState<_AttachRecipesDialog> {
  final Set<String> _selected = <String>{};
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final unattachedAsync = ref.watch(unattachedRecipesProvider);

    return AlertDialog(
      title: const Text('Attacher des recettes validées'),
      content: SizedBox(
        width: 560,
        child: unattachedAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Text('Erreur : $e'),
          data: (recipes) {
            if (recipes.isEmpty) {
              return const Text('Aucune recette validée libre à attacher.');
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${recipes.length} recette(s) disponible(s)',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: recipes.length,
                    itemBuilder: (context, i) {
                      final r = recipes[i];
                      final checked = _selected.contains(r.id);
                      return CheckboxListTile(
                        value: checked,
                        onChanged: _saving
                            ? null
                            : (v) {
                                setState(() {
                                  if (v == true) {
                                    _selected.add(r.id);
                                  } else {
                                    _selected.remove(r.id);
                                  }
                                });
                              },
                        title: Text(r.titre),
                        subtitle: Text(
                          r.portions == null
                              ? 'Sans portions'
                              : '${r.portions} portions',
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton.icon(
          onPressed: _saving || _selected.isEmpty
              ? null
              : () async {
                  setState(() => _saving = true);
                  try {
                    await ref
                        .read(recipeRepositoryProvider)
                        .attachValidatedRecipesToBook(
                          recipeIds: _selected.toList(),
                          bookId: widget.bookId,
                          bookTitre: widget.bookTitre,
                        );
                    if (!context.mounted) return;
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          '${_selected.length} recette(s) attachée(s) au livre.',
                        ),
                      ),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                },
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.link),
          label: Text('Attacher (${_selected.length})'),
        ),
      ],
    );
  }
}

class _RecipeCard extends ConsumerWidget {
  final Recipe recipe;
  final bool inBookContext;
  final bool canEdit;

  const _RecipeCard({
    required this.recipe,
    required this.inBookContext,
    required this.canEdit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final annotations =
        ref.watch(annotationsProvider(recipe.id)).value ?? [];
    final noteCount = annotations
        .where((a) => a.type == AnnotationType.note)
        .length;
    final tipCount = annotations
        .where((a) => a.type == AnnotationType.tip)
        .length;
    final corrCount = annotations
        .where((a) => a.type == AnnotationType.correction)
        .length;

    void goToAnnotations() =>
        context.push('/recipes/${recipe.id}?anchor=annotations');

    final badges = [
      if (noteCount > 0)
        _AnnotBadge(
          icon: Icons.sticky_note_2_outlined,
          count: noteCount,
          color: _annotNoteColor(theme),
          foregroundColor: _annotNoteFg(theme),
          onTap: goToAnnotations,
        ),
      if (tipCount > 0)
        _AnnotBadge(
          icon: Icons.lightbulb_outline,
          count: tipCount,
          color: theme.colorScheme.tertiaryContainer,
          foregroundColor: theme.colorScheme.onTertiaryContainer,
          onTap: goToAnnotations,
        ),
      if (corrCount > 0)
        _AnnotBadge(
          icon: Icons.build_circle_outlined,
          count: corrCount,
          color: theme.colorScheme.errorContainer,
          foregroundColor: theme.colorScheme.onErrorContainer,
          onTap: goToAnnotations,
        ),
    ];

    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.restaurant,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Row(
          children: [
            Expanded(child: Text(recipe.titre)),
            if (recipe.pageNumber != null) ...[
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'p.${recipe.pageNumber}',
                  style: TextStyle(
                    fontSize: 10,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            RecipeRatingBadge(recipeId: recipe.id),
            if (badges.isNotEmpty) ...[const SizedBox(width: 4), ...badges],
          ],
        ),
        subtitle: (!inBookContext && recipe.bookTitre != null)
            ? Text(recipe.bookTitre!)
            : null,
        trailing: canEdit
            ? _RecipeActionsMenu(recipe: recipe, inBookContext: inBookContext)
            : const Icon(Icons.chevron_right),
        onTap: () => context.push('/recipes/${recipe.id}'),
      ),
    );
  }
}

class _AnnotBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;
  const _AnnotBadge({
    required this.icon,
    required this.count,
    required this.color,
    required this.foregroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: foregroundColor),
            if (count > 0) ...[
              const SizedBox(width: 3),
              Text(
                '$count',
                style: TextStyle(fontSize: 11, color: foregroundColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecipeActionsMenu extends ConsumerWidget {
  final Recipe recipe;
  final bool inBookContext;

  const _RecipeActionsMenu({required this.recipe, required this.inBookContext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_RecipeAction>(
      tooltip: 'Actions recette',
      onSelected: (action) async {
        if (action == _RecipeAction.detach) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Détacher la recette ?'),
              content: Text(
                'La recette "${recipe.titre}" sera retirée du livre et restera disponible en recette libre.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Détacher'),
                ),
              ],
            ),
          );
          if (confirmed != true || !context.mounted) return;
          try {
            await ref
                .read(recipeRepositoryProvider)
                .detachRecipeFromBook(recipe.id);
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Recette détachée du livre.')),
            );
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
          }
        } else if (action == _RecipeAction.edit) {
          if (!context.mounted) return;
          context.push('/recipes/${recipe.id}/edit');
        } else if (action == _RecipeAction.annotate) {
          if (!context.mounted) return;
          context.push('/recipes/${recipe.id}?anchor=annotations');
        } else if (action == _RecipeAction.delete) {
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Supprimer la recette ?'),
              content: Text(
                'La recette "${recipe.titre}" sera supprimée définitivement.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Annuler'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Supprimer'),
                ),
              ],
            ),
          );
          if (confirmed != true || !context.mounted) return;
          try {
            await ref.read(recipeRepositoryProvider).deleteRecipe(recipe.id);
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Recette supprimée.')));
          } catch (e) {
            if (!context.mounted) return;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
          }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem<_RecipeAction>(
          value: _RecipeAction.edit,
          child: Row(
            children: [
              Icon(Icons.edit_outlined),
              SizedBox(width: 8),
              Text('Modifier'),
            ],
          ),
        ),
        const PopupMenuItem<_RecipeAction>(
          value: _RecipeAction.annotate,
          child: Row(
            children: [
              Icon(Icons.comment_outlined),
              SizedBox(width: 8),
              Text('Annoter'),
            ],
          ),
        ),
        if (inBookContext)
          const PopupMenuItem<_RecipeAction>(
            value: _RecipeAction.detach,
            child: Row(
              children: [
                Icon(Icons.link_off_outlined),
                SizedBox(width: 8),
                Text('Détacher du livre'),
              ],
            ),
          ),
        const PopupMenuItem<_RecipeAction>(
          value: _RecipeAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline),
              SizedBox(width: 8),
              Text('Supprimer'),
            ],
          ),
        ),
      ],
      child: const Icon(Icons.more_vert),
    );
  }
}

enum _RecipeAction { edit, annotate, detach, delete }

// ── Couleurs fixes badge "Note" (bleu, adapté dark/light) ─────────────────────
Color _annotNoteColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF1565C0) // blue.shade800
    : const Color(0xFFBBDEFB); // blue.shade100

Color _annotNoteFg(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white
    : const Color(0xFF0D47A1); // blue.shade900
