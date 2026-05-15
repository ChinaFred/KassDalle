import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../cooklang_preview.dart';
import '../recipe_rating_widget.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../planning/presentation/schedule_recipe_sheet.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_illustrations.dart';
import 'shopping_list_sheet.dart';

// ── Body : preview + liste annotations ──────────────────────────────────────

class RecipeDetailBody extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;
  final bool canEdit;
  final GlobalKey annotationsKey;
  const RecipeDetailBody({
    super.key,
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEdit,
    required this.annotationsKey,
  });

  @override
  ConsumerState<RecipeDetailBody> createState() => _RecipeDetailBodyState();
}

class _RecipeDetailBodyState extends ConsumerState<RecipeDetailBody> {
  bool _uploadingIllustration = false;

  Future<void> _addIllustration() async {
    debugPrint(
      '[Illustration] Démarrage ajout illustration – recipeId=${widget.recipeId}',
    );
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
      debugPrint('[Illustration] Sélection source annulée');
      return;
    }
    debugPrint('[Illustration] Source choisie : $source');

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source, imageQuality: 85);
    if (picked == null) {
      debugPrint('[Illustration] Aucune image sélectionnée');
      return;
    }
    final bytes = await picked.readAsBytes();
    debugPrint('[Illustration] Image lue – taille=${bytes.length} octets');
    if (!mounted) return;

    debugPrint('[Illustration] Ouverture ImageEnhancer');
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
      debugPrint('[Illustration] ImageEnhancer annulé (enhanced == null)');
      return;
    }
    debugPrint(
      '[Illustration] Image améliorée – taille=${enhanced.length} octets',
    );

    if (mounted) setState(() => _uploadingIllustration = true);
    String? url;
    try {
      final path =
          'recipes/${widget.recipeId}/illus_${DateTime.now().millisecondsSinceEpoch}.jpg';
      debugPrint('[Illustration] Upload Storage → $path');
      final storageRef = FirebaseStorage.instance.ref().child(path);
      final snapshot = await storageRef.putData(
        enhanced,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      debugPrint(
        '[Illustration] Upload terminé – bytesTransferred=${snapshot.bytesTransferred}',
      );
      url = await snapshot.ref.getDownloadURL();
      debugPrint('[Illustration] Download URL obtenu : $url');
    } catch (e, st) {
      debugPrint('[Illustration] ✗ ERREUR Storage : $e');
      debugPrint('[Illustration] Stack : $st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur Storage : $e')));
      }
      if (mounted) setState(() => _uploadingIllustration = false);
      return;
    }

    try {
      debugPrint(
        '[Illustration] Écriture Firestore recipes/${widget.recipeId}.image_urls \u2190 $url',
      );
      await ref
          .read(recipeRepositoryProvider)
          .addImageUrl(widget.recipeId, url);
      debugPrint('[Illustration] \u2713 URL ajoutée avec succès');
    } catch (e, st) {
      debugPrint('[Illustration] ✗ ERREUR Firestore : $e');
      debugPrint('[Illustration] Stack : $st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur Firestore : $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingIllustration = false);
    }
  }

  void _showGallery(List<String> urls, int startIndex) {
    showDialog<void>(
      context: context,
      builder: (ctx) =>
          IllustrationGallery(urls: urls, initialIndex: startIndex),
    );
  }

  Future<void> _deleteIllustration(String url) async {
    try {
      await ref
          .read(recipeRepositoryProvider)
          .removeImageUrl(widget.recipeId, url);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur suppression : $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final annotationsAsync = ref.watch(annotationsProvider(widget.recipeId));
    final recipe = widget.recipe;

    final scrollView = CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Stack(
            children: [
              CooklangPreview(
                ctrl: widget.ctrl,
                overrideIngredients: recipe.ingredients,
                illustrationUrls: recipe.imageUrls.isNotEmpty
                    ? recipe.imageUrls
                    : null,
                onAddIllustration: widget.canEdit ? _addIllustration : null,
                onTapIllustration: recipe.imageUrls.isNotEmpty
                    ? (i) => _showGallery(recipe.imageUrls, i)
                    : null,
                onDeleteIllustration: widget.canEdit
                    ? _deleteIllustration
                    : null,
                onCreateShoppingList: recipe.ingredients.isNotEmpty
                    ? () {
                        final uid = ref.read(appUserProvider).value?.uid ?? '';
                        showShoppingListSheet(
                          context,
                          recipe.ingredients,
                          recipe.titre,
                          uid,
                        );
                      }
                    : null,
                onSchedule: recipe.ingredients.isNotEmpty
                    ? () => showScheduleRecipeSheet(
                          context,
                          titre: recipe.titre,
                          recipeId: recipe.id,
                          prepTimeMin: recipe.tags.prepTime,
                          cookTimeMin: recipe.tags.cookTime,
                          ingredients: recipe.ingredients,
                        )
                    : null,
                dishTypes: recipe.tags.dishTypes.isNotEmpty
                    ? recipe.tags.dishTypes
                    : null,
              ),
              if (_uploadingIllustration)
                Positioned.fill(
                  child: Container(
                    color: Colors.black26,
                    child: const Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: RecipeRatingEditor(recipeId: widget.recipeId),
        ),
        SliverToBoxAdapter(
          child: Padding(
            key: widget.annotationsKey,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Annotations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
          ),
        ),
        annotationsAsync.when(
          loading: () => const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) =>
              SliverToBoxAdapter(child: Center(child: Text('Erreur : $e'))),
          data: (annotations) {
            if (annotations.isEmpty) {
              return const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'Aucune annotation. Soyez le premier !',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              );
            }
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => AnnotationTile(
                  annotation: annotations[i],
                  recipeId: widget.recipeId,
                ),
                childCount: annotations.length,
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );

    return scrollView;
  }
}

// ── Couverture par défaut "Recette libre" ──────────────────────────────────

class RecipeDetailFreeRecipeCover extends StatelessWidget {
  final bool isOwner;
  const RecipeDetailFreeRecipeCover({super.key, this.isOwner = false});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.secondaryContainer;
    final fg = Theme.of(context).colorScheme.onSecondaryContainer;
    return Container(
      width: 32,
      height: 44,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.menu_book_rounded, size: 18, color: fg),
          if (isOwner)
            Positioned(
              bottom: 2,
              right: 2,
              child: Icon(
                Icons.add_a_photo_outlined,
                size: 9,
                color: fg.withOpacity(0.7),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Label propriétaire ────────────────────────────────────────────────────────

class RecipeDetailOwnerLabel extends ConsumerWidget {
  final String ownerUid;
  const RecipeDetailOwnerLabel({super.key, required this.ownerUid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownerAsync = ref.watch(userByUidProvider(ownerUid));
    final name = ownerAsync.value?.displayName;
    if (name == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.person_outline,
          size: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        Text(
          name,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
