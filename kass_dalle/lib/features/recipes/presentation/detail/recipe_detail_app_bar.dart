import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/utils/platform_utils.dart';
import '../../domain/recipe.dart';
import '../recipe_rating_widget.dart';
import '../source_viewer.dart';
import '../../../auth/domain/app_user.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/presentation/book_providers.dart';
import '../ai/ai_ui_copy.dart';
import 'book_reader_navigation.dart';
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
  final VoidCallback onModifyWithAi;
  final VoidCallback onDetachFromBook;
  final VoidCallback onDeleteRecipe;
  final VoidCallback onExportPdf;
  final BookReadingContext readingContext;

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
    required this.onModifyWithAi,
    required this.onDetachFromBook,
    required this.onDeleteRecipe,
    required this.onExportPdf,
    this.readingContext = const BookReadingContext(),
    this.hauteur = kToolbarHeight,
  });

  /// Hauteur réclamée au Scaffold, calculée par l'appelant.
  ///
  /// Elle doit valoir ce que [build] construit réellement. Sinon le Scaffold
  /// réserve moins de place que la barre n'en occupe, et la barre est rognée
  /// par le haut : titre amputé de sa moitié supérieure, flèche de retour avec
  /// lui. C'est ce qui arrivait — 56 px réclamés pour 114 construits.
  final double hauteur;

  /// Ce que la barre occupera dans ce contexte.
  ///
  /// Statique, parce que l'appelant doit la connaître AVANT de construire le
  /// widget : `preferredSize` n'a pas de `BuildContext` et ne peut lire ni la
  /// largeur de l'écran, ni l'échelle de police.
  static double hauteurPour(BuildContext context) {
    final compacte =
        MediaQuery.sizeOf(context).width <
        PlatformUtils.compactDetailBreakpoint;
    if (!compacte) return kToolbarHeight;
    // Deux lignes de titre, plus la rangée d'actions. La première suit
    // l'échelle de police du système ; au-delà, le titre débordait.
    final echelle = MediaQuery.textScalerOf(context).scale(1.0);
    return (72.0 * echelle).clamp(72.0, 140.0) + _hauteurActions;
  }

  /// Hauteur de la rangée d'actions, sous le titre.
  static const double _hauteurActions = 42;

  @override
  Size get preferredSize => Size.fromHeight(hauteur);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMobileCompact =
        MediaQuery.sizeOf(context).width <
        PlatformUtils.compactDetailBreakpoint;
    final bookId = recipe.bookId;
    final isOwnRecipe = user?.uid == recipe.createdBy;
    final coverUrl = (bookId != null && bookId.isNotEmpty)
        ? ref.watch(bookByIdProvider(bookId)).value?.urlCouverture ?? ''
        : '';
    final ownerAsync = ref.watch(userByUidProvider(recipe.createdBy));
    final freeRecipeCoverUrl = ownerAsync.value?.freeRecipeCoverUrl ?? '';
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
    // Les puces d'annotation se lisent d'un coup d'œil : combien de remarques,
    // d'astuces, de corrections. Elles sont les mêmes des deux côtés — seule
    // la place qu'on leur donne change.
    final annotBadges = <Widget>[
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
          color: Theme.of(context).colorScheme.tertiaryContainer,
          foregroundColor: Theme.of(context).colorScheme.onTertiaryContainer,
          onTap: onScrollToAnnotations,
        ),
      if (corrCount > 0)
        DetailAnnotBadge(
          icon: Icons.build_circle_outlined,
          count: corrCount,
          color: Theme.of(context).colorScheme.errorContainer,
          foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
          onTap: onScrollToAnnotations,
        ),
    ];

    final bookListLocation = Uri(
      path: '/recipes',
      queryParameters: {
        if ((readingContext.bookId ?? recipe.bookId ?? '').isNotEmpty)
          'bookId': readingContext.bookId ?? recipe.bookId!,
        if ((readingContext.bookTitre ?? recipe.bookTitre ?? '').isNotEmpty)
          'bookTitre': readingContext.bookTitre ?? recipe.bookTitre!,
        if ((readingContext.bookCoverUrl ?? '').isNotEmpty)
          'bookCoverUrl': readingContext.bookCoverUrl!,
        if (readingContext.showUnattached) 'showUnattached': 'true',
      },
    ).toString();

    if (isMobileCompact) {
      // Deux lignes, parce qu'il n'y a pas la place pour une.
      //
      // Le titre partageait la barre avec la note, les pastilles d'annotation,
      // le document source et un menu « … » : il lui restait de quoi afficher
      // « Gâteau au … ». Les actions descendent donc d'un cran, et le titre
      // dispose de toute la largeur, sur deux lignes au besoin.
      //
      // Le menu « … » disparaît avec elles. Il cachait huit actions derrière un
      // geste et un temps d'attente ; les mêmes icônes, posées à plat, se
      // désignent directement.
      // La note et les pastilles ne sont pas des actions : elles décrivent la
      // recette, et vivent donc avec son titre.
      final actionsCompactes = <Widget>[
        SourceViewerButton(
          sourceFileUrl: recipe.sourceFileUrl,
          sourceFileName: recipe.sourceFileName,
          additionalSourceFileUrls: recipe.additionalSourceFileUrls,
        ),
        _ActionCompacte(
          tooltip: 'Aller aux annotations',
          icon: Icons.sticky_note_2_outlined,
          onPressed: onScrollToAnnotations,
        ),
        if (user != null)
          _ActionCompacte(
            tooltip: RecipeAiUiCopy.appBarActionTooltip,
            icon: Icons.auto_awesome_outlined,
            onPressed: onModifyWithAi,
          ),
        if (user != null && recipe.createdBy != user!.uid)
          _ActionCompacte(
            tooltip: 'Copier comme brouillon',
            icon: Icons.copy_outlined,
            onPressed: onCopyAsDraft,
          ),
        // Une recette libre n'a pas de couverture de livre : la sienne se
        // change depuis la vignette en large, et depuis cette icône ici.
        if (isOwnRecipe && canEdit && recipe.bookId == null)
          _ActionCompacte(
            tooltip: uploadingFreeCover
                ? 'Envoi de la couverture…'
                : 'Changer la couverture',
            icon: Icons.image_outlined,
            onPressed: uploadingFreeCover ? null : onChangeCover,
          ),
        if (canEdit && recipe.bookId != null)
          _ActionCompacte(
            tooltip: 'Détacher du livre',
            icon: Icons.link_off_outlined,
            onPressed: onDetachFromBook,
          ),
        if (canEdit)
          _ActionCompacte(
            tooltip: 'Modifier la recette',
            icon: Icons.edit_outlined,
            onPressed: () => context.push('/recipes/${recipe.id}/edit'),
          ),
        _ActionCompacte(
          tooltip: 'Exporter en PDF',
          icon: Icons.picture_as_pdf_outlined,
          onPressed: onExportPdf,
        ),
        if (canEdit)
          _ActionCompacte(
            tooltip: 'Supprimer la recette',
            icon: Icons.delete_outline,
            couleur: Theme.of(context).colorScheme.error,
            onPressed: onDeleteRecipe,
          ),
      ];

      return AppBar(
        toolbarHeight: hauteur - _hauteurActions,
        centerTitle: false,
        titleSpacing: 8,
        title: Row(
          children: [
            Flexible(
              child: Tooltip(
                message: [
                  recipe.titre,
                  if (recipe.bookTitre != null)
                    [
                      recipe.bookTitre!,
                      if (recipe.pageNumber != null) 'pg ${recipe.pageNumber}',
                    ].join(', '),
                ].join('\n'),
                child: Text(
                  recipe.titre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 6),
            RecipeRatingBadge(recipeId: recipe.id),
            ...annotBadges,
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(_hauteurActions),
          child: SizedBox(
            height: _hauteurActions,
            // Défilement horizontal en dernier recours : à densité normale les
            // dix icônes tiennent sur 360 px, mais une police agrandie ou une
            // recette qui offre toutes les actions peuvent les déborder. Rien
            // ne doit alors disparaître.
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: actionsCompactes,
              ),
            ),
          ),
        ),
      );
    }

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
                    ...annotBadges,
                  ],
                ),
                if (recipe.bookTitre != null)
                  GestureDetector(
                    onTap: () => context.push(bookListLocation),
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
        if (user != null && recipe.createdBy != user!.uid)
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copier comme mon brouillon',
            onPressed: onCopyAsDraft,
          ),
        if (user != null)
          IconButton(
            icon: const Icon(Icons.auto_awesome_outlined),
            tooltip: RecipeAiUiCopy.appBarActionTooltip,
            onPressed: onModifyWithAi,
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
        IconButton(
          icon: const Icon(Icons.picture_as_pdf_outlined),
          tooltip: 'Exporter en PDF',
          onPressed: onExportPdf,
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

/// Une action de la barre compacte : une icône, une infobulle, rien d'autre.
///
/// Dimensions serrées — vingt-deux pixels d'icône dans trente-six de touche —
/// pour que la dizaine d'actions tienne sur une ligne de téléphone. En dessous,
/// la cible devient trop petite pour le doigt.
class _ActionCompacte extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color? couleur;

  const _ActionCompacte({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.couleur,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: couleur),
      iconSize: 22,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }
}
