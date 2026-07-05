import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../../../auth/presentation/auth_providers.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_app_bar.dart';
import 'book_reader_navigation.dart';
import 'recipe_detail_widgets.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/services/recipe_pdf_export.dart';
import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/utils/platform_utils.dart';

class RecipeDetailScreen extends ConsumerStatefulWidget {
  final String recipeId;
  final bool scrollToAnnotations;
  final BookReadingContext readingContext;
  const RecipeDetailScreen({
    super.key,
    required this.recipeId,
    this.scrollToAnnotations = false,
    this.readingContext = const BookReadingContext(),
  });

  @override
  ConsumerState<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen> {
  final _annotationsKey = GlobalKey();
  final _prefetchedRecipeIds = <String>{};
  final _prefetchedPageIds = <String>{};
  bool _uploadingFreeCover = false;
  bool _redirected = false;
  TextEditingController? _rawCooklangCtrl;
  String? _portionsRecipeId;
  int? _basePortions;
  int? _selectedPortions;

  @override
  void initState() {
    super.initState();
    if (widget.scrollToAnnotations) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToAnnotations(),
      );
    }
  }

  @override
  void dispose() {
    _rawCooklangCtrl?.dispose();
    super.dispose();
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

  void _prefetchRecipe(String recipeId) {
    if (_prefetchedRecipeIds.contains(recipeId)) return;
    _prefetchedRecipeIds.add(recipeId);
    unawaited(() async {
      try {
        await ref.read(recipeDetailProvider(recipeId).future);
      } catch (_) {}
    }());
  }

  void _prefetchBookPage(String pageId) {
    if (_prefetchedPageIds.contains(pageId)) return;
    _prefetchedPageIds.add(pageId);
    unawaited(() async {
      try {
        await ref.read(recipeByIdProvider(pageId).future);
      } catch (_) {}
    }());
  }

  void _prefetchReaderItem(Recipe item) {
    if (item.pageType == PageType.recipe) {
      _prefetchRecipe(item.id);
      return;
    }
    _prefetchBookPage(item.id);
  }

  void _prefetchAround(BookReadingPosition? position) {
    if (position == null) return;
    _prefetchReaderItem(position.current);
    final previous = position.previous;
    if (previous != null) {
      _prefetchReaderItem(previous);
    }
    final next = position.next;
    if (next != null) {
      _prefetchReaderItem(next);
    }
  }

  Future<void> _changeFreeRecipeCover(String uid) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 600,
      imageQuality: 85,
    );
    if (picked == null || !mounted) return;
    final bytes = await picked.readAsBytes();
    if (!mounted) return;
    setState(() => _uploadingFreeCover = true);
    try {
      final oldUrl =
          ref.read(userByUidProvider(uid)).value?.freeRecipeCoverUrl ?? '';
      if (oldUrl.isNotEmpty) {
        await CachedNetworkImage.evictFromCache(oldUrl);
      }
      await ref
          .read(authRepositoryProvider)
          .uploadFreeRecipeCover(
            uid,
            bytes,
            oldUrl: oldUrl.isNotEmpty ? oldUrl : null,
          );
      ref.invalidate(userByUidProvider(uid));
      if (mounted) {
        context.showSuccessSnackBar('Couverture "Recette libre" mise à jour');
      }
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Erreur upload : $e');
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
    final readingPagesAsync = widget.readingContext.isEnabled
        ? ref.watch(
            widget.readingContext.showUnattached
                ? libresRecipesProvider(widget.readingContext.bookId!)
                : allPagesByBookProvider(widget.readingContext.bookId!),
          )
        : null;

    return recipeAsync.when(
      loading: () {
        final isMobile = MediaQuery.sizeOf(context).width < 700;
        return Scaffold(
          body: Center(
            child: isMobile
                ? const CircularProgressIndicator()
                : const Text('Chargement de la recette...'),
          ),
        );
      },
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
              if (mounted) {
                context.replace(
                  buildReaderBookPageLocation(recipe.id, widget.readingContext),
                );
              }
            });
          }
          return const Scaffold(
            body: Center(child: Text('Ouverture de la page...')),
          );
        }

        final readingPosition = readingPagesAsync == null
            ? null
            : resolveBookReadingPosition(
                readingPagesAsync.value ?? const [],
                recipe.id,
              );
        _prefetchAround(readingPosition);

        void openReaderItem(Recipe target) {
          _prefetchReaderItem(target);
          final location = target.pageType == PageType.recipe
              ? buildReaderRecipeLocation(target.id, widget.readingContext)
              : buildReaderBookPageLocation(target.id, widget.readingContext);
          context.go(location);
        }

        final ctrl = _rawCooklangCtrl ??= TextEditingController();
        if (ctrl.text != recipe.rawCooklang) ctrl.text = recipe.rawCooklang;
        final basePortions =
            recipe.portions ?? extractPortions(recipe.rawCooklang);
        if (_portionsRecipeId != recipe.id || _basePortions != basePortions) {
          _portionsRecipeId = recipe.id;
          _basePortions = basePortions;
          _selectedPortions = basePortions;
        }
        final canEdit =
            user != null && (user.canEdit || user.uid == recipe.createdBy);

        return Scaffold(
          appBar: RecipeDetailAppBar(
            recipe: recipe,
            user: user,
            canEdit: canEdit,
            uploadingFreeCover: _uploadingFreeCover,
            readingContext: widget.readingContext,
            onScrollToAnnotations: _scrollToAnnotations,
            onChangeCover: () => _changeFreeRecipeCover(recipe.createdBy),
            onCoverZoom: (url) => _showCoverZoom(context, url),
            onCopyAsDraft: () => _copyAsDraft(context, recipe, user!.uid),
            onDetachFromBook: () => _detachFromBook(context, recipe),
            onDeleteRecipe: () => _deleteRecipe(recipe),
            onExportPdf: () => _exportPdf(
              recipe,
              basePortions: _basePortions,
              selectedPortions: _selectedPortions,
            ),
          ),
          body: BookReaderViewport(
            position: readingPosition,
            onOpen: openReaderItem,
            child: RecipeDetailBody(
              recipeId: recipeId,
              ctrl: ctrl,
              recipe: recipe,
              canEdit: canEdit,
              annotationsKey: _annotationsKey,
              basePortions: _basePortions,
              selectedPortions: _selectedPortions,
              onSelectedPortionsChanged: (value) {
                if (_selectedPortions == value) return;
                setState(() => _selectedPortions = value);
              },
            ),
          ),
          bottomNavigationBar: BookReaderBottomBar(
            position: readingPosition,
            onOpen: openReaderItem,
          ),
          floatingActionButton: user != null
              ? FloatingActionButton(
                  tooltip: 'ajouter une annotation',
                  child: const Icon(Icons.comment_outlined),
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

  Future<void> _exportPdf(
    Recipe recipe, {
    int? basePortions,
    int? selectedPortions,
  }) async {
    bool includeImages = false;

    if (recipe.imageUrls.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final lastChoice = prefs.getBool('pdf_include_images') ?? true;

      if (!mounted) return;
      final choice = await _showPdfImageDialog(
        context,
        recipe.imageUrls.length,
        lastChoice,
      );
      if (choice == null) return; // annulé
      includeImages = choice;
      await prefs.setBool('pdf_include_images', choice);
    }

    if (!mounted) return;
    context.showSnackBar(
      'Génération du PDF…',
      duration: const Duration(seconds: 2),
    );
    try {
      final result = await exportRecipeToPdf(
        recipe,
        includeImages: includeImages,
        basePortions: basePortions,
        selectedPortions: selectedPortions,
      );
      if (!mounted) return;
      context.showSnackBar(
        '\u00ab\u00a0${recipe.titre}\u00a0\u00bb export\u00e9 en PDF',
        duration: const Duration(seconds: 8),
        action: PlatformUtils.isMobile
            ? SnackBarAction(
                label: 'Ouvrir',
                onPressed: () => openPdf(result.bytes, result.filename),
              )
            : null,
      );
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Erreur export PDF : $e');
    }
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
      context.push(
        isValidated
            ? buildReaderRecipeLocation(newId, const BookReadingContext())
            : '/drafts/$newId',
      );
    } catch (e) {
      if (!context.mounted) return;
      context.showErrorSnackBar('Erreur : $e');
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
      context.showErrorSnackBar('Erreur suppression : $e');
    }
  }

  Future<void> _detachFromBook(BuildContext context, Recipe recipe) async {
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
      await ref.read(recipeRepositoryProvider).detachRecipeFromBook(recipe.id);
      if (!context.mounted) return;
      context.showSuccessSnackBar('Recette détachée du livre.');
      ref.invalidate(recipeDetailProvider(recipe.id));
    } catch (e) {
      if (!context.mounted) return;
      context.showErrorSnackBar('Erreur : $e');
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

// ── Dialogue "Inclure les photos dans le PDF ?" ───────────────────────────────

/// Affiche une boîte de dialogue demandant si les photos doivent être incluses.
/// Retourne [null] si l'utilisateur annule, sinon le booléen choisi.
Future<bool?> _showPdfImageDialog(
  BuildContext context,
  int imageCount,
  bool initialInclude,
) {
  bool include = initialInclude;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) => AlertDialog(
        title: const Text('Export PDF'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Cette recette contient $imageCount '
              'photo${imageCount > 1 ? "s" : ""}.',
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Inclure les photos'),
              value: include,
              onChanged: (v) => setDlgState(() => include = v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(include),
            child: const Text('Exporter'),
          ),
        ],
      ),
    ),
  );
}
