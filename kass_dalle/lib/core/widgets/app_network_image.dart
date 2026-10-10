import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../theme/app_icon_size.dart';
import '../utils/app_image_url.dart';

export '../utils/app_image_url.dart' show ForeignImageUrl;

/// Le seul point d'affichage d'une image réseau de l'application.
///
/// Même interface que `CachedNetworkImage`, réduite aux paramètres qu'emploie
/// le projet. Une URL refusée par `isAppImageUrl` n'est jamais chargée :
/// `errorWidget` la remplace, ou à défaut [AppImageFallback] : un fond neutre
/// et l'icône d'image cassée, à la taille demandée.
///
/// La photo de profil Google n'y passe pas (exception, voir `isAppImageUrl`).
class AppNetworkImage extends StatelessWidget {
  const AppNetworkImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit,
    this.alignment = Alignment.center,
    this.filterQuality = FilterQuality.low,
    this.memCacheWidth,
    this.memCacheHeight,
    this.placeholder,
    this.errorWidget,
  });

  final String imageUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Alignment alignment;
  final FilterQuality filterQuality;
  final int? memCacheWidth;
  final int? memCacheHeight;
  final PlaceholderWidgetBuilder? placeholder;
  final LoadingErrorWidgetBuilder? errorWidget;

  @override
  Widget build(BuildContext context) {
    if (!isAppImageUrl(imageUrl)) {
      final fallback = errorWidget;
      if (fallback != null) {
        return fallback(context, imageUrl, ForeignImageUrl(imageUrl));
      }
      return AppImageFallback(width: width, height: height);
    }
    return CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      alignment: alignment,
      filterQuality: filterQuality,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: placeholder,
      errorWidget: errorWidget,
    );
  }
}

/// L'image de repli par défaut : fond `surfaceContainerHighest` et icône
/// `broken_image_outlined`. Un écran qui veut un vide le demande par son
/// `errorWidget`.
class AppImageFallback extends StatelessWidget {
  const AppImageFallback({
    super.key,
    this.width,
    this.height,
    this.tooltip,
    this.message,
  });

  final double? width;
  final double? height;

  /// Le texte au survol et lu par le lecteur d'écran, s'il en faut un.
  final String? tooltip;

  /// Une phrase sous l'icône, quand la place le permet.
  final String? message;

  /// Ce qu'un éditeur affiche pour une image insérée hors de Kass'Dalle.
  static const foreignInTextMessage =
      'Image extérieure : importez-la depuis la galerie';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final icon = Icon(
      Icons.broken_image_outlined,
      size: AppIconSize.medium,
      color: scheme.onSurfaceVariant,
    );
    final t = tooltip;
    final m = message;
    final Widget content = m == null
        ? icon
        : Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                icon,
                const SizedBox(height: 4),
                Text(
                  m,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
    return Container(
      width: width,
      height: height,
      color: scheme.surfaceContainerHighest,
      alignment: Alignment.center,
      child: t == null ? content : Tooltip(message: t, child: content),
    );
  }
}
