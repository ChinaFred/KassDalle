import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import 'image_enhancer_screen.dart';

class ImageActionCard extends StatefulWidget {
  final String? imageUrl;
  final String? thumbnailUrl;
  final Uint8List? imageBytes;
  final String? assetPath;
  final double aspectRatio;
  final bool selected;
  final bool showActions;
  final bool showBusyOverlay;
  final bool showSelectionOverlay;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;
  final Future<void> Function(EnhancerMode mode, Uint8List bytes)? onEdit;
  final Future<void> Function()? onEnhanceAi;
  final String emptyLabel;
  final String? deleteTooltip;
  final String? cropTooltip;
  final String? colorTooltip;
  final String? aiTooltip;

  const ImageActionCard({
    super.key,
    this.imageUrl,
    this.thumbnailUrl,
    this.imageBytes,
    this.assetPath,
    this.aspectRatio = 4 / 3,
    this.selected = false,
    this.showActions = true,
    this.showBusyOverlay = false,
    this.showSelectionOverlay = false,
    this.onTap,
    this.onDelete,
    this.onEdit,
    this.onEnhanceAi,
    this.emptyLabel = 'Aucune image',
    this.deleteTooltip,
    this.cropTooltip,
    this.colorTooltip,
    this.aiTooltip,
  });

  @override
  State<ImageActionCard> createState() => _ImageActionCardState();
}

class _ImageActionCardState extends State<ImageActionCard> {
  bool _busy = false;

  Future<Uint8List?> _downloadBytes(String url) async {
    try {
      return await FirebaseStorage.instance
          .refFromURL(url)
          .getData(30 * 1024 * 1024);
    } catch (_) {
      return null;
    }
  }

  Future<void> _runEnhancer(EnhancerMode mode) async {
    final onEdit = widget.onEdit;
    if (onEdit == null) return;

    setState(() => _busy = true);
    try {
      final bytes =
          widget.imageBytes ??
          (widget.imageUrl == null
              ? null
              : await _downloadBytes(widget.imageUrl!));
      if (!mounted || bytes == null) return;

      final result = await showGeneralDialog<Uint8List?>(
        context: context,
        barrierDismissible: false,
        barrierColor: Colors.transparent,
        transitionDuration: Duration.zero,
        pageBuilder: (ctx, _, _) => ImageEnhancerScreen(
          imageBytes: bytes,
          title: mode == EnhancerMode.crop
              ? 'Recadrer'
              : 'Améliorer les couleurs',
          mode: mode,
        ),
      );
      if (!mounted || result == null) return;
      await onEdit(mode, result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    Color? backgroundColor,
  }) {
    return Material(
      color: backgroundColor ?? Colors.black54,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: _busy ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Tooltip(
            message: tooltip,
            child: Icon(icon, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = widget.thumbnailUrl ?? widget.imageUrl;
    final hasImage =
        widget.imageBytes != null ||
        (imageUrl != null && imageUrl.isNotEmpty) ||
        widget.assetPath != null;
    final theme = Theme.of(context);

    return AspectRatio(
      aspectRatio: widget.aspectRatio,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: hasImage
                  ? widget.imageBytes != null
                        ? Image.memory(widget.imageBytes!, fit: BoxFit.cover)
                        : CachedNetworkImage(
                            imageUrl: imageUrl!,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Center(
                                child: CircularProgressIndicator(),
                              ),
                            ),
                            errorWidget: (_, _, _) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Center(
                                child: Icon(Icons.broken_image, size: 40),
                              ),
                            ),
                          )
                  : widget.assetPath != null
                  ? Image.asset(widget.assetPath!, fit: BoxFit.cover)
                  : Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          widget.emptyLabel,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
            ),
            if (widget.showSelectionOverlay && widget.selected)
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  color: theme.colorScheme.primary.withAlpha(70),
                  border: Border.all(
                    color: theme.colorScheme.primary,
                    width: 2,
                  ),
                ),
              ),
            if (widget.showActions && widget.onEdit != null)
              Positioned(
                top: 6,
                left: 6,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildActionButton(
                      icon: Icons.crop_outlined,
                      tooltip: widget.cropTooltip ?? 'Crop',
                      onPressed: () => _runEnhancer(EnhancerMode.crop),
                    ),
                    const SizedBox(height: 6),
                    _buildActionButton(
                      icon: Icons.tune_outlined,
                      tooltip: widget.colorTooltip ?? 'Couleur',
                      onPressed: () => _runEnhancer(EnhancerMode.color),
                    ),
                  ],
                ),
              ),
            if (widget.showActions && widget.onEnhanceAi != null)
              Positioned(
                top: 6,
                left: 54,
                child: _buildActionButton(
                  icon: Icons.auto_awesome,
                  tooltip: widget.aiTooltip ?? 'Enhance IA',
                  onPressed: () async {
                    setState(() => _busy = true);
                    try {
                      await widget.onEnhanceAi!();
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
                  backgroundColor: Colors.deepPurple.withValues(alpha: 0.85),
                ),
              ),
            if (widget.showActions && widget.onDelete != null)
              Positioned(
                top: 6,
                right: 6,
                child: _buildActionButton(
                  icon: Icons.delete_outline,
                  tooltip: widget.deleteTooltip ?? 'Supprimer',
                  onPressed: widget.onDelete!,
                  backgroundColor: theme.colorScheme.error.withValues(
                    alpha: 0.9,
                  ),
                ),
              ),
            if (_busy || widget.showBusyOverlay)
              Positioned.fill(
                child: Container(
                  color: Colors.black26,
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
