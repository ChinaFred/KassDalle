import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_icon_size.dart';
import '../../../../../core/widgets/app_states.dart';
import '../../../domain/recipe.dart';
import '../recipe_illustration_actions.dart';
import '../../../../../core/widgets/app_network_image.dart';

/// Ce que lit un propriétaire lecteur à la place du bouton d'ajout.
const kPhotosEditorOnlyMessage =
    'Ajouter des photos est réservé aux éditeurs. Demandez à un '
    'administrateur de vous nommer éditeur.';

/// Onglet « Photos » : les illustrations de la recette, en grand.
///
/// Elles étaient déjà affichées, en vignettes de 48 pixels posées entre la
/// puce des portions et celle du temps de cuisson, en haut de « Préparer ».
/// À cette taille une photo de plat ne se distingue pas d'une icône, et rien
/// n'annonçait qu'il y en avait. Cet onglet les montre en grille et réunit
/// l'ajout et la suppression au même endroit.
class PhotosTab extends ConsumerStatefulWidget {
  final String recipeId;
  final Recipe recipe;

  /// Propriétaire ou administrateur : choisit le texte de l'état vide.
  final bool canEdit;

  /// Propriétaire ET éditeur (`AppUser.canEnrichRecipe`) : ajouter ou
  /// supprimer une photo (`image_urls`, hors des écritures d'un lecteur).
  final bool canEnrich;

  const PhotosTab({
    super.key,
    required this.recipeId,
    required this.recipe,
    required this.canEdit,
    required this.canEnrich,
  });

  @override
  ConsumerState<PhotosTab> createState() => PhotosTabState();
}

class PhotosTabState extends ConsumerState<PhotosTab>
    with RecipeIllustrationActions<PhotosTab> {
  @override
  bool uploadingIllustration = false;

  @override
  String get recipeId => widget.recipeId;

  @override
  Widget build(BuildContext context) {
    final urls = widget.recipe.imageUrls;
    final theme = Theme.of(context);

    final Widget body;
    if (urls.isEmpty) {
      body = AppEmptyState(
        icon: Icons.photo_library_outlined,
        title: 'Aucune photo',
        // Propriétaire lecteur : l'ajout est réservé aux éditeurs (tickets
        // #162 et #163), et l'état vide le lui dit, sans bouton.
        message: widget.canEnrich
            ? 'Photographiez le plat, ou choisissez une image dans la galerie.'
            : widget.canEdit
            ? kPhotosEditorOnlyMessage
            : 'Personne n\'a encore ajouté de photo à cette recette.',
        action: widget.canEnrich
            ? FilledButton.icon(
                onPressed: uploadingIllustration ? null : addIllustration,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: const Text('Ajouter une photo'),
              )
            : null,
      );
    } else {
      body = CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${urls.length} photo${urls.length > 1 ? 's' : ''}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (widget.canEnrich)
                    FilledButton.tonalIcon(
                      onPressed: uploadingIllustration ? null : addIllustration,
                      icon: const Icon(
                        Icons.add_a_photo_outlined,
                        size: AppIconSize.small,
                      ),
                      label: const Text('Ajouter'),
                    ),
                ],
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 4 / 3,
              ),
              itemCount: urls.length,
              itemBuilder: (_, i) => _PhotoTile(
                url: urls[i],
                onTap: () => showGallery(urls, i),
                onDelete: widget.canEnrich
                    ? () => deleteIllustration(urls[i])
                    : null,
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        body,
        if (uploadingIllustration)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

/// Une photo de la grille : ouverture en plein écran au clic, suppression
/// confirmée par le bouton posé dans le coin.
class _PhotoTile extends StatelessWidget {
  final String url;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _PhotoTile({required this.url, required this.onTap, this.onDelete});

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette photo ?'),
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
    if (confirmed == true) onDelete!();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: InkWell(
                onTap: onTap,
                child: AppNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => const Center(
                    child: SizedBox(
                      width: AppIconSize.medium,
                      height: AppIconSize.medium,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                  errorWidget: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    size: AppIconSize.large,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onDelete != null)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black54,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: IconButton(
                tooltip: 'Supprimer cette photo',
                iconSize: AppIconSize.small,
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => _confirmDelete(context),
              ),
            ),
          ),
      ],
    );
  }
}
