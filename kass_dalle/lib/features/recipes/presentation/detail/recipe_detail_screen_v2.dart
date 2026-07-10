import 'dart:async';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/services/recipe_pdf_export.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/utils/recipe_portion_scaler.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../planning/presentation/schedule_recipe_sheet.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import '../recipe_providers.dart';
import '../recipe_rating_widget.dart';
import 'book_reader_navigation.dart';
import '../ai/ai_ui_copy.dart';
import 'dressing_coach_screen.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_app_bar.dart';
import 'recipe_detail_illustrations.dart';
import 'shopping_list_sheet.dart';

class RecipeDetailScreenV2 extends ConsumerStatefulWidget {
  final String recipeId;
  final bool scrollToAnnotations;
  final BookReadingContext readingContext;

  const RecipeDetailScreenV2({
    super.key,
    required this.recipeId,
    this.scrollToAnnotations = false,
    this.readingContext = const BookReadingContext(),
  });

  @override
  ConsumerState<RecipeDetailScreenV2> createState() =>
      _RecipeDetailScreenV2State();
}

class _RecipeDetailScreenV2State extends ConsumerState<RecipeDetailScreenV2>
    with SingleTickerProviderStateMixin {
  final _annotationsKey = GlobalKey();
  final _prefetchedRecipeIds = <String>{};
  final _prefetchedPageIds = <String>{};
  bool _uploadingFreeCover = false;
  bool _redirected = false;
  bool _isMobileLayout = false;
  bool _mobileKitchenMode = false;
  TextEditingController? _rawCooklangCtrl;
  String? _portionsRecipeId;
  int? _basePortions;
  int? _selectedPortions;
  String? _loadedOverrideKey;
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.scrollToAnnotations ? 1 : 0,
    );
    if (widget.scrollToAnnotations) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _scrollToAnnotations(),
      );
    }
  }

  @override
  void dispose() {
    _rawCooklangCtrl?.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _scrollToAnnotations() {
    if (_isMobileLayout) {
      unawaited(_openCommunitySheet());
      return;
    }
    _tabController.animateTo(1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _annotationsKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  Future<void> _openCommunitySheet() {
    final sheetAnnotationsKey = GlobalKey();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.92,
        child: Column(
          children: [
            ListTile(
              title: const Text('Communaute'),
              trailing: IconButton(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Fermer',
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _CommunityTab(
                recipeId: widget.recipeId,
                annotationsKey: sheetAnnotationsKey,
              ),
            ),
          ],
        ),
      ),
    );
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
        context.showSuccessSnackBar('Couverture "Recette libre" mise a jour');
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
    _isMobileLayout = MediaQuery.sizeOf(context).width < 700;
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
      loading: () => Scaffold(
        body: Center(
          child: _isMobileLayout
              ? const CircularProgressIndicator()
              : const Text('Chargement de la recette...'),
        ),
      ),
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
          _loadedOverrideKey = null;
        }
        final uid = user?.uid;
        if (uid != null && _portionsRecipeId != null) {
          final key = '$uid/${_portionsRecipeId!}';
          if (_loadedOverrideKey != key) {
            _loadedOverrideKey = key;
            Future<void>(() async {
              try {
                final persisted = await ref
                    .read(recipeRepositoryProvider)
                    .getPortionsOverride(uid, _portionsRecipeId!);
                if (!mounted || _loadedOverrideKey != key) return;
                if (persisted != null &&
                    persisted > 0 &&
                    _selectedPortions != persisted) {
                  setState(() => _selectedPortions = persisted);
                }
              } catch (_) {
                // Best-effort: on conserve la valeur locale en cas d'erreur.
              }
            });
          }
        }
        final canEdit =
            user != null && (user.canEdit || user.uid == recipe.createdBy);

        Future<void> onSelectedPortionsChanged(int value) async {
          if (_selectedPortions == value) return;
          setState(() => _selectedPortions = value);
          if (uid == null || _portionsRecipeId == null) return;
          try {
            await ref
                .read(recipeRepositoryProvider)
                .savePortionsOverride(
                  uid: uid,
                  recipeId: _portionsRecipeId!,
                  selectedPortions: value,
                );
            await ref
                .read(recipeRepositoryProvider)
                .recomputeNutrition(
                  recipeId: _portionsRecipeId!,
                  selectedPortions: value,
                );
          } catch (e) {
            if (!context.mounted) return;
            context.showErrorSnackBar('Erreur recalcul nutrition : $e');
          }
        }

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
            onModifyWithAi: () => _modifyRecipeWithAi(recipe),
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
            enableNavigation: !_isMobileLayout || !_mobileKitchenMode,
            child: _isMobileLayout
                ? _MobileUnifiedBody(
                    recipeId: recipeId,
                    ctrl: ctrl,
                    recipe: recipe,
                    canEdit: canEdit,
                    basePortions: _basePortions,
                    selectedPortions: _selectedPortions,
                    kitchenMode: _mobileKitchenMode,
                    onKitchenModeChanged: (value) {
                      if (_mobileKitchenMode == value) return;
                      setState(() => _mobileKitchenMode = value);
                    },
                    onSelectedPortionsChanged: (value) {
                      unawaited(onSelectedPortionsChanged(value));
                    },
                    onOpenCommunity: _openCommunitySheet,
                  )
                : Column(
                    children: [
                      Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: TabBar(
                          controller: _tabController,
                          tabs: const [
                            Tab(
                              icon: Icon(Icons.restaurant_menu),
                              text: 'Preparer',
                            ),
                            Tab(
                              icon: Icon(Icons.forum_outlined),
                              text: 'Communaute',
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _PrepareTab(
                              recipeId: recipeId,
                              ctrl: ctrl,
                              recipe: recipe,
                              canEdit: canEdit,
                              basePortions: _basePortions,
                              selectedPortions: _selectedPortions,
                              onSelectedPortionsChanged: (value) {
                                unawaited(onSelectedPortionsChanged(value));
                              },
                            ),
                            _CommunityTab(
                              recipeId: recipeId,
                              annotationsKey: _annotationsKey,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          bottomNavigationBar: _isMobileLayout && _mobileKitchenMode
              ? null
              : BookReaderBottomBar(
                  position: readingPosition,
                  onOpen: openReaderItem,
                  showProgressChip: true,
                ),
          floatingActionButton:
              user != null && (!_isMobileLayout || !_mobileKitchenMode)
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
      if (choice == null) return;
      includeImages = choice;
      await prefs.setBool('pdf_include_images', choice);
    }

    if (!mounted) return;
    context.showSnackBar(
      'Generation du PDF...',
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
        '" ${recipe.titre} " exporte en PDF',
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
              ? 'Une copie de "${recipe.titre}" sera ajoutee directement a vos recettes.'
              : 'Une copie de "${recipe.titre}" sera creee dans vos brouillons.',
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

  Future<void> _modifyRecipeWithAi(Recipe recipe) async {
    final myUid = ref.read(appUserProvider).value?.uid;
    if (myUid == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ameliorer cette recette avec l\'IA ?'),
        content: Text(
          'Une copie brouillon de "${recipe.titre}" sera creee puis ouverte avec l\'outil IA de modification.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(RecipeAiUiCopy.refineDialogPrimaryCta),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      final draftId = await ref
          .read(recipeRepositoryProvider)
          .copyRecipeAsDraft(
            recipe: recipe,
            newOwnerUid: myUid,
            forceDraft: true,
          );
      if (!mounted) return;
      context.push('/drafts/$draftId?ai=true');
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Erreur : $e');
    }
  }

  Future<void> _deleteRecipe(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette recette ?'),
        content: Text(
          '" ${recipe.titre} " sera definitivement supprimee et ne pourra pas etre recuperee.',
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
        title: const Text('Detacher cette recette ?'),
        content: Text(
          'La recette "${recipe.titre}" sera retiree de son livre et restera disponible en recette libre.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Detacher'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(recipeRepositoryProvider).detachRecipeFromBook(recipe.id);
      if (!context.mounted) return;
      context.showSuccessSnackBar('Recette detachee du livre.');
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

class _MobileUnifiedBody extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;
  final bool canEdit;
  final int? basePortions;
  final int? selectedPortions;
  final bool kitchenMode;
  final ValueChanged<bool> onKitchenModeChanged;
  final ValueChanged<int>? onSelectedPortionsChanged;
  final Future<void> Function() onOpenCommunity;

  const _MobileUnifiedBody({
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEdit,
    this.basePortions,
    this.selectedPortions,
    required this.kitchenMode,
    required this.onKitchenModeChanged,
    this.onSelectedPortionsChanged,
    required this.onOpenCommunity,
  });

  @override
  ConsumerState<_MobileUnifiedBody> createState() => _MobileUnifiedBodyState();
}

class _MobileUnifiedBodyState extends ConsumerState<_MobileUnifiedBody> {
  bool _uploadingIllustration = false;

  Future<void> _addIllustration() async {
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

    if (mounted) setState(() => _uploadingIllustration = true);
    String? url;
    try {
      url = await ref
          .read(recipeRepositoryProvider)
          .uploadRecipePhoto(widget.recipeId, enhanced);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur Storage : $e')));
      }
      if (mounted) setState(() => _uploadingIllustration = false);
      return;
    }

    try {
      await ref
          .read(recipeRepositoryProvider)
          .addImageUrl(widget.recipeId, url);
    } catch (e) {
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
    final recipe = widget.recipe;
    final basePortions = widget.basePortions;
    final selectedPortions = widget.selectedPortions;
    final scaleFactor =
        basePortions != null &&
            selectedPortions != null &&
            basePortions > 0 &&
            selectedPortions > 0
        ? portionScaleFactor(
            basePortions: basePortions,
            targetPortions: selectedPortions,
          )
        : 1.0;
    final scaledIngredients = scaleRecipeIngredients(
      recipe.ingredients,
      scaleFactor,
    );
    final topContent = Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          SwitchListTile.adaptive(
            value: widget.kitchenMode,
            onChanged: widget.onKitchenModeChanged,
            title: const Text('Mode cuisine'),
            secondary: const Icon(Icons.soup_kitchen_outlined),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: NutritionPanel(
              recipe: recipe,
              selectedPortions: selectedPortions,
              onRecompute: () async {
                final portions = selectedPortions ?? basePortions ?? 1;
                await ref
                    .read(recipeRepositoryProvider)
                    .recomputeNutrition(
                      recipeId: widget.recipeId,
                      selectedPortions: portions,
                    );
              },
            ),
          ),
        ],
      ),
    );

    Widget preview = CooklangPreview(
      ctrl: widget.ctrl,
      topContent: topContent,
      bottomContent: widget.kitchenMode
          ? Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.restaurant,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DressingCoachEntryCard(
                        recipe: recipe,
                        basePortions: basePortions,
                        selectedPortions: selectedPortions,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : _MobileCommunitySummary(
              recipeId: widget.recipeId,
              onOpenCommunity: widget.onOpenCommunity,
            ),
      overrideIngredients: recipe.ingredients,
      basePortions: basePortions,
      selectedPortions: selectedPortions,
      onSelectedPortionsChanged: widget.onSelectedPortionsChanged,
      illustrationUrls: recipe.imageUrls.isNotEmpty ? recipe.imageUrls : null,
      onAddIllustration: widget.canEdit && !widget.kitchenMode
          ? _addIllustration
          : null,
      onTapIllustration: recipe.imageUrls.isNotEmpty
          ? (i) => _showGallery(recipe.imageUrls, i)
          : null,
      onDeleteIllustration: widget.canEdit && !widget.kitchenMode
          ? _deleteIllustration
          : null,
      onCreateShoppingList: recipe.ingredients.isNotEmpty
          ? () {
              final uid = ref.read(appUserProvider).value?.uid ?? '';
              final scaledProducts = scaleShoppingProducts(
                recipe.shoppingProducts,
                scaleFactor,
              );
              showShoppingListSheet(
                context,
                scaledProducts,
                scaledIngredients,
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
      recipeTags: recipe.tags,
    );

    if (widget.kitchenMode) {
      preview = MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(1.1)),
        child: preview,
      );
    }

    return Stack(
      children: [
        preview,
        if (_uploadingIllustration)
          Positioned.fill(
            child: Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}

class _MobileCommunitySummary extends ConsumerWidget {
  final String recipeId;
  final Future<void> Function() onOpenCommunity;

  const _MobileCommunitySummary({
    required this.recipeId,
    required this.onOpenCommunity,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotationsAsync = ref.watch(annotationsProvider(recipeId));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Communaute',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onOpenCommunity,
                  icon: const Icon(Icons.open_in_full, size: 18),
                  label: const Text('Voir tout'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            RecipeRatingEditor(recipeId: recipeId),
            const SizedBox(height: 8),
            annotationsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Erreur : $e'),
              data: (annotations) {
                if (annotations.isEmpty) {
                  return const Text('Aucune annotation pour le moment.');
                }
                final items = annotations.take(3).toList();
                return Column(
                  children: [
                    for (final annotation in items)
                      AnnotationTile(
                        annotation: annotation,
                        recipeId: recipeId,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PrepareTab extends ConsumerStatefulWidget {
  final String recipeId;
  final TextEditingController ctrl;
  final Recipe recipe;
  final bool canEdit;
  final int? basePortions;
  final int? selectedPortions;
  final ValueChanged<int>? onSelectedPortionsChanged;

  const _PrepareTab({
    required this.recipeId,
    required this.ctrl,
    required this.recipe,
    required this.canEdit,
    this.basePortions,
    this.selectedPortions,
    this.onSelectedPortionsChanged,
  });

  @override
  ConsumerState<_PrepareTab> createState() => _PrepareTabState();
}

class _PrepareTabState extends ConsumerState<_PrepareTab> {
  bool _uploadingIllustration = false;

  Future<void> _addIllustration() async {
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

    if (mounted) setState(() => _uploadingIllustration = true);
    String? url;
    try {
      url = await ref
          .read(recipeRepositoryProvider)
          .uploadRecipePhoto(widget.recipeId, enhanced);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur Storage : $e')));
      }
      if (mounted) setState(() => _uploadingIllustration = false);
      return;
    }

    try {
      await ref
          .read(recipeRepositoryProvider)
          .addImageUrl(widget.recipeId, url);
    } catch (e) {
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
    final recipe = widget.recipe;
    final basePortions = widget.basePortions;
    final selectedPortions = widget.selectedPortions;
    final scaleFactor =
        basePortions != null &&
            selectedPortions != null &&
            basePortions > 0 &&
            selectedPortions > 0
        ? portionScaleFactor(
            basePortions: basePortions,
            targetPortions: selectedPortions,
          )
        : 1.0;
    final scaledIngredients = scaleRecipeIngredients(
      recipe.ingredients,
      scaleFactor,
    );

    return SingleChildScrollView(
      child: Stack(
        children: [
          CooklangPreview(
            ctrl: widget.ctrl,
            topContent: Column(
              children: [
                DressingCoachEntryCard(
                  recipe: recipe,
                  basePortions: basePortions,
                  selectedPortions: selectedPortions,
                ),
                const SizedBox(height: 8),
                NutritionPanel(
                  recipe: recipe,
                  selectedPortions: selectedPortions,
                  onRecompute: () async {
                    final portions = selectedPortions ?? basePortions ?? 1;
                    await ref
                        .read(recipeRepositoryProvider)
                        .recomputeNutrition(
                          recipeId: widget.recipeId,
                          selectedPortions: portions,
                        );
                  },
                ),
              ],
            ),
            overrideIngredients: recipe.ingredients,
            basePortions: basePortions,
            selectedPortions: selectedPortions,
            onSelectedPortionsChanged: widget.onSelectedPortionsChanged,
            illustrationUrls: recipe.imageUrls.isNotEmpty
                ? recipe.imageUrls
                : null,
            onAddIllustration: widget.canEdit ? _addIllustration : null,
            onTapIllustration: recipe.imageUrls.isNotEmpty
                ? (i) => _showGallery(recipe.imageUrls, i)
                : null,
            onDeleteIllustration: widget.canEdit ? _deleteIllustration : null,
            onCreateShoppingList: recipe.ingredients.isNotEmpty
                ? () {
                    final uid = ref.read(appUserProvider).value?.uid ?? '';
                    final scaledProducts = scaleShoppingProducts(
                      recipe.shoppingProducts,
                      scaleFactor,
                    );
                    showShoppingListSheet(
                      context,
                      scaledProducts,
                      scaledIngredients,
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
            recipeTags: recipe.tags,
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
    );
  }
}

class NutritionPanel extends StatefulWidget {
  final Recipe recipe;
  final int? selectedPortions;
  final Future<void> Function() onRecompute;

  const NutritionPanel({
    super.key,
    required this.recipe,
    required this.selectedPortions,
    required this.onRecompute,
  });

  @override
  State<NutritionPanel> createState() => _NutritionPanelState();
}

class _NutritionPanelState extends State<NutritionPanel> {
  bool _detail = false;
  bool _loading = false;

  static const _rows = [
    ('kcal', 'Calories (kcal)'),
    ('protein_g', 'Proteines (g)'),
    ('carbs_g', 'Glucides (g)'),
    ('sugar_g', 'Sucres (g)'),
    ('fiber_g', 'Fibres (g)'),
    ('fat_g', 'Lipides (g)'),
    ('saturated_fat_g', 'Satures (g)'),
    ('salt_g', 'Sel (g)'),
  ];

  String _fmt(double? v, {bool integer = false}) {
    if (v == null) return '-';
    return integer ? v.round().toString() : v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.recipe.nutrition;
    final hasSnapshot = n != null;
    final hasValues = n != null && n.perPortion.isNotEmpty;

    Future<void> recompute() async {
      setState(() => _loading = true);
      try {
        await widget.onRecompute();
      } catch (e) {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur recalcul nutrition : $e')),
        );
      } finally {
        if (mounted) setState(() => _loading = false);
      }
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.monitor_heart_outlined, size: 18),
                const SizedBox(width: 8),
                const Text('Nutrition'),
                const Spacer(),
                if (hasSnapshot)
                  FilledButton.tonal(
                    onPressed: () => setState(() => _detail = !_detail),
                    child: Text(_detail ? 'Basique' : 'Detail'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (!hasSnapshot)
              Row(
                children: [
                  const Expanded(
                    child: Text('Aucune donnee nutritionnelle calculee.'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _loading ? null : recompute,
                    icon: _loading
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.calculate_outlined),
                    label: const Text('Calculer'),
                  ),
                ],
              )
            else ...[
              if (!hasValues)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Calcul effectue mais aucun nutriment exploitable n\'a ete trouve '
                    '(couverture ${(n.coverage * 100).toStringAsFixed(0)}%). '
                    'Verifiez les ingredients, quantites et unites.',
                  ),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MiniMetric(
                    label: 'Calories / portion',
                    value: '${_fmt(n.perPortion['kcal'], integer: true)} kcal',
                  ),
                  _MiniMetric(
                    label: 'Proteines',
                    value: '${_fmt(n.perPortion['protein_g'])} g',
                  ),
                  _MiniMetric(
                    label: 'Glucides',
                    value: '${_fmt(n.perPortion['carbs_g'])} g',
                  ),
                  _MiniMetric(
                    label: 'Lipides',
                    value: '${_fmt(n.perPortion['fat_g'])} g',
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Chip(
                    label: Text(
                      'Qualite ${n.quality.level} (${n.quality.score})',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Chip(
                    label: Text(
                      'Couverture ${(n.coverage * 100).toStringAsFixed(0)} %',
                    ),
                  ),
                ],
              ),
              if (_detail) ...[
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Nutriment')),
                      DataColumn(label: Text('Total')),
                      DataColumn(label: Text('Portion')),
                      DataColumn(label: Text('100 g')),
                    ],
                    rows: [
                      for (final row in _rows)
                        DataRow(
                          cells: [
                            DataCell(Text(row.$2)),
                            DataCell(
                              Text(
                                _fmt(
                                  n.totals[row.$1],
                                  integer: row.$1 == 'kcal',
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _fmt(
                                  n.perPortion[row.$1],
                                  integer: row.$1 == 'kcal',
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _fmt(
                                  n.per100g?[row.$1],
                                  integer: row.$1 == 'kcal',
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: _loading ? null : recompute,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Recalculer'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;

  const _MiniMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

class _CommunityTab extends ConsumerWidget {
  final String recipeId;
  final GlobalKey annotationsKey;

  const _CommunityTab({required this.recipeId, required this.annotationsKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotationsAsync = ref.watch(annotationsProvider(recipeId));
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: RecipeRatingEditor(recipeId: recipeId)),
        SliverToBoxAdapter(
          child: Padding(
            key: annotationsKey,
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
                  recipeId: recipeId,
                ),
                childCount: annotations.length,
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

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
