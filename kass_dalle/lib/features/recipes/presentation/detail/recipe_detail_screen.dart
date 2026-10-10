import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../core/services/cooklang_parser.dart';
import '../../../../core/services/recipe_pdf_export.dart';
import '../../../../core/services/screen_wakelock.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../planning/domain/meal_prep_context.dart';
import '../../../../core/services/nutrition_units_reference.dart';
import '../../domain/nutrition_contributions.dart';
import '../../domain/recipe.dart';
import '../../domain/storage_text.dart';
import '../recipe_providers.dart';
import 'book_reader_navigation.dart';
import '../ai/ai_ui_copy.dart';
import 'tabs/community_tab.dart';
import 'tabs/dressing_tab.dart';
import 'tabs/mobile_unified_body.dart';
import 'tabs/nutrition_tab.dart';
import 'tabs/photos_tab.dart';
import 'tabs/prepare_tab.dart';
import 'recipe_detail_annotations.dart';
import 'recipe_detail_app_bar.dart';
import 'recipe_text_zoom.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/widgets/app_network_image.dart';

class RecipeDetailScreen extends ConsumerStatefulWidget {
  final String recipeId;
  final bool scrollToAnnotations;
  final BookReadingContext readingContext;

  /// Portions imposées par le contexte d'ouverture — un repas planifié pour 8
  /// parts affiche la recette pour 8.
  ///
  /// Une valeur dérivée, jamais écrite : ni sur la recette, ni sur les
  /// préférences de portions de l'utilisateur, qui restent celles qu'il a
  /// choisies pour ses propres lectures.
  final int? initialPortions;

  /// Repas planifié dont la préparation précède le service, quand la recette
  /// est ouverte depuis le planning.
  ///
  /// Non nul, la fiche s'ouvre sur un bandeau de conservation et de
  /// réchauffage : cuisiner dimanche pour lundi n'est pas cuisiner pour le soir
  /// même. Contexte de lecture, jamais écrit sur la recette partagée.
  final MealPrepContext? prepContext;

  const RecipeDetailScreen({
    super.key,
    required this.recipeId,
    this.scrollToAnnotations = false,
    this.readingContext = const BookReadingContext(),
    this.initialPortions,
    this.prepContext,
  });

  @override
  ConsumerState<RecipeDetailScreen> createState() => _RecipeDetailScreenState();
}

class _RecipeDetailScreenState extends ConsumerState<RecipeDetailScreen>
    with SingleTickerProviderStateMixin, KeepScreenAwake {
  final _annotationsKey = GlobalKey();
  final _prefetchedRecipeIds = <String>{};
  final _prefetchedPageIds = <String>{};
  final _strippedStorageIds = <String>{};
  bool _uploadingFreeCover = false;
  bool _redirected = false;
  bool _isMobileLayout = false;
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
      length: 5,
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
    _tabController.animateTo(3);
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
              title: const Text('Communauté'),
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

  /// Retire la section de conservation héritée du texte de la recette.
  ///
  /// Le conseil a été un temps recopié en fin de recette, où il faisait doublon
  /// avec le bandeau et où le rendu numérotait son titre comme une étape de
  /// préparation. Plus rien ne l'écrit ; les recettes qui la portent encore se
  /// nettoient à leur première ouverture par quelqu'un qui a le droit de les
  /// modifier. Un lecteur ne tente rien : il n'a pas ce droit, et l'échec
  /// n'apprendrait rien.
  void _stripLegacyStorageSection(Recipe recipe, {required bool canEdit}) {
    if (!canEdit || _strippedStorageIds.contains(recipe.id)) return;
    if (!hasStorageSection(recipe.rawCooklang)) return;
    _strippedStorageIds.add(recipe.id);
    unawaited(
      ref
          .read(storageRepositoryProvider)
          .stripSection(recipeId: recipe.id, rawCooklang: recipe.rawCooklang)
          .catchError((Object error, StackTrace stackTrace) {
            reportUnexpectedError(
              feature: 'recipeDetailScreen.stripLegacyStorageSection',
              error: error,
              stackTrace: stackTrace,
            );
            // Nettoyage best-effort : la recette reste lisible avec sa section.
            return false;
          }),
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
          ref.read(userProfileProvider(uid)).value?.freeRecipeCoverUrl ?? '';
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
      ref.invalidate(userProfileProvider(uid));
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
    _isMobileLayout =
        MediaQuery.sizeOf(context).width <
        PlatformUtils.compactDetailBreakpoint;
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
        appBar: AppBar(),
        body: AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(recipeDetailProvider(widget.recipeId)),
        ),
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
          _selectedPortions = widget.initialPortions ?? basePortions;
          _loadedOverrideKey = null;
        }
        final uid = user?.uid;
        // Les portions imposées par le contexte l'emportent sur la préférence
        // enregistrée : ouvrir un repas planifié pour 8 ne doit pas retomber
        // sur les 4 parts choisies un autre jour pour cette même recette.
        if (uid != null &&
            _portionsRecipeId != null &&
            widget.initialPortions == null) {
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
        // Créateur ou administrateur seulement, éditeur compris : miroir de la
        // règle `recipes` de `firestore.rules`.
        final canEdit = user?.canModifyRecipe(recipe.createdBy) ?? false;
        _stripLegacyStorageSection(recipe, canEdit: canEdit);

        Future<void> onSelectedPortionsChanged(int value) async {
          if (_selectedPortions == value) return;
          setState(() => _selectedPortions = value);
          // Ouverture contextuelle : l'ajustement reste volant. L'enregistrer
          // ferait des parts d'un repas planifié la préférence permanente de
          // l'utilisateur pour cette recette.
          if (widget.initialPortions != null) return;
          if (uid == null || _portionsRecipeId == null) return;
          try {
            // Seule la préférence de l'utilisateur est enregistrée, sous son
            // compte. Aucun recalcul : les valeurs par portion sont une
            // division des totaux, faite à l'affichage. Le recalcul déclenché
            // ici écrivait le choix d'un lecteur sur la recette partagée — et
            // payait un appel serveur à chaque coup de curseur.
            await ref
                .read(recipeRepositoryProvider)
                .savePortionsOverride(
                  uid: uid,
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
            context.showErrorSnackBar('Erreur enregistrement portions : $e');
          }
        }

        return Scaffold(
          appBar: RecipeDetailAppBar(
            hauteur: RecipeDetailAppBar.hauteurPour(context),
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
            child: _isMobileLayout
                ? MobileUnifiedBody(
                    recipeId: recipeId,
                    ctrl: ctrl,
                    recipe: recipe,
                    canEdit: canEdit,
                    basePortions: _basePortions,
                    selectedPortions: _selectedPortions,
                    onSelectedPortionsChanged: (value) {
                      unawaited(onSelectedPortionsChanged(value));
                    },
                    onOpenCommunity: _openCommunitySheet,
                    prepContext: widget.prepContext,
                  )
                : Column(
                    children: [
                      Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: TabBar(
                          controller: _tabController,
                          tabs: const [
                            Tab(
                              icon: Icon(Icons.restaurant_menu_outlined),
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
                              text: 'Communauté',
                            ),
                            Tab(
                              icon: Icon(Icons.photo_library_outlined),
                              text: 'Photos',
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            // Seul cet onglet se zoome : c'est lui qu'on lit
                            // à un mètre, les mains dans la pâte. Les autres
                            // se consultent, tablette en main.
                            RecipeTextZoomArea(
                              child: PrepareTab(
                                recipeId: recipeId,
                                ctrl: ctrl,
                                recipe: recipe,
                                canEdit: canEdit,
                                basePortions: _basePortions,
                                selectedPortions: _selectedPortions,
                                onSelectedPortionsChanged: (value) {
                                  unawaited(onSelectedPortionsChanged(value));
                                },
                                prepContext: widget.prepContext,
                              ),
                            ),
                            NutritionTab(
                              recipeId: recipeId,
                              recipe: recipe,
                              basePortions: _basePortions,
                              selectedPortions: _selectedPortions,
                              canRecompute: canEdit,
                            ),
                            DressingTab(recipe: recipe, canEdit: canEdit),
                            CommunityTab(
                              recipeId: recipeId,
                              annotationsKey: _annotationsKey,
                            ),
                            PhotosTab(
                              recipeId: recipeId,
                              recipe: recipe,
                              canEdit: canEdit,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          bottomNavigationBar: BookReaderBottomBar(
            position: readingPosition,
            onOpen: openReaderItem,
            showProgressChip: true,
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
    // Ce que la recette porte en plus de sa méthode : les photos, les
    // annotations des membres de la famille, et la note de celui qui imprime.
    // Les deux dernières se lisent en base — l'écran ne les a pas forcément
    // sous la main quand l'export part depuis la barre de titre.
    final List<Annotation> annotations;
    final int? userRating;
    try {
      annotations = await ref
          .read(annotationRepositoryProvider)
          .watchAnnotations(recipe.id)
          .first;
      final uid = ref.read(appUserProvider).value?.uid;
      userRating = uid == null
          ? null
          : (await ref
                    .read(recipeRatingRepositoryProvider)
                    .watch(uid, recipe.id)
                    .first)
                ?.rating;
    } catch (error, stackTrace) {
      // On n'exporte pas « ce qu'on a pu lire » : un PDF amputé de ses astuces
      // sans que rien ne le dise est pire qu'un export refusé.
      reportUnexpectedError(
        feature: 'recipeDetailScreen.exportPdf.readExtras',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipe.id},
      );
      if (!mounted) return;
      context.showErrorSnackBar(
        'Impossible de lire les annotations et la note : export annulé.',
      );
      return;
    }

    final counts = PdfExtraCounts.of(recipe, annotations);
    var choice = PdfExportChoice.rien;

    // Rien à choisir : rien à demander. Le dialogue ne sert qu'à trancher.
    if (counts.hasAny) {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final answer = await _showPdfExportDialog(
        context,
        counts: counts,
        initial: PdfExportChoice(
          images: prefs.getBool('pdf_include_images') ?? true,
          notes: prefs.getBool('pdf_include_notes') ?? true,
          tips: prefs.getBool('pdf_include_tips') ?? true,
          corrections: prefs.getBool('pdf_include_corrections') ?? true,
          nutrition: prefs.getBool('pdf_include_nutrition') ?? true,
          // Le détail par ingrédient, lui, part décoché : dix colonnes de
          // diagnostic sur une fiche de cuisine se demandent, elles ne
          // s'imposent pas.
          nutritionDetails:
              prefs.getBool('pdf_include_nutrition_details') ?? false,
        ),
      );
      if (answer == null) return;
      choice = answer;
      // Seuls les choix réellement proposés sont mémorisés : une case absente
      // de ce dialogue-ci ne doit pas écraser la préférence d'un autre export.
      if (counts.images > 0) {
        await prefs.setBool('pdf_include_images', choice.images);
      }
      if (counts.notes > 0) {
        await prefs.setBool('pdf_include_notes', choice.notes);
      }
      if (counts.tips > 0) {
        await prefs.setBool('pdf_include_tips', choice.tips);
      }
      if (counts.corrections > 0) {
        await prefs.setBool('pdf_include_corrections', choice.corrections);
      }
      if (counts.nutrition) {
        await prefs.setBool('pdf_include_nutrition', choice.nutrition);
      }
      if (counts.hasNutritionDetails) {
        await prefs.setBool(
          'pdf_include_nutrition_details',
          choice.nutritionDetails,
        );
      }
    }

    // Le détail par ingrédient se calcule avec les référentiels d'unités et
    // d'ingrédients, que le générateur de PDF ne lit pas lui-même. Cette
    // lecture n'a lieu que si l'utilisateur l'a demandée.
    final snapshot = recipe.nutrition;
    PdfNutritionBlock? nutritionBlock;
    if (snapshot != null && choice.nutrition) {
      NutritionContributionTable? contributions;
      if (choice.wantsNutritionDetails) {
        try {
          final profiles = await ref.read(
            nutritionIngredientsByIdProvider(
              nutritionProfileIdsKey(recipeNutritionProfileIds(recipe)),
            ).future,
          );
          // Le référentiel d'unités d'abord : les providers qui en dérivent
          // rendent une table vide tant qu'il n'est pas chargé, et le tableau
          // sortirait alors avec des poids de repli.
          await ref.read(nutritionUnitsProvider.future);
          contributions = buildNutritionContributions(
            recipe: recipe,
            nutritionById: profiles,
            unitOverrides: ref.read(nutritionUnitOverridesProvider),
            unitInfos: ref.read(nutritionUnitInfosProvider),
          );
        } catch (error, stackTrace) {
          reportUnexpectedError(
            feature: 'recipeDetailScreen.exportPdf.readNutrition',
            error: error,
            stackTrace: stackTrace,
            context: {'recipe_id': recipe.id},
          );
          if (!mounted) return;
          context.showErrorSnackBar(
            'Impossible de lire le détail nutritionnel : export annulé.',
          );
          return;
        }
      }
      nutritionBlock = PdfNutritionBlock(
        snapshot: snapshot,
        displayedPortions: selectedPortions,
        contributions: contributions,
      );
    }

    if (!mounted) return;
    context.showSnackBar(
      'Génération du PDF…',
      duration: const Duration(seconds: 2),
    );
    try {
      final result = await exportRecipeToPdf(
        recipe,
        includeImages: choice.images,
        annotations: annotations
            .where((a) => choice.keeps(a.type))
            .toList(growable: false),
        nutrition: nutritionBlock,
        userRating: userRating,
        basePortions: basePortions,
        selectedPortions: selectedPortions,
      );
      if (!mounted) return;
      context.showSnackBar(
        '« ${recipe.titre} » exporté en PDF',
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
        title: const Text('Améliorer cette recette avec l\'IA ?'),
        content: Text(
          'Une copie brouillon de « ${recipe.titre} » sera créée puis ouverte avec l\'outil IA de modification.',
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
        title: const Text('Détacher cette recette ?'),
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
            child: const Text('Détacher'),
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
                child: AppNetworkImage(
                  imageUrl: coverUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorWidget: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    size: AppIconSize.hero,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filled(
                tooltip: 'Fermer',
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

Future<PdfExportChoice?> _showPdfExportDialog(
  BuildContext context, {
  required PdfExtraCounts counts,
  required PdfExportChoice initial,
}) {
  var choice = initial;
  return showDialog<PdfExportChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDlgState) => AlertDialog(
        title: const Text('Export PDF'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(pdfExtrasSentence(counts)),
              const SizedBox(height: 8),
              if (counts.images > 0)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inclure les photos'),
                  value: choice.images,
                  onChanged: (v) =>
                      setDlgState(() => choice = choice.copyWith(images: v)),
                ),
              if (counts.notes > 0)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inclure les remarques'),
                  value: choice.notes,
                  onChanged: (v) =>
                      setDlgState(() => choice = choice.copyWith(notes: v)),
                ),
              if (counts.tips > 0)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inclure les astuces'),
                  value: choice.tips,
                  onChanged: (v) =>
                      setDlgState(() => choice = choice.copyWith(tips: v)),
                ),
              if (counts.corrections > 0)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inclure les corrections'),
                  value: choice.corrections,
                  onChanged: (v) => setDlgState(
                    () => choice = choice.copyWith(corrections: v),
                  ),
                ),
              if (counts.nutrition)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Inclure les valeurs nutritionnelles'),
                  subtitle: const Text(
                    'Par portion, recette entière et pour 100 g',
                  ),
                  value: choice.nutrition,
                  onChanged: (v) =>
                      setDlgState(() => choice = choice.copyWith(nutrition: v)),
                ),
              // Décroché plutôt que caché quand la synthèse est refusée : la
              // case disparaîtrait sous le doigt au moment où l'on coupe la
              // nutrition, et son réglage reste visible.
              if (counts.hasNutritionDetails)
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(left: 16),
                  title: const Text('Détail par ingrédient'),
                  subtitle: const Text(
                    'Le tableau des apports, ligne par ligne',
                  ),
                  value: choice.wantsNutritionDetails,
                  onChanged: choice.nutrition
                      ? (v) => setDlgState(
                          () => choice = choice.copyWith(nutritionDetails: v),
                        )
                      : null,
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(choice),
            child: const Text('Exporter'),
          ),
        ],
      ),
    ),
  );
}
