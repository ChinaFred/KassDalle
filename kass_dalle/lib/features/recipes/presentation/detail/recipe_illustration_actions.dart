import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/error_reporting.dart';
import '../recipe_providers.dart';
import 'recipe_detail_illustrations.dart';
import '../../../../core/utils/context_extensions.dart';

/// Ajout, consultation et suppression des illustrations d'une recette.
///
/// Ce code existait en double, à l'identique (119 lignes), dans le corps mobile
/// unifié et dans l'onglet « Préparer » de l'écran de détail. Toute correction
/// devait être faite deux fois, sans rien pour le rappeler.
///
/// L'état hôte doit exposer [recipeId] et [uploadingIllustration].
mixin RecipeIllustrationActions<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// Identifiant de la recette dont on modifie les illustrations.
  String get recipeId;

  /// Indicateur d'upload en cours, porté par l'état hôte pour son affichage.
  bool get uploadingIllustration;
  set uploadingIllustration(bool value);

  /// Propose caméra ou galerie, passe par l'améliorateur d'image, puis
  /// téléverse et rattache l'illustration à la recette.
  Future<void> addIllustration() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Prendre une photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choisir dans la galerie'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) {
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      preferredCameraDevice: source == ImageSource.camera
          ? CameraDevice.rear
          : CameraDevice.front,
      imageQuality: 85,
    );
    if (picked == null) {
      return;
    }
    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    final enhanced = await showGeneralDialog<Uint8List?>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, _, _) =>
          ImageEnhancerScreen(imageBytes: bytes, title: 'Illustration'),
    );
    if (!mounted) return;
    if (enhanced == null) {
      return;
    }

    if (mounted) setState(() => uploadingIllustration = true);
    String? url;
    try {
      url = await ref
          .read(recipeRepositoryProvider)
          .uploadRecipePhoto(recipeId, enhanced);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeIllustrationActions.addIllustration',
        error: e,
        stackTrace: stackTrace,
        context: {'etape': 'upload', 'recipeId': recipeId},
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur Storage : $e');
      }
      if (mounted) setState(() => uploadingIllustration = false);
      return;
    }

    try {
      await ref.read(recipeRepositoryProvider).addImageUrl(recipeId, url);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeIllustrationActions.addIllustration',
        error: e,
        stackTrace: stackTrace,
        context: {'etape': 'rattachement', 'recipeId': recipeId},
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur Firestore : $e');
      }
    } finally {
      if (mounted) setState(() => uploadingIllustration = false);
    }
  }

  void showGallery(List<String> urls, int startIndex) {
    showDialog<void>(
      context: context,
      builder: (ctx) =>
          IllustrationGallery(urls: urls, initialIndex: startIndex),
    );
  }

  Future<void> deleteIllustration(String url) async {
    try {
      await ref.read(recipeRepositoryProvider).removeImageUrl(recipeId, url);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeIllustrationActions.deleteIllustration',
        error: e,
        stackTrace: stackTrace,
        context: {'recipeId': recipeId},
      );
      if (!mounted) return;
      context.showErrorSnackBar('Erreur suppression : $e');
    }
  }
}
