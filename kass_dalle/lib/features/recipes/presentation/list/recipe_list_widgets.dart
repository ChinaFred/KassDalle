import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/domain/book.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../recipe_rating_widget.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/utils/recipe_tag_sections.dart';
import '../detail/recipe_detail_illustrations.dart';

// ── En-têtes de section ───────────────────────────────────────────────────────

class RecipeSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const RecipeSectionHeader({
    super.key,
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

class RecipeMemberSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const RecipeMemberSectionHeader({
    super.key,
    required this.ownerUid,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userByUidProvider(ownerUid));
    final name = userAsync.value?.displayName ?? '…';
    return RecipeSectionHeader(
      title: 'Recettes libres de $name',
      count: count,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

// ── Contenu "À propos" du livre ───────────────────────────────────────────────

class BookAboutContent extends StatelessWidget {
  final Book book;
  const BookAboutContent({super.key, required this.book});

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
        if (book.tags.isNotEmpty && !book.isSystemBook) ...[
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

// ── Dialogue : attacher des recettes à un livre ───────────────────────────────

class AttachRecipesDialog extends ConsumerStatefulWidget {
  final String bookId;
  final String bookTitre;

  const AttachRecipesDialog({
    super.key,
    required this.bookId,
    required this.bookTitre,
  });

  @override
  ConsumerState<AttachRecipesDialog> createState() =>
      _AttachRecipesDialogState();
}

class _AttachRecipesDialogState extends ConsumerState<AttachRecipesDialog> {
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
                    context.showSuccessSnackBar(
                      '${_selected.length} recette(s) attachée(s) au livre.',
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    context.showErrorSnackBar('Erreur : $e');
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

// ── Tuile page de livre (non-recette) ─────────────────────────────────────────

class BookPageTile extends StatelessWidget {
  final Recipe recipe;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onSelect;

  const BookPageTile({
    super.key,
    required this.recipe,
    this.selectionMode = false,
    this.isSelected = false,
    this.onSelect,
  });

  static IconData _iconForPageType(PageType t) => switch (t) {
    PageType.technique => Icons.tips_and_updates_outlined,
    PageType.equipment => Icons.kitchen_outlined,
    PageType.ingredientNote => Icons.eco_outlined,
    PageType.other => Icons.description_outlined,
    _ => Icons.description_outlined,
  };

  static String _labelForPageType(PageType t) => switch (t) {
    PageType.technique => 'Technique',
    PageType.equipment => 'Matériel',
    PageType.ingredientNote => 'Ingrédient',
    PageType.other => 'Page',
    _ => 'Page',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: isSelected ? theme.colorScheme.secondaryContainer : null,
      child: ListTile(
        leading: selectionMode
            ? Checkbox(
                value: isSelected,
                onChanged: onSelect != null ? (_) => onSelect!() : null,
              )
            : CircleAvatar(
                backgroundColor: theme.colorScheme.secondaryContainer,
                child: Icon(
                  _iconForPageType(recipe.pageType),
                  color: theme.colorScheme.onSecondaryContainer,
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
          ],
        ),
        subtitle: Text(
          _labelForPageType(recipe.pageType),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.secondary,
          ),
        ),
        trailing: selectionMode ? null : const Icon(Icons.chevron_right),
        onTap: selectionMode
            ? onSelect
            : () => context.push('/book-pages/${recipe.id}'),
        onLongPress: !selectionMode ? onSelect : null,
      ),
    );
  }
}

// ── Carte recette ─────────────────────────────────────────────────────────────

class RecipeCard extends ConsumerWidget {
  final Recipe recipe;
  final bool inBookContext;
  final bool canEdit;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onSelect;

  const RecipeCard({
    super.key,
    required this.recipe,
    required this.inBookContext,
    required this.canEdit,
    this.selectionMode = false,
    this.isSelected = false,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final hasGalleryShortcut =
        recipe.imageUrls.isNotEmpty &&
        screenWidth >= (PlatformUtils.wideBreakpoint + 100);
    final tagsSummary = buildRecipeTagSummary(recipe.tags);
    final annotations = ref.watch(annotationsProvider(recipe.id)).value ?? [];
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
        AnnotBadge(
          icon: Icons.sticky_note_2_outlined,
          count: noteCount,
          color: annotNoteColor(theme),
          foregroundColor: annotNoteFg(theme),
          onTap: goToAnnotations,
        ),
      if (tipCount > 0)
        AnnotBadge(
          icon: Icons.lightbulb_outline,
          count: tipCount,
          color: theme.colorScheme.tertiaryContainer,
          foregroundColor: theme.colorScheme.onTertiaryContainer,
          onTap: goToAnnotations,
        ),
      if (corrCount > 0)
        AnnotBadge(
          icon: Icons.build_circle_outlined,
          count: corrCount,
          color: theme.colorScheme.errorContainer,
          foregroundColor: theme.colorScheme.onErrorContainer,
          onTap: goToAnnotations,
        ),
    ];

    return Card(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.7)
          : null,
      child: ListTile(
        leading: selectionMode
            ? Checkbox(
                value: isSelected,
                onChanged: onSelect != null ? (_) => onSelect!() : null,
              )
            : CircleAvatar(
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
        subtitle: _buildRecipeSubtitle(theme, tagsSummary),
        trailing: selectionMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasGalleryShortcut)
                    IconButton(
                      tooltip: 'Voir la galerie',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: 32,
                        height: 32,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.photo_library_outlined),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (ctx) => IllustrationGallery(
                          urls: recipe.imageUrls,
                          initialIndex: 0,
                        ),
                      ),
                    ),
                  if (canEdit)
                    RecipeActionsMenu(
                      recipe: recipe,
                      inBookContext: inBookContext,
                    )
                  else
                    const Icon(Icons.chevron_right),
                ],
              ),
        onTap: selectionMode
            ? onSelect
            : () => context.push('/recipes/${recipe.id}'),
        onLongPress: !selectionMode ? onSelect : null,
      ),
    );
  }

  Widget? _buildRecipeSubtitle(ThemeData theme, String? tagsSummary) {
    final bookTitle = (!inBookContext && recipe.bookTitre != null)
        ? recipe.bookTitre
        : null;
    if (bookTitle == null && tagsSummary == null) return null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bookTitle != null) Text(bookTitle),
        if (tagsSummary != null)
          Text(
            tagsSummary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }
}

// ── Badge d'annotation ────────────────────────────────────────────────────────

class AnnotBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;
  const AnnotBadge({
    super.key,
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

// ── Menu d'actions recette ────────────────────────────────────────────────────

class RecipeActionsMenu extends ConsumerWidget {
  final Recipe recipe;
  final bool inBookContext;

  const RecipeActionsMenu({
    super.key,
    required this.recipe,
    required this.inBookContext,
  });

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
            context.showSuccessSnackBar('Recette détachée du livre.');
          } catch (e) {
            if (!context.mounted) return;
            context.showErrorSnackBar('Erreur : $e');
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
            context.showSuccessSnackBar('Recette supprimée.');
          } catch (e) {
            if (!context.mounted) return;
            context.showErrorSnackBar('Erreur : $e');
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

// ── Enums et helpers internes ─────────────────────────────────────────────────

enum _RecipeAction { edit, annotate, detach, delete }

/// Couleur de fond du badge "Note" (adapté dark/light).
Color annotNoteColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF1565C0)
    : const Color(0xFFBBDEFB);

/// Couleur de texte/icône du badge "Note" (adapté dark/light).
Color annotNoteFg(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white
    : const Color(0xFF0D47A1);
