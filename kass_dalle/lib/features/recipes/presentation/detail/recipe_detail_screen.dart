import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/services/recipe_pdf_export.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import 'book_reader_navigation.dart';
import '../ai/ai_ui_copy.dart';
import 'tabs/community_tab.dart';
import 'tabs/dressing_tab.dart';
import 'tabs/mobile_unified_body.dart';
import 'tabs/nutrition_tab.dart';
import 'tabs/prepare_tab.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_app_bar.dart';
import '../../../../core/services/error_reporting.dart';

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

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen>
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
      length: 4,
      vsync: this,
      initialIndex: widget.scrollToAnnotations ? 3 : 0,
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
    _tabController.animateTo(2);
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
              child: CommunityTab(
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
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'recipeDetailScreen.prefetchRecipe',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }());
  }

  void _prefetchBookPage(String pageId) {
    if (_prefetchedPageIds.contains(pageId)) return;
    _prefetchedPageIds.add(pageId);
    unawaited(() async {
      try {
        await ref.read(recipeByIdProvider(pageId).future);
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'recipeDetailScreen.prefetchBookPage',
          error: error,
          stackTrace: stackTrace,
        );
      }
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
        context.showSuccessSnackBar('Couverture « Recette libre » mise à jour');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailScreen.changeFreeRecipeCover',
        error: e,
        stackTrace: stackTrace,
      );
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
              } catch (error, stackTrace) {
                reportUnexpectedError(
                  feature: 'recipeDetailScreen.build',
                  error: error,
                  stackTrace: stackTrace,
                );
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
          } catch (e, stackTrace) {
            reportUnexpectedError(
              feature: 'recipeDetailScreen.onSelectedPortionsChanged',
              error: e,
              stackTrace: stackTrace,
            );
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
                ? MobileUnifiedBody(
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
                              text: 'Préparer',
                            ),
                            Tab(
                              icon: Icon(Icons.monitor_heart_outlined),
                              text: 'Nutrition',
                            ),
                            Tab(
                              icon: Icon(Icons.style_outlined),
                              text: 'Dressage',
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
                            PrepareTab(
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
                            NutritionTab(
                              recipeId: recipeId,
                              recipe: recipe,
                              basePortions: _basePortions,
                              selectedPortions: _selectedPortions,
                            ),
                            DressingTab(
                              recipe: recipe,
                              basePortions: _basePortions,
                              selectedPortions: _selectedPortions,
                            ),
                            CommunityTab(
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
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailScreen.exportPdf',
        error: e,
        stackTrace: stackTrace,
      );
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
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailScreen.copyAsDraft',
        error: e,
        stackTrace: stackTrace,
      );
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
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailScreen.modifyRecipeWithAi',
        error: e,
        stackTrace: stackTrace,
      );
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
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailScreen.deleteRecipe',
        error: e,
        stackTrace: stackTrace,
      );
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
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailScreen.detachFromBook',
        error: e,
        stackTrace: stackTrace,
      );
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
