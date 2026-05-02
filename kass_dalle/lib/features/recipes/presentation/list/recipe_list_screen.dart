import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';

class RecipeListScreen extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(canEditProvider);
    final inBookContext = (bookId ?? '').isNotEmpty;

    final AsyncValue<List<Recipe>> recipesAsync = inBookContext
        ? ref.watch(recipesByBookProvider(bookId!))
        : ref.watch(unattachedRecipesProvider);

    final hasCover = inBookContext && (bookCoverUrl ?? '').isNotEmpty;

    final titleWidget = inBookContext
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasCover) ...[
                GestureDetector(
                  onTap: () => _showCoverZoom(context, bookCoverUrl!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      bookCoverUrl!,
                      width: 32,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Text(bookTitre ?? 'Recettes du livre'),
            ],
          )
        : const Text('Recettes libres');

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        title: titleWidget,
        actions: [
          if (inBookContext && canEdit) ...[
            IconButton(
              tooltip: 'Modifier le livre',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => context.push('/books/$bookId/edit'),
            ),
            IconButton(
              tooltip: 'Scanner des pages dans ce livre',
              icon: const Icon(Icons.document_scanner_outlined),
              onPressed: () => _goToScan(context),
            ),
            IconButton(
              tooltip: 'Attacher des recettes validées',
              icon: const Icon(Icons.link_outlined),
              onPressed: () => _showAttachDialog(context),
            ),
          ],
        ],
      ),
      body: recipesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (recipes) {
          if (recipes.isEmpty) {
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
                    inBookContext
                        ? 'Aucune recette dans ce livre'
                        : 'Aucune recette libre\nValidez un brouillon sans livre pour en créer',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: recipes.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _RecipeCard(
              recipe: recipes[i],
              inBookContext: inBookContext,
              canEdit: canEdit,
            ),
          );
        },
      ),
      floatingActionButton: inBookContext && canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _showAddActions(context),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter'),
            )
          : null,
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
      '/scan?mode=book-document&bookId=$bookId&bookTitre=${Uri.encodeQueryComponent(bookTitre ?? '')}',
    );
  }

  void _showAttachDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _AttachRecipesDialog(
        bookId: bookId!,
        bookTitre: bookTitre ?? 'Livre',
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
              leading: const Icon(Icons.document_scanner_outlined),
              title: const Text('Scanner des pages'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _goToScan(context);
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
        ref.watch(annotationsProvider(recipe.id)).valueOrNull ?? [];
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
          color: theme.colorScheme.primaryContainer,
          onTap: goToAnnotations,
        ),
      if (tipCount > 0)
        _AnnotBadge(
          icon: Icons.lightbulb_outline,
          count: tipCount,
          color: theme.colorScheme.tertiaryContainer,
          onTap: goToAnnotations,
        ),
      if (corrCount > 0)
        _AnnotBadge(
          icon: Icons.build_circle_outlined,
          count: corrCount,
          color: theme.colorScheme.errorContainer,
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
        title: badges.isEmpty
            ? Text(recipe.titre)
            : Row(
                children: [
                  Expanded(child: Text(recipe.titre)),
                  const SizedBox(width: 4),
                  ...badges,
                ],
              ),
        subtitle: recipe.bookTitre != null
            ? Text(recipe.bookTitre!)
            : Text(
                'Recette libre',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
        trailing: inBookContext && canEdit
            ? _RecipeActionsMenu(recipe: recipe)
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
  final VoidCallback onTap;
  const _AnnotBadge({
    required this.icon,
    required this.count,
    required this.color,
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
            Icon(icon, size: 12),
            if (count > 0) ...[
              const SizedBox(width: 3),
              Text('$count', style: const TextStyle(fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

class _RecipeActionsMenu extends ConsumerWidget {
  final Recipe recipe;

  const _RecipeActionsMenu({required this.recipe});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<_RecipeAction>(
      tooltip: 'Actions recette',
      onSelected: (action) async {
        if (action != _RecipeAction.detach) return;
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
      },
      itemBuilder: (_) => const [
        PopupMenuItem<_RecipeAction>(
          value: _RecipeAction.detach,
          child: Row(
            children: [
              Icon(Icons.link_off_outlined),
              SizedBox(width: 8),
              Text('Détacher du livre'),
            ],
          ),
        ),
      ],
      child: const Icon(Icons.more_vert),
    );
  }
}

enum _RecipeAction { detach }
