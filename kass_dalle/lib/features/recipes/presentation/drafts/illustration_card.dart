
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Vignette d'illustration d'un brouillon, avec ses actions.
///
/// Extrait de draft_review_widgets.dart.

class IllustrationCard extends StatelessWidget {
  final String url;

  /// URL de la vignette WebP 400px. Si null, utilise [url] (fallback anciens enregistrements).
  final String? thumbnailUrl;

  final VoidCallback? onDelete;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
  final VoidCallback? onEnhance;
  final bool enhancing;
  final bool selected;
  final VoidCallback? onSelectTap;

  const IllustrationCard({super.key, 
    required this.url,
    this.thumbnailUrl,
    this.onDelete,
    this.onTap,
    this.onEdit,
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
      onTap: isSelectMode ? onSelectTap : onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CachedNetworkImage(
              // Utilise la vignette WebP 400px pour la grille (chargement plus rapide),
              // fallback sur l'URL pleine résolution pour les anciens enregistrements.
              imageUrl: thumbnailUrl ?? url,
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
          if (onEdit != null)
            Positioned(
              bottom: 4,
              right: 4,
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: onEdit,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.tune, size: 14, color: Colors.white),
                        SizedBox(width: 4),
                        Text(
                          'Recadrer',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Panneau d'aperçu du document source ──────────────────────────────────────

