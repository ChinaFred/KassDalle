import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';

class RecipeListScreen extends ConsumerWidget {
  final String? bookId;
  final String? bookTitre;
  const RecipeListScreen({super.key, this.bookId, this.bookTitre});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(canEditProvider);
    final inBookContext = (bookId ?? '').isNotEmpty;

    final AsyncValue<List<Recipe>> recipesAsync = inBookContext
        ? ref.watch(recipesByBookProvider(bookId!))
        : ref.watch(unattachedRecipesProvider);

    final title = inBookContext
        ? (bookTitre == null ? 'Recettes du livre' : 'Recettes - $bookTitre')
        : 'Recettes libres';

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (inBookContext && canEdit) ...[
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
            itemBuilder: (context, i) => _RecipeCard(recipe: recipes[i]),
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

  void _goToScan(BuildContext context) {
    context.go(
      '/scan?bookId=$bookId&bookTitre=${Uri.encodeQueryComponent(bookTitre ?? '')}',
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

class _RecipeCard extends StatelessWidget {
  final Recipe recipe;
  const _RecipeCard({required this.recipe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.restaurant,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(recipe.titre),
        subtitle: recipe.bookTitre != null
            ? Text(recipe.bookTitre!)
            : Text(
                'Recette libre',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/recipes/${recipe.id}'),
      ),
    );
  }
}
