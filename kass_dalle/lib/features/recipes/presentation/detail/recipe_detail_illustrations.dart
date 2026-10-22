import 'package:flutter/material.dart';

import '../../../../core/presentation/app_image_viewer.dart';

/// Ouvre la visionneuse commune sur les illustrations [urls], à partir de
/// [initialIndex]. [title] : « Illustrations » pour une recette,
/// « Illustrations de la page » pour une page de livre.
Future<void> showIllustrationGallery(
  BuildContext context,
  List<String> urls, {
  int initialIndex = 0,
  String title = 'Illustrations',
}) {
  return showAppImageViewer(
    context,
    images: [
      for (final url in urls)
        AppViewerImage.network(url, semanticLabel: 'Illustration'),
    ],
    initialIndex: initialIndex,
    title: title,
    itemLabel: 'Illustration',
  );
}
