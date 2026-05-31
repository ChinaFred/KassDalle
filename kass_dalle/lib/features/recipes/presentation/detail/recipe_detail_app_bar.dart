import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../domain/recipe.dart';
import '../recipe_rating_widget.dart';
import '../source_viewer.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/presentation/book_providers.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_widgets.dart';

/// AppBar de la page de détail d'une recette.
class RecipeDetailAppBar extends ConsumerWidget implements PreferredSizeWidget {
  final Recipe recipe;
  final AppUser? user;
  final bool canEdit;
  final bool uploadingFreeCover;
  final VoidCallback onScrollToAnnotations;
  final VoidCallback onChangeCover;
  final void Function(String url) onCoverZoom;
  final VoidCallback onCopyAsDraft;
  final VoidCallback onDetachFromBook;
  final VoidCallback onDeleteRecipe;
  final VoidCallback onExportPdf;

  const RecipeDetailAppBar({
    super.key,
    required this.recipe,
    required this.user,
    required this.canEdit,
    required this.uploadingFreeCover,
    required this.onScrollToAnnotations,
    required this.onChangeCover,
    required this.onCoverZoom,
    required this.onCopyAsDraft,
    required this.onDetachFromBook,
    required this.onDeleteRecipe,
    required this.onExportPdf,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookId = recipe.bookId;
    final isOwnRecipe = user?.uid == recipe.createdBy;
    final coverUrl = (bookId != null && bookId.isNotEmpty)
        ? ref.watch(bookByIdProvider(bookId)).value?.urlCouverture ?? ''
        : '';
    final ownerAsync = ref.watch(userByUidProvider(recipe.createdBy));
    final freeRecipeCoverUrl = ownerAsync.value?.freeRecipeCoverUrl ?? '';
    final annotations =
        ref.watch(annotationsProvider(recipe.id)).value ?? [];
    final noteCount =
        annotations.where((a) => a.type == AnnotationType.note).length;
    final tipCount =
        annotations.where((a) => a.type == AnnotationType.tip).length;
    final corrCount =
        annotations.where((a) => a.type == AnnotationType.correction).length;

    return AppBar(
      centerTitle: false,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (coverUrl.isNotEmpty) ...[
            GestureDetector(
              onTap: () => onCoverZoom(coverUrl),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: CachedNetworkImage(
                  imageUrl: coverUrl,
                  width: 32,
                  height: 44,
                  fit: BoxFit.cover,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ] else if (recipe.bookId == null) ...[
            GestureDetector(
              onTap: isOwnRecipe && canEdit
                  ? onChangeCover
                  : freeRecipeCoverUrl.isNotEmpty
                  ? () => onCoverZoom(freeRecipeCoverUrl)
                  : null,
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: freeRecipeCoverUrl.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: freeRecipeCoverUrl,
                            width: 32,
                            height: 44,
                            fit: BoxFit.cover,
                            errorWidget: (_, _, _) =>
                                RecipeDetailFreeRecipeCover(
                                  isOwner: isOwnRecipe && canEdit,
                                ),
                          )
                        : RecipeDetailFreeRecipeCover(
                            isOwner: isOwnRecipe && canEdit,
                          ),
                  ),
                  if (uploadingFreeCover)
                    Positioned.fill(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: const ColoredBox(
                          color: Colors.black38,
                          child: Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        recipe.titre,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    RecipeRatingBadge(recipeId: recipe.id),
                    if (noteCount > 0)
                      DetailAnnotBadge(
                        icon: Icons.sticky_note_2_outlined,
                        count: noteCount,
                        color: annotNoteColor(Theme.of(context)),
                        foregroundColor: annotNoteFg(Theme.of(context)),
                        onTap: onScrollToAnnotations,
                      ),
                    if (tipCount > 0)
                      DetailAnnotBadge(
                        icon: Icons.lightbulb_outline,
                        count: tipCount,
                        color:
                            Theme.of(context).colorScheme.tertiaryContainer,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onTertiaryContainer,
                        onTap: onScrollToAnnotations,
                      ),
                    if (corrCount > 0)
                      DetailAnnotBadge(
                        icon: Icons.build_circle_outlined,
                        count: corrCount,
                        color: Theme.of(context).colorScheme.errorContainer,
                        foregroundColor: Theme.of(
                          context,
                        ).colorScheme.onErrorContainer,
                        onTap: onScrollToAnnotations,
                      ),
                  ],
                ),
                if (recipe.bookTitre != null)
                  GestureDetector(
                    onTap: () => context.push(
                      '/recipes?bookId=${recipe.bookId ?? ''}&bookTitre=${Uri.encodeComponent(recipe.bookTitre!)}',
                    ),
                    child: Text(
                      [
                        recipe.bookTitre!,
                        if (recipe.pageNumber != null)
                          'pg\u00a0${recipe.pageNumber}',
                      ].join(', '),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        decoration: TextDecoration.underline,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (recipe.bookTitre == null)
                  GestureDetector(
                    onTap: () => context.push('/recipes'),
                    child: Text(
                      'Recette libre',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        decoration: TextDecoration.underline,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (recipe.createdBy != user?.uid)
                  RecipeDetailOwnerLabel(ownerUid: recipe.createdBy),
              ],
            ),
          ),
        ],
      ),
      actions: [
        SourceViewerButton(
          sourceFileUrl: recipe.sourceFileUrl,
          sourceFileName: recipe.sourceFileName,
          additionalSourceFileUrls: recipe.additionalSourceFileUrls,
        ),
        IconButton(
          icon: const Icon(Icons.picture_as_pdf_outlined),
          tooltip: 'Exporter en PDF',
          onPressed: onExportPdf,
        ),
        if (user != null && recipe.createdBy != user!.uid)
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copier comme mon brouillon',
            onPressed: onCopyAsDraft,
          ),
        if (canEdit && recipe.bookId != null)
          IconButton(
            icon: const Icon(Icons.link_off_outlined),
            tooltip: 'Détacher du livre',
            onPressed: onDetachFromBook,
          ),
        if (canEdit)
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Modifier la recette',
            onPressed: () => context.push('/recipes/${recipe.id}/edit'),
          ),
        if (canEdit)
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Supprimer la recette',
            color: Theme.of(context).colorScheme.error,
            onPressed: onDeleteRecipe,
          ),
      ],
    );
  }
}
