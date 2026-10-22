import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/domain/book.dart';
import '../../../books/presentation/book_providers.dart';
import '../../../auth/domain/user_profile.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../recipe_rating_widget.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/utils/recipe_tag_sections.dart';
import '../detail/book_reader_navigation.dart';
import '../detail/recipe_detail_annotations.dart';
import '../detail/recipe_detail_illustrations.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/theme/app_icon_size.dart';

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
    final name = ref.watch(memberNameProvider(ownerUid));
    return RecipeSectionHeader(
      title: switch (name) {
        null => 'Recettes libres de …',
        UserProfile.fallbackName => 'Recettes libres d\'un membre',
        _ => 'Recettes libres de $name',
      },
      count: count,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

// ── Contenu "À propos" du livre ───────────────────────────────────────────────

class BookAboutContent extends ConsumerWidget {
  final Book book;
  const BookAboutContent({super.key, required this.book});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final libraryOrigin = ref.watch(libraryOriginProvider(book.createdBy));

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
        // « Auteur » est celui du livre imprimé ; « Bibliothèque » dit qui, dans
        // la famille, détient cet exemplaire-là. Les deux se confondaient.
        if (libraryOrigin != null) infoRow('Bibliothèque', libraryOrigin),
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

// ── Tuile page de livre (non-recette) ─────────────────────────────────────────

class BookPageTile extends StatelessWidget {
  final Recipe recipe;
  final String? bookId;
  final String? bookTitre;
  final String? bookCoverUrl;
  final bool showUnattached;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onSelect;

  const BookPageTile({
    super.key,
    required this.recipe,
    this.bookId,
    this.bookTitre,
    this.bookCoverUrl,
    this.showUnattached = false,
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
    final readingContext = <String, String>{
      if ((bookId ?? '').isNotEmpty) 'bookId': bookId!,
      if ((bookTitre ?? '').isNotEmpty) 'bookTitre': bookTitre!,
      if ((bookCoverUrl ?? '').isNotEmpty) 'bookCoverUrl': bookCoverUrl!,
      if (showUnattached) 'showUnattached': 'true',
    };
    final pageUri = Uri(
      path: '/book-pages/${recipe.id}',
      queryParameters: readingContext.isEmpty ? null : readingContext,
    ).toString();
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
        onTap: selectionMode ? onSelect : () => context.push(pageUri),
        onLongPress: !selectionMode ? onSelect : null,
      ),
    );
  }
}

// ── Carte recette ─────────────────────────────────────────────────────────────

class RecipeCard extends ConsumerWidget {
  final Recipe recipe;
  final bool inBookContext;
  final String? bookId;
  final String? bookTitre;
  final String? bookCoverUrl;
  final bool showUnattached;
  final bool canEdit;
  final bool selectionMode;
  final bool isSelected;
  final VoidCallback? onSelect;

  const RecipeCard({
    super.key,
    required this.recipe,
    required this.inBookContext,
    this.bookId,
    this.bookTitre,
    this.bookCoverUrl,
    this.showUnattached = false,
    required this.canEdit,
    this.selectionMode = false,
    this.isSelected = false,
    this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;
    final readingContext = BookReadingContext(
      bookId: bookId,
      bookTitre: bookTitre,
      bookCoverUrl: bookCoverUrl,
      showUnattached: showUnattached,
    );
    final recipeUri = buildReaderRecipeLocation(recipe.id, readingContext);
    final hasGalleryShortcut =
        recipe.imageUrls.isNotEmpty &&
        screenWidth >= PlatformUtils.galleryShortcutBreakpoint;
    final tagsSummary = buildRecipeTagSummary(recipe.tags);
    final annotations = ref.watch(annotationsProvider(recipe.id)).value ?? [];
    // Pastilles en lecture seule : leur texte est lu avec la tuile, et l'appui
    // ouvre la fiche. La note se modifie sur la fiche, où sa cible fait 48 px.
    final annotPills = AnnotationPills(counts: countAnnotations(annotations));

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
                  Icons.restaurant_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
        title: Row(
          children: [
            Expanded(child: Text(recipe.titre)),
            if (hasGalleryShortcut)
              IconButton(
                tooltip: 'Voir la galerie',
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.photo_library_outlined,
                  size: AppIconSize.small,
                ),
                onPressed: () =>
                    showIllustrationGallery(context, recipe.imageUrls),
              ),
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
            RecipeRatingBadge(recipeId: recipe.id, readOnly: true),
            annotPills,
          ],
        ),
        subtitle: _buildRecipeSubtitle(theme, tagsSummary),
        trailing: selectionMode
            ? null
            : (canEdit
                  ? RecipeActionsMenu(
                      recipe: recipe,
                      inBookContext: inBookContext,
                    )
                  : const Icon(Icons.chevron_right)),
        onTap: selectionMode ? onSelect : () => context.push(recipeUri),
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
          } catch (e, stackTrace) {
            reportUnexpectedError(
              feature: 'recipeListWidgets.detachFromBook',
              error: e,
              stackTrace: stackTrace,
            );
            if (!context.mounted) return;
            context.showFailureSnackBar('Recette non détachée du livre', e);
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
          } catch (e, stackTrace) {
            reportUnexpectedError(
              feature: 'recipeListWidgets.deleteRecipe',
              error: e,
              stackTrace: stackTrace,
            );
            if (!context.mounted) return;
            context.showFailureSnackBar('Recette non supprimée', e);
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
