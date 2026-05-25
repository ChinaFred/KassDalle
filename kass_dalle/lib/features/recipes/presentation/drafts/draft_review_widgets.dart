import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../source_viewer.dart';

// ── Onglet illustrations ──────────────────────────────────────────────────────

class DraftIllustrationsTab extends ConsumerStatefulWidget {
  final Recipe recipe;
  final bool isOwner;
  final bool aiRefining;
  final bool saving;
  final VoidCallback? onExtract;
  final VoidCallback? onExtractFromOriginal;
  final void Function(int index)? onCrop;
  final void Function(int index)? onColor;

  /// Bouton « AI enhance » (perspective + couleurs) — admin uniquement.
  final void Function(int index)? onEnhance;

  /// Index actuellement en cours d'amélioration AI (spinner sur la carte).
  final int? enhancingIndex;

  const DraftIllustrationsTab({
    super.key,
    required this.recipe,
    required this.isOwner,
    required this.aiRefining,
    required this.saving,
    this.onExtract,
    this.onExtractFromOriginal,
    this.onCrop,
    this.onColor,
    this.onEnhance,
    this.enhancingIndex,
  });

  @override
  ConsumerState<DraftIllustrationsTab> createState() =>
      _DraftIllustrationsTabState();
}

class _DraftIllustrationsTabState
    extends ConsumerState<DraftIllustrationsTab> {
  bool _selectMode = false;
  final Set<int> _selected = {};

  void _toggleSelect(int i) => setState(
        () => _selected.contains(i) ? _selected.remove(i) : _selected.add(i),
      );

  void _startSelectMode() => setState(() => _selectMode = true);

  void _cancelSelectMode() => setState(() {
        _selectMode = false;
        _selected.clear();
      });

  void _selectAll() {
    setState(() {
      _selected.clear();
      for (var i = 0; i < widget.recipe.imageUrls.length; i++) {
        _selected.add(i);
      }
    });
  }

  Future<void> _removeAt(int index) async {
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
    if (confirmed != true || !mounted) return;
    final newUrls = List<String>.from(widget.recipe.imageUrls)..removeAt(index);
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(widget.recipe.id, newUrls);
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) return;
    final n = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer $n photo${n > 1 ? 's' : ''} ?'),
        content: Text(
          '$n photo${n > 1 ? 's' : ''} sélectionnée${n > 1 ? 's' : ''} '
          'ser${n > 1 ? 'ont' : 'a'} supprimée${n > 1 ? 's' : ''} définitivement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Supprimer du plus grand index au plus petit pour préserver les indices
    final sorted = _selected.toList()..sort((a, b) => b.compareTo(a));
    final newUrls = List<String>.from(widget.recipe.imageUrls);
    for (final i in sorted) {
      newUrls.removeAt(i);
    }
    _cancelSelectMode();
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(widget.recipe.id, newUrls);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final busy = widget.aiRefining || widget.saving;

    final canExtract = widget.isOwner && widget.onExtract != null;

    final canExtractFromOriginal =
        widget.isOwner && widget.onExtractFromOriginal != null;

    final hasPhotos = widget.recipe.imageUrls.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Barre d'actions (toujours visible) ──────────────────────────────
        if (canExtract || canExtractFromOriginal || (hasPhotos && widget.isOwner))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: Row(
              children: [
                if (hasPhotos)
                  Text(
                    '${widget.recipe.imageUrls.length} photo'
                    '${widget.recipe.imageUrls.length > 1 ? 's' : ''}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                const Spacer(),
                if (!_selectMode) ...[
                  if (canExtract)
                    TextButton.icon(
                      onPressed: busy ? null : widget.onExtract,
                      icon: widget.aiRefining
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 16),
                      label: Text(hasPhotos ? 'Ré-extraire' : 'Extraire'),
                    ),
                  if (canExtractFromOriginal)
                    TextButton.icon(
                      onPressed: busy ? null : widget.onExtractFromOriginal,
                      icon: const Icon(Icons.crop_outlined, size: 16),
                      label: const Text("Depuis l'original"),
                    ),
                  if (hasPhotos && widget.isOwner)
                    IconButton(
                      tooltip: 'Sélectionner plusieurs',
                      icon: const Icon(Icons.checklist_outlined),
                      onPressed: _startSelectMode,
                    ),
                ] else ...[
                  // ── Mode sélection multiple ──────────────────────────────
                  Text(
                    '${_selected.length} sélectionnée'
                    '${_selected.length > 1 ? 's' : ''}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  TextButton(
                    onPressed: _selectAll,
                    child: const Text('Tout'),
                  ),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                    ),
                    onPressed: _selected.isEmpty ? null : _deleteSelected,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: Text('Supprimer (${_selected.length})'),
                  ),
                  TextButton(
                    onPressed: _cancelSelectMode,
                    child: const Text('Annuler'),
                  ),
                ],
              ],
            ),
          ),
        // ── Zone centrale ─────────────────────────────────────────────────
        Expanded(
          child: hasPhotos
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 260,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                    childAspectRatio: 4 / 3,
                  ),
                  itemCount: widget.recipe.imageUrls.length,
                  itemBuilder: (ctx, i) => _IllustrationCard(
                    url: widget.recipe.imageUrls[i],
                    onDelete: (!_selectMode && widget.isOwner)
                        ? () => _removeAt(i)
                        : null,
                    onCrop: (!_selectMode &&
                            widget.isOwner &&
                            widget.onCrop != null)
                        ? () => widget.onCrop!(i)
                        : null,
                    onColor: (!_selectMode &&
                            widget.isOwner &&
                            widget.onColor != null)
                        ? () => widget.onColor!(i)
                        : null,
                    onEnhance: (!_selectMode &&
                            widget.isOwner &&
                            widget.onEnhance != null)
                        ? () => widget.onEnhance!(i)
                        : null,
                    enhancing: widget.enhancingIndex == i,
                    selected: _selectMode && _selected.contains(i),
                    onSelectTap: _selectMode ? () => _toggleSelect(i) : null,
                  ),
                )
              : Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.photo_library_outlined,
                          size: 64,
                          color: cs.onSurfaceVariant,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Aucune photo détectée',
                          style: theme.textTheme.titleMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          (canExtract || canExtractFromOriginal)
                              ? "L'IA n'a pas encore analysé le scan, ou n'a trouvé\n"
                                  'aucune photo culinaire dans ce document.'
                              : "Aucune illustration n'a été associée à ce brouillon.",
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ],
                    ),
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
  final VoidCallback? onEnhance;
  final bool enhancing;
  final bool selected;
  final VoidCallback? onSelectTap;

  const _IllustrationCard({
    required this.url,
    this.onDelete,
    this.onCrop,
    this.onColor,
    this.onEnhance,
    this.enhancing = false,
    this.selected = false,
    this.onSelectTap,
  });

  @override
  Widget build(BuildContext context) {
    // En mode sélection : le tap bascule la sélection, les boutons sont cachés
    final isSelectMode = onSelectTap != null;

    return GestureDetector(
      onTap: isSelectMode ? onSelectTap : null,
      child: Stack(
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
        // Overlay sélection
        if (isSelectMode)
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: selected
                  ? Theme.of(context).colorScheme.primary.withAlpha(77)
                  : Colors.transparent,
              border: selected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    )
                  : null,
            ),
          ),
        if (isSelectMode)
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.black45,
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
        if (!isSelectMode && onDelete != null)
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
                  child: Icon(
                    Icons.delete_outline,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        if (onEnhance != null)
          Positioned(
            top: 4,
            left: 4,
            child: Material(
              color: Colors.deepPurple.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: enhancing ? null : onEnhance,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (enhancing)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      else
                        const Icon(
                          Icons.auto_fix_high,
                          size: 14,
                          color: Colors.white,
                        ),
                      const SizedBox(width: 4),
                      const Text(
                        'AI',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
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
                        child: Icon(
                          Icons.crop_free,
                          size: 16,
                          color: Colors.white,
                        ),
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
    ),
    );
  }
}

// ── Panneau d'aperçu du document source ──────────────────────────────────────

class DraftSourcePreviewPanel extends StatefulWidget {
  final String? sourceFileUrl;
  final String? sourceFileName;
  final List<String> additionalSourceFileUrls;

  const DraftSourcePreviewPanel({
    super.key,
    required this.sourceFileUrl,
    required this.sourceFileName,
    this.additionalSourceFileUrls = const [],
  });

  @override
  State<DraftSourcePreviewPanel> createState() =>
      _DraftSourcePreviewPanelState();
}

class _DraftSourcePreviewPanelState extends State<DraftSourcePreviewPanel> {
  final _pageCtrl = PageController();
  int _currentPage = 0;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  bool _isImageUrl(String url, {String? fileName}) {
    final lower = (fileName ?? url).toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sourceFileUrl == null) return const SizedBox.shrink();

    final allUrls = [widget.sourceFileUrl!, ...widget.additionalSourceFileUrls];

    // ── Single page ──────────────────────────────────────────────────────────
    if (allUrls.length == 1) {
      if (_isImageUrl(widget.sourceFileUrl!, fileName: widget.sourceFileName)) {
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Center(
            child: CachedNetworkImage(
              imageUrl: widget.sourceFileUrl!,
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
            Text(widget.sourceFileName ?? 'Document source'),
            const SizedBox(height: 16),
            SourceViewerButton(
              sourceFileUrl: widget.sourceFileUrl,
              sourceFileName: widget.sourceFileName,
            ),
          ],
        ),
      );
    }

    // ── Multi-page : PageView avec indicateur ────────────────────────────────
    return Stack(
      children: [
        PageView.builder(
          controller: _pageCtrl,
          onPageChanged: (i) => setState(() => _currentPage = i),
          itemCount: allUrls.length,
          itemBuilder: (ctx, i) {
            final url = allUrls[i];
            final fileName = i == 0 ? widget.sourceFileName : null;
            if (_isImageUrl(url, fileName: fileName)) {
              return InteractiveViewer(
                minScale: 0.5,
                maxScale: 5,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: url,
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
                  Text(fileName ?? 'Page ${i + 1}'),
                  const SizedBox(height: 16),
                  SourceViewerButton(
                    sourceFileUrl: url,
                    sourceFileName: fileName,
                  ),
                ],
              ),
            );
          },
        ),
        // Indicateur de page
        Positioned(
          bottom: 12,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_left,
                      color: Colors.white,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _currentPage > 0
                        ? () => _pageCtrl.previousPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                          )
                        : null,
                  ),
                  Text(
                    'Page ${_currentPage + 1} / ${allUrls.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.chevron_right,
                      color: Colors.white,
                      size: 20,
                    ),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    visualDensity: VisualDensity.compact,
                    onPressed: _currentPage < allUrls.length - 1
                        ? () => _pageCtrl.nextPage(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
