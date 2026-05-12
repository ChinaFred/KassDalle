import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../cooklang_preview.dart';
import '../source_viewer.dart';
import '../recipe_rating_widget.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/presentation/book_providers.dart';
import 'shopping_list_sheet.dart';

class RecipeDetailScreen extends ConsumerStatefulWidget {
  final String recipeId;
  final bool scrollToAnnotations;
  const RecipeDetailScreen({
    super.key,
    required this.recipeId,
    this.scrollToAnnotations = false,
  });

  @override
  ConsumerState<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen> {
  final _annotationsKey = GlobalKey();
  bool _uploadingFreeCover = false;

  @override
  void initState() {
    super.initState();
    if (widget.scrollToAnnotations) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToAnnotations(),
      );
    }
  }

  void _scrollToAnnotations() {
    final ctx = _annotationsKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _changeFreeRecipeCover(String uid) async {
    debugPrint(
      '[FreeCover] Démarrage changement couverture recette libre – uid=$uid',
    );
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 600,
      imageQuality: 85,
    );
    if (picked == null || !mounted) {
      debugPrint('[FreeCover] Sélection annulée ou widget démonté');
      return;
    }
    final bytes = await picked.readAsBytes();
    debugPrint(
      '[FreeCover] Image sélectionnée – taille=${bytes.length} octets',
    );
    if (!mounted) return;
    setState(() => _uploadingFreeCover = true);
    try {
      // Évincer l'ancien URL du cache image avant l'upload.
      final oldUrl =
          ref.read(userByUidProvider(uid)).value?.freeRecipeCoverUrl ?? '';
      debugPrint(
        '[FreeCover] Ancien URL : ${oldUrl.isEmpty ? "(vide)" : oldUrl}',
      );
      if (oldUrl.isNotEmpty) {
        await CachedNetworkImage.evictFromCache(oldUrl);
      }

      // Nom de fichier unique pour forcer un nouvel URL Firebase Storage
      // (évite les problèmes de cache navigateur / CachedNetworkImage).
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = 'users/$uid/free_recipe_cover_$ts.jpg';
      debugPrint('[FreeCover] Upload Storage → $path');
      final storageRef = FirebaseStorage.instance.ref().child(path);
      final uploadTask = storageRef.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
      final snapshot = await uploadTask;
      debugPrint(
        '[FreeCover] Upload terminé – bytesTransferred=${snapshot.bytesTransferred}',
      );
      final url = await snapshot.ref.getDownloadURL();
      debugPrint('[FreeCover] Download URL obtenu : $url');

      // Supprimer l'ancien fichier Storage (nettoyage silencieux).
      if (oldUrl.isNotEmpty) {
        try {
          await FirebaseStorage.instance.refFromURL(oldUrl).delete();
          debugPrint('[FreeCover] Ancien fichier Storage supprimé');
        } catch (e) {
          debugPrint('[FreeCover] Nettoyage ancien fichier ignoré : $e');
        }
      }

      debugPrint(
        '[FreeCover] Mise à jour Firestore users/$uid.free_recipe_cover_url',
      );
      await ref.read(authRepositoryProvider).updateFreeRecipeCoverUrl(uid, url);
      ref.invalidate(userByUidProvider(uid));
      debugPrint('[FreeCover] ✓ Couverture mise à jour avec succès');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Couverture "Recette libre" mise à jour'),
          ),
        );
      }
    } catch (e, st) {
      debugPrint('[FreeCover] ✗ ERREUR : $e');
      debugPrint('[FreeCover] Stack : $st');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur upload : $e')));
      }
    } finally {
      if (mounted) setState(() => _uploadingFreeCover = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipeId = widget.recipeId;
    final recipeAsync = ref.watch(recipeDetailProvider(recipeId));
    final user = ref.watch(appUserProvider).value;
    final annotations = ref.watch(annotationsProvider(recipeId)).value ?? [];
    final noteCount = annotations
        .where((a) => a.type == AnnotationType.note)
        .length;
    final tipCount = annotations
        .where((a) => a.type == AnnotationType.tip)
        .length;
    final corrCount = annotations
        .where((a) => a.type == AnnotationType.correction)
        .length;

    return recipeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Erreur')),
        body: Center(child: Text('$e')),
      ),
      data: (recipe) {
        if (recipe == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Recette introuvable')),
          );
        }

        final ctrl = TextEditingController(text: recipe.rawCooklang);
        final canEdit =
            user != null && (user.canEdit || user.uid == recipe.createdBy);

        // Couverture du livre pour l'AppBar
        final bookId = recipe.bookId;
        final isOwnRecipe = user?.uid == recipe.createdBy;
        final coverUrl = (bookId != null && bookId.isNotEmpty)
            ? ref.watch(bookByIdProvider(bookId)).value?.urlCouverture ?? ''
            : '';
        // Cover "recette libre" : celle du propriétaire de la recette
        final ownerAsync = ref.watch(userByUidProvider(recipe.createdBy));
        final freeRecipeCoverUrl = ownerAsync.value?.freeRecipeCoverUrl ?? '';

        // ── Diagnostic couverture recette libre ──────────────────────────
        if (recipe.bookId == null) {
          debugPrint('[FreeCover:build] recipeId=${recipe.id}');
          debugPrint('[FreeCover:build] recipe.createdBy=${recipe.createdBy}');
          debugPrint('[FreeCover:build] user.uid=${user?.uid}');
          debugPrint('[FreeCover:build] user.role=${user?.role}');
          debugPrint('[FreeCover:build] user.canEdit=${user?.canEdit}');
          debugPrint('[FreeCover:build] isOwnRecipe=$isOwnRecipe');
          debugPrint('[FreeCover:build] canEdit (local)=$canEdit');
          debugPrint(
            '[FreeCover:build] ownerAsync.status=${ownerAsync.isLoading
                ? "loading"
                : ownerAsync.hasError
                ? "error(${ownerAsync.error})"
                : "loaded"}',
          );
          debugPrint(
            '[FreeCover:build] freeRecipeCoverUrl=${freeRecipeCoverUrl.isEmpty ? "(vide)" : freeRecipeCoverUrl}',
          );
          debugPrint(
            '[FreeCover:build] → bouton actif (changement): ${isOwnRecipe && canEdit}',
          );
        }

        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (coverUrl.isNotEmpty) ...[
                  GestureDetector(
                    onTap: () => _showCoverZoom(context, coverUrl),
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
                  // Cover "Recette libre" : custom ou défaut
                  GestureDetector(
                    onTap: isOwnRecipe && canEdit
                        ? () => _changeFreeRecipeCover(recipe.createdBy)
                        : freeRecipeCoverUrl.isNotEmpty
                        ? () => _showCoverZoom(context, freeRecipeCoverUrl)
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
                                      _DefaultFreeRecipeCover(
                                        isOwner: isOwnRecipe && canEdit,
                                      ),
                                )
                              : _DefaultFreeRecipeCover(
                                  isOwner: isOwnRecipe && canEdit,
                                ),
                        ),
                        if (_uploadingFreeCover)
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
                          RecipeRatingBadge(recipeId: recipeId),
                          if (noteCount > 0)
                            _AnnotBadge(
                              icon: Icons.sticky_note_2_outlined,
                              count: noteCount,
                              color: _annotNoteColor(Theme.of(context)),
                              foregroundColor: _annotNoteFg(Theme.of(context)),
                              onTap: _scrollToAnnotations,
                            ),
                          if (tipCount > 0)
                            _AnnotBadge(
                              icon: Icons.lightbulb_outline,
                              count: tipCount,
                              color: Theme.of(
                                context,
                              ).colorScheme.tertiaryContainer,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.onTertiaryContainer,
                              onTap: _scrollToAnnotations,
                            ),
                          if (corrCount > 0)
                            _AnnotBadge(
                              icon: Icons.build_circle_outlined,
                              count: corrCount,
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.onErrorContainer,
                              onTap: _scrollToAnnotations,
                            ),
                        ],
                      ),
                      if (recipe.bookTitre != null)
                        GestureDetector(
                          onTap: () => context.push(
                            '/recipes?bookId=${recipe.bookId ?? ''}&bookTitre=${Uri.encodeComponent(recipe.bookTitre!)}',
                          ),
                          child: Text(
                            [
                              recipe.bookTitre!,
                              if (recipe.pageNumber != null)
                                'pg\u00a0${recipe.pageNumber}',
                            ].join(', '),
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
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
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  decoration: TextDecoration.underline,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (recipe.createdBy != user?.uid)
                        _OwnerLabel(ownerUid: recipe.createdBy),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              SourceViewerButton(
                sourceFileUrl: recipe.sourceFileUrl,
                sourceFileName: recipe.sourceFileName,
              ),
              if (user != null && recipe.createdBy != user.uid)
                IconButton(
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: 'Copier comme mon brouillon',
                  onPressed: () => _copyAsDraft(context, recipe, user.uid),
                ),
              if (canEdit && recipe.bookId != null)
                IconButton(
                  icon: const Icon(Icons.link_off_outlined),
                  tooltip: 'Détacher du livre',
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Détacher cette recette ?'),
                        content: Text(
                          'La recette "${recipe.titre}" sera retirée de son livre et restera disponible en recette libre.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Annuler'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Détacher'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true || !context.mounted) return;

                    try {
                      await ref
                          .read(recipeRepositoryProvider)
                          .detachRecipeFromBook(recipe.id);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Recette détachée du livre.'),
                        ),
                      );
                      ref.invalidate(recipeDetailProvider(recipe.id));
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                    }
                  },
                ),
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Modifier la recette',
                  onPressed: () => context.push('/recipes/${recipe.id}/edit'),
                ),
            ],
          ),
          body: _RecipeDetailBody(
            recipeId: recipeId,
            ctrl: ctrl,
            recipe: recipe,
            canEdit: canEdit,
            annotationsKey: _annotationsKey,
          ),
          floatingActionButton: user != null
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.comment_outlined),
                  label: const Text('Annoter'),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _AnnotationDialog(recipeId: recipeId),
                  ),
                )
              : null,
        );
      },
    );
  }

  Future<void> _copyAsDraft(
    BuildContext context,
    Recipe recipe,
    String myUid,
  ) async {
    final isValidated = recipe.reviewStatus == ReviewStatus.validated;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copier cette recette ?'),
        content: Text(
          isValidated
              ? 'Une copie de « ${recipe.titre} » sera ajoutée directement à vos recettes.'
              : 'Une copie de « ${recipe.titre} » sera créée dans vos brouillons.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Copier'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final newId = await ref
          .read(recipeRepositoryProvider)
          .copyRecipeAsDraft(recipe: recipe, newOwnerUid: myUid);
      if (!context.mounted) return;
      context.push(isValidated ? '/recipes/$newId' : '/drafts/$newId');
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }

  void _showCoverZoom(BuildContext context, String coverUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                child: CachedNetworkImage(
                  imageUrl: coverUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorWidget: (_, _, _) => const Icon(
                    Icons.broken_image,
                    size: 64,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filled(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Body : preview + liste annotations ──────────────────────────────────────

class _RecipeDetailBody extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;
  final bool canEdit;
  final GlobalKey annotationsKey;
  const _RecipeDetailBody({
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEdit,
    required this.annotationsKey,
  });

  @override
  ConsumerState<_RecipeDetailBody> createState() => _RecipeDetailBodyState();
}

class _RecipeDetailBodyState extends ConsumerState<_RecipeDetailBody> {
  bool _uploadingIllustration = false;

  Future<void> _addIllustration() async {
    debugPrint(
      '[Illustration] Démarrage ajout illustration – recipeId=${widget.recipeId}',
    );
    // Laisser le choix : appareil photo ou galerie
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

    // Ouvre l'ImageEnhancer via un dialog overlay (au-dessus du FAB et de tout le reste)
    debugPrint('[Illustration] Ouverture ImageEnhancer');
    final enhanced = await showGeneralDialog<Uint8List?>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (ctx, _, __) =>
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
        '[Illustration] Écriture Firestore recipes/${widget.recipeId}.image_urls ← $url',
      );
      await ref
          .read(recipeRepositoryProvider)
          .addImageUrl(widget.recipeId, url);
      debugPrint('[Illustration] ✓ URL ajoutée avec succès');
      // Pas besoin d'invalidate : recipeDetailProvider est un StreamProvider temps réel
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
          _IllustrationGallery(urls: urls, initialIndex: startIndex),
    );
  }

  Future<void> _deleteIllustration(String url) async {
    try {
      await ref
          .read(recipeRepositoryProvider)
          .removeImageUrl(widget.recipeId, url);
      // Pas besoin d'invalidate : le StreamProvider se met à jour automatiquement
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
                (ctx, i) => _AnnotationTile(
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

class _DefaultFreeRecipeCover extends StatelessWidget {
  final bool isOwner;
  const _DefaultFreeRecipeCover({this.isOwner = false});

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

// ── Badge annotation ───────────────────────────────────────────────────────

class _AnnotBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;
  const _AnnotBadge({
    required this.icon,
    required this.count,
    required this.color,
    required this.foregroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: foregroundColor),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: TextStyle(fontSize: 11, color: foregroundColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tile annotation ──────────────────────────────────────────────────────────

class _AnnotationTile extends ConsumerWidget {
  final Annotation annotation;
  final String recipeId;
  const _AnnotationTile({required this.annotation, required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).value;
    final isOwner = user?.uid == annotation.uid;
    final isAdmin = user?.isAdmin ?? false;
    final theme = Theme.of(context);

    final (icon, color, label) = switch (annotation.type) {
      AnnotationType.note => (
        Icons.sticky_note_2_outlined,
        Colors.blue.shade100,
        'Note',
      ),
      AnnotationType.tip => (
        Icons.lightbulb_outline,
        theme.colorScheme.tertiaryContainer,
        'Astuce',
      ),
      AnnotationType.correction => (
        Icons.build_circle_outlined,
        theme.colorScheme.errorContainer,
        'Correction',
      ),
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Icon(icon, size: 18),
        ),
        title: Text(annotation.text),
        subtitle: Text(
          '${annotation.authorName} · $label',
          style: theme.textTheme.bodySmall,
        ),
        trailing: (isOwner || isAdmin)
            ? PopupMenuButton<_AnnotationAction>(
                onSelected: (action) async {
                  if (action == _AnnotationAction.edit) {
                    final result = await showDialog<_AnnotationEditResult>(
                      context: context,
                      builder: (_) => _AnnotationDialog(
                        recipeId: recipeId,
                        existing: annotation,
                      ),
                    );
                    if (result != null) {
                      await updateAnnotation(
                        ref: ref,
                        recipeId: recipeId,
                        annotationId: annotation.id,
                        text: result.text,
                        type: result.type,
                      );
                    }
                  } else {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Supprimer l\'annotation ?'),
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
                    if (confirmed == true) {
                      await deleteAnnotation(
                        ref: ref,
                        recipeId: recipeId,
                        annotationId: annotation.id,
                      );
                    }
                  }
                },
                itemBuilder: (_) => [
                  if (isOwner)
                    const PopupMenuItem(
                      value: _AnnotationAction.edit,
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Modifier'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: _AnnotationAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Supprimer'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

enum _AnnotationAction { edit, delete }

// ── Visionneuse illustrations plein écran ─────────────────────────────────

class _IllustrationGallery extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;

  const _IllustrationGallery({required this.urls, required this.initialIndex});

  @override
  State<_IllustrationGallery> createState() => _IllustrationGalleryState();
}

class _IllustrationGalleryState extends State<_IllustrationGallery> {
  late PageController _pageCtrl;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _pageCtrl = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          PageView.builder(
            controller: _pageCtrl,
            itemCount: widget.urls.length,
            onPageChanged: (i) => setState(() => _current = i),
            itemBuilder: (_, i) => InteractiveViewer(
              minScale: 0.5,
              maxScale: 6,
              child: CachedNetworkImage(
                imageUrl: widget.urls[i],
                fit: BoxFit.contain,
                placeholder: (_, _) => const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
                errorWidget: (_, _, _) => const Icon(
                  Icons.broken_image,
                  size: 64,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
          // Compteur
          if (widget.urls.length > 1)
            Positioned(
              bottom: 24,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    '${_current + 1} / ${widget.urls.length}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          // Flèches
          if (widget.urls.length > 1) ...[
            if (_current > 0)
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filled(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => _pageCtrl.previousPage(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                    ),
                  ),
                ),
              ),
            if (_current < widget.urls.length - 1)
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filled(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () => _pageCtrl.nextPage(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeInOut,
                    ),
                  ),
                ),
              ),
          ],
          // Fermer
          Positioned(
            top: 16,
            right: 16,
            child: IconButton.filled(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnnotationEditResult {
  final String text;
  final AnnotationType type;
  const _AnnotationEditResult({required this.text, required this.type});
}

// ── Dialog création / édition annotation ────────────────────────────────────

class _AnnotationDialog extends ConsumerStatefulWidget {
  final String recipeId;
  final Annotation? existing;
  const _AnnotationDialog({required this.recipeId, this.existing});

  @override
  ConsumerState<_AnnotationDialog> createState() => _AnnotationDialogState();
}

class _AnnotationDialogState extends ConsumerState<_AnnotationDialog> {
  late final TextEditingController _textCtrl;
  late AnnotationType _type;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.existing?.text ?? '');
    _type = widget.existing?.type ?? AnnotationType.note;
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _saving = true);
    try {
      if (widget.existing == null) {
        await addAnnotation(
          ref: ref,
          recipeId: widget.recipeId,
          text: text,
          type: _type,
        );
        if (mounted) Navigator.pop(context);
      } else {
        if (mounted) {
          Navigator.pop(
            context,
            _AnnotationEditResult(text: text, type: _type),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? 'Modifier l\'annotation' : 'Nouvelle annotation'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<AnnotationType>(
              segments: const [
                ButtonSegment(
                  value: AnnotationType.note,
                  label: Text('Note'),
                  icon: Icon(Icons.sticky_note_2_outlined),
                ),
                ButtonSegment(
                  value: AnnotationType.tip,
                  label: Text('Astuce'),
                  icon: Icon(Icons.lightbulb_outline),
                ),
                ButtonSegment(
                  value: AnnotationType.correction,
                  label: Text('Correction'),
                  icon: Icon(Icons.build_circle_outlined),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textCtrl,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Texte',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isEdit ? 'Mettre à jour' : 'Ajouter'),
        ),
      ],
    );
  }
}

// ── Couleurs fixes badge "Note" (bleu, adapté dark/light) ─────────────────────
Color _annotNoteColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF1565C0) // blue.shade800
    : const Color(0xFFBBDEFB); // blue.shade100

Color _annotNoteFg(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white
    : const Color(0xFF0D47A1); // blue.shade900

// ── Label propriétaire ────────────────────────────────────────────────────────

class _OwnerLabel extends ConsumerWidget {
  final String ownerUid;
  const _OwnerLabel({required this.ownerUid});

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
