import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../source_viewer.dart';
import '../recipe_rating_widget.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../books/presentation/book_providers.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_widgets.dart';

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
  bool _redirected = false;

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

        // Une page non-recette s'affiche via BookPageDetailScreen
        if (recipe.pageType != PageType.recipe) {
          if (!_redirected) {
            _redirected = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) context.replace('/book-pages/${recipe.id}');
            });
          }
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
                                      RecipeDetailFreeRecipeCover(
                                        isOwner: isOwnRecipe && canEdit,
                                      ),
                                )
                              : RecipeDetailFreeRecipeCover(
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
                            DetailAnnotBadge(
                              icon: Icons.sticky_note_2_outlined,
                              count: noteCount,
                              color: annotNoteColor(Theme.of(context)),
                              foregroundColor: annotNoteFg(Theme.of(context)),
                              onTap: _scrollToAnnotations,
                            ),
                          if (tipCount > 0)
                            DetailAnnotBadge(
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
                            DetailAnnotBadge(
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
                        RecipeDetailOwnerLabel(ownerUid: recipe.createdBy),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              SourceViewerButton(
                sourceFileUrl: recipe.sourceFileUrl,
                sourceFileName: recipe.sourceFileName,
                additionalSourceFileUrls: recipe.additionalSourceFileUrls,
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
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Supprimer la recette',
                  color: Theme.of(context).colorScheme.error,
                  onPressed: () => _deleteRecipe(recipe),
                ),
            ],
          ),
          body: RecipeDetailBody(
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
                    builder: (_) => AnnotationDialog(recipeId: recipeId),
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

  Future<void> _deleteRecipe(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette recette ?'),
        content: Text(
          '« ${recipe.titre} » sera définitivement supprimée et ne pourra pas être récupérée.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(recipeRepositoryProvider).deleteRecipe(recipe.id);
      if (!mounted) return;
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur suppression : $e')));
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

