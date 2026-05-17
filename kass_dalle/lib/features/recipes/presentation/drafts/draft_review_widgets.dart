import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../source_viewer.dart';

// ── Onglet illustrations ──────────────────────────────────────────────────────

class DraftIllustrationsTab extends ConsumerWidget {
  final Recipe recipe;
  final bool isOwner;
  final bool aiRefining;
  final bool saving;
  final VoidCallback? onExtract;
  final void Function(int index)? onCrop;
  final void Function(int index)? onColor;

  const DraftIllustrationsTab({
    super.key,
    required this.recipe,
    required this.isOwner,
    required this.aiRefining,
    required this.saving,
    this.onExtract,
    this.onCrop,
    this.onColor,
  });

  bool _isImageSource(String? url, String? fileName) {
    final lower = (fileName ?? url ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  Future<void> _removeAt(BuildContext context, WidgetRef ref, int index) async {
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
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final newUrls = List<String>.from(recipe.imageUrls)..removeAt(index);
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(recipe.id, newUrls);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canExtract =
        isOwner &&
        onExtract != null &&
        _isImageSource(recipe.sourceFileUrl, recipe.sourceFileName);

    if (recipe.imageUrls.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Aucune photo détectée',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                canExtract
                    ? 'L\'IA n\'a pas encore analysé le scan, ou n\'a trouvé\naucune photo culinaire dans ce document.'
                    : 'Aucune illustration n\'a été associée à ce brouillon.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (canExtract) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: (aiRefining || saving) ? null : onExtract,
                  icon: aiRefining
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_search_outlined),
                  label: const Text('Extraire les illustrations'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text(
                '${recipe.imageUrls.length} photo(s)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (canExtract)
                TextButton.icon(
                  onPressed: (aiRefining || saving) ? null : onExtract,
                  icon: aiRefining
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('Ré-extraire'),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 4 / 3,
            ),
            itemCount: recipe.imageUrls.length,
            itemBuilder: (ctx, i) => _IllustrationCard(
              url: recipe.imageUrls[i],
              onDelete: isOwner ? () => _removeAt(context, ref, i) : null,
              onCrop: (isOwner && onCrop != null) ? () => onCrop!(i) : null,
              onColor: (isOwner && onColor != null) ? () => onColor!(i) : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _IllustrationCard extends StatelessWidget {
  final String url;
  final VoidCallback? onDelete;
  final VoidCallback? onCrop;
  final VoidCallback? onColor;

  const _IllustrationCard({
    required this.url,
    this.onDelete,
    this.onCrop,
    this.onColor,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, _) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, _, _) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(child: Icon(Icons.broken_image, size: 40)),
            ),
          ),
        ),
        if (onDelete != null)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onDelete,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
        if (onCrop != null || onColor != null)
          Positioned(
            bottom: 4,
            right: 4,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onCrop != null)
                  Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: onCrop,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.crop_free, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                if (onCrop != null && onColor != null) const SizedBox(width: 4),
                if (onColor != null)
                  Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: onColor,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.tune, size: 16, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── Panneau d'aperçu du document source ──────────────────────────────────────

class DraftSourcePreviewPanel extends StatelessWidget {
  final String? sourceFileUrl;
  final String? sourceFileName;

  const DraftSourcePreviewPanel({
    super.key,
    required this.sourceFileUrl,
    required this.sourceFileName,
  });

  bool get _isImage {
    final lower = (sourceFileName ?? sourceFileUrl ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  @override
  Widget build(BuildContext context) {
    if (sourceFileUrl == null) return const SizedBox.shrink();
    if (_isImage) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: CachedNetworkImage(
            imageUrl: sourceFileUrl!,
            fit: BoxFit.contain,
            placeholder: (_, _) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, _, _) =>
                const Center(child: Icon(Icons.broken_image, size: 64)),
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.picture_as_pdf, size: 64),
          const SizedBox(height: 16),
          Text(sourceFileName ?? 'Document source'),
          const SizedBox(height: 16),
          SourceViewerButton(
            sourceFileUrl: sourceFileUrl,
            sourceFileName: sourceFileName,
          ),
        ],
      ),
    );
  }
}
