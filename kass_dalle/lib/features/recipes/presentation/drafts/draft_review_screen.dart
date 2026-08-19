import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/gemini_providers.dart';
import '../ai/ai_processing_overlay.dart';
import '../ai/ai_ui_copy.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../source_viewer.dart';
import '../detail/recipe_detail_illustrations.dart';
import '../edit/recipe_form_mixin.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../data/draft_review_service.dart';
import 'draft_review_body.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../../core/theme/app_icon_size.dart';

/// Actions rangées derrière le menu « ⋮ » de la barre.
///
/// Les deux sont irréversibles, et elles étaient posées en boutons nus juste à
/// gauche de « Valider ». Un pouce qui vise le bouton vert et rate d'un demi-
/// centimètre effaçait le brouillon qu'il venait de relire.
enum _DraftOverflowAction { clearSourceFile, delete }

class DraftReviewScreen extends ConsumerStatefulWidget {
  final String recipeId;
  final bool autoOpenAiRefine;

  const DraftReviewScreen({
    super.key,
    required this.recipeId,
    this.autoOpenAiRefine = false,
  });

  @override
  ConsumerState<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends ConsumerState<DraftReviewScreen>
    with RecipeFormMixin<DraftReviewScreen> {
  bool _aiRefining = false;
  bool _isDeleting = false;
  final _refineCtrl = TextEditingController();

  // Enhancer inline pour les illustrations
  Uint8List? _enhancerBytes;
  int? _enhancingIndex;
  bool _showingIllEnhancer = false;
  EnhancerMode _enhancerMode = EnhancerMode.studio;

  // Index actuellement en cours d'amélioration AI (perspective + couleurs Gemini)
  int? _enhancingAiIndex;
  bool _aiDialogAutoOpened = false;

  @override
  void dispose() {
    _refineCtrl.dispose();
    super.dispose();
  }

  /// Ouvre un dialogue pour saisir une instruction IA, puis lance le raffinement.
  Future<void> _showRefineDialog(Recipe recipe) async {
    _refineCtrl.clear();
    // Checkbox état local au dialogue
    bool alsoExtract = false;
    final isSourceImage = DraftReviewService.isImageUrl(
      recipe.sourceFileUrl,
      recipe.sourceFileName,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.auto_awesome_outlined),
              SizedBox(width: 8),
              Text(RecipeAiUiCopy.refineDialogTitle),
            ],
          ),
          content: SizedBox(
            width: MediaQuery.sizeOf(ctx).width > 720
                ? 560
                : MediaQuery.sizeOf(ctx).width * 0.9,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  RecipeAiUiCopy.refineDialogInputPrompt,
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _refineCtrl,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: recipe.pageType != PageType.recipe
                        ? 'Ex : "Mets les titres en gras, regroupe les items similaires…"'
                        : 'Ex : "Corrige les ingrédients mal balisés, ajoute des sections…"',
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  recipe.pageType != PageType.recipe
                      ? 'Si vide : correction orthographique et mise en forme Markdown.'
                      : 'Si vide : reformatage et corrections automatiques.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
                if (isSourceImage) ...[
                  const Divider(height: 20),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text(
                      'Extraire les illustrations depuis le scan',
                      style: TextStyle(fontSize: 13),
                    ),
                    subtitle: const Text(
                      'Détecte et recadre les photos culinaires de l\'image source',
                      style: TextStyle(fontSize: 11),
                    ),
                    value: alsoExtract,
                    onChanged: (v) =>
                        setDialogState(() => alsoExtract = v ?? false),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(
                Icons.auto_awesome_outlined,
                size: AppIconSize.inline,
              ),
              label: const Text(RecipeAiUiCopy.refineDialogPrimaryCta),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    if (alsoExtract) {
      await _doExtractIllustrations(recipe);
      if (!mounted) return;
    }
    await _doRefine(recipe, _refineCtrl.text.trim());
  }

  /// Télécharge une illustration et ouvre l'enhancer inline.
  Future<void> _startEnhanceIllustration(
    Recipe recipe,
    int index,
    EnhancerMode mode,
  ) async {
    final url = recipe.imageUrls[index];
    setState(() => _aiRefining = true);
    try {
      final bytes = await DraftReviewService.downloadImageBytes(url);
      if (bytes == null || !mounted) return;
      setState(() {
        _enhancerBytes = bytes;
        _enhancingIndex = index;
        _showingIllEnhancer = true;
        _enhancerMode = mode;
        _aiRefining = false;
      });
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.startEnhanceIllustration',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _aiRefining = false);
        context.showErrorSnackBar('Erreur chargement : $e');
      }
    }
  }

  /// Lance l'amélioration AI (perspective + couleurs) via Gemini Image.
  /// Réservé aux administrateurs (vérifié côté backend également).
  Future<void> _enhanceIllustrationAi(Recipe recipe, int index) async {
    if (_enhancingAiIndex != null) return;
    final url = recipe.imageUrls[index];
    setState(() => _enhancingAiIndex = index);
    try {
      final gemini = ref.read(geminiServiceProvider);
      await DraftReviewService.enhanceIllustration(
        gemini: gemini,
        recipeId: recipe.id,
        illustrationUrl: url,
      );
      if (!mounted) return;
      context.showSuccessSnackBar('Photo améliorée par l\'IA.');
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.enhanceIllustrationAi',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Échec de l\'amélioration AI : $e');
    } finally {
      if (mounted) setState(() => _enhancingAiIndex = null);
    }
  }

  /// Ouvre la visionneuse plein écran sur l'image cliquée.
  void _showIllustrationGallery(List<String> urls, int startIndex) {
    showDialog<void>(
      context: context,
      builder: (ctx) =>
          IllustrationGallery(urls: urls, initialIndex: startIndex),
    );
  }

  /// Supprime une illustration sans demander confirmation
  /// (utilisé depuis l'aperçu, où la miniature confirme déjà elle-même).
  Future<void> _deleteIllustrationDirect(Recipe recipe, String url) async {
    final index = recipe.imageUrls.indexOf(url);
    final newUrls = List<String>.from(recipe.imageUrls)..remove(url);
    final thumbs = recipe.thumbnailUrls;
    final newThumbs = (index >= 0 && index < thumbs.length)
        ? (List<String>.from(thumbs)..removeAt(index))
        : null;
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(
          recipe.id,
          newUrls,
          thumbnailUrls: newThumbs,
        );
  }

  Future<String?> _uploadImageFromGallery(
    Uint8List bytes,
    String fileName,
  ) async {
    final uid = currentUid;
    return DraftReviewService.uploadIllustration(bytes, fileName, uid);
  }

  /// Reçoit le résultat de l'enhancer, upload et met à jour Firestore.
  Future<void> _onIllustrationEnhancerResult(
    Recipe recipe,
    Uint8List? result,
  ) async {
    setState(() => _showingIllEnhancer = false);
    if (result == null) return;
    final index = _enhancingIndex; // null = ajout, int = remplacement
    setState(() => _aiRefining = true);
    try {
      final uid = currentUid;
      final newUrl = await DraftReviewService.uploadEnhancedIllustration(
        uid,
        result,
      );
      final newUrls = List<String>.from(recipe.imageUrls);
      final newThumbs = List<String>.from(recipe.thumbnailUrls);
      if (index != null && index < newUrls.length) {
        newUrls[index] = newUrl; // Remplacement
        if (index < newThumbs.length) {
          newThumbs[index] = newUrl;
        }
      } else {
        newUrls.add(newUrl); // Ajout
        newThumbs.add(newUrl);
      }
      await ref
          .read(recipeRepositoryProvider)
          .updateRecipeIllustrations(
            recipe.id,
            newUrls,
            thumbnailUrls: newThumbs.isEmpty ? null : newThumbs,
          );
      if (mounted) {
        context.showSuccessSnackBar(
          index != null ? 'Photo améliorée ✓' : 'Illustration extraite ✓',
        );
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.onIllustrationEnhancerResult',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setState(() => _aiRefining = false);
    }
  }

  /// Ouvre le scan source dans l'enhancer (mode recadrage) pour extraire
  /// manuellement une illustration qui n'aurait pas été détectée.
  Future<void> _startExtractFromOriginal(Recipe recipe) async {
    final url = recipe.sourceFileUrl;
    if (url == null || url.isEmpty) return;
    setState(() => _aiRefining = true);
    try {
      final bytes = await DraftReviewService.downloadImageBytes(url);
      if (bytes == null || !mounted) return;
      setState(() {
        _enhancerBytes = bytes;
        _enhancingIndex = null; // null = ajout d'une nouvelle illustration
        _showingIllEnhancer = true;
        _enhancerMode = EnhancerMode.studio;
        _aiRefining = false;
      });
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.startExtractFromOriginal',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() => _aiRefining = false);
        context.showSnackBar('Erreur chargement source : $e');
      }
    }
  }

  /// Télécharge le scan source, détecte et extrait les régions culinaires
  /// via Gemini, puis met à jour les illustrations de la recette.
  Future<void> _doExtractIllustrations(Recipe recipe) async {
    final url = recipe.sourceFileUrl;
    if (url == null || url.isEmpty) return;
    if (!DraftReviewService.isImageUrl(url, recipe.sourceFileName)) {
      if (mounted) {
        context.showSnackBar(
          'Extraction disponible uniquement pour les images JPEG/PNG',
        );
      }
      return;
    }
    setState(() => _aiRefining = true);
    try {
      final uid = currentUid;
      final gemini = ref.read(geminiServiceProvider);
      final result = await DraftReviewService.extractAndUploadIllustrations(
        sourceUrl: url,
        sourceFileName: recipe.sourceFileName,
        uid: uid,
        gemini: gemini,
      );
      if (!mounted) return;
      if (result.urls.isNotEmpty) {
        await ref
            .read(recipeRepositoryProvider)
            .updateRecipeIllustrations(recipe.id, result.urls);
        if (mounted) {
          context.showSuccessSnackBar(
            '${result.urls.length} illustration(s) extraite(s) ✓',
          );
        }
      } else {
        if (mounted) {
          context.showSuccessSnackBar(
            'Aucune illustration trouvée dans le scan',
          );
        }
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.doExtractIllustrations',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Erreur extraction : $e');
      }
    } finally {
      if (mounted) setState(() => _aiRefining = false);
    }
  }

  Future<void> _doRefine(Recipe recipe, String customInstruction) async {
    setState(() => _aiRefining = true);
    try {
      final gemini = ref.read(geminiServiceProvider);

      if (recipe.pageType != PageType.recipe) {
        // Document non-recette : polish Markdown (orthographe + mise en forme, pas de CookLang)
        final polished = await DraftReviewService.polishMarkdownContent(
          gemini: gemini,
          markdown: cooklangCtrl.text,
          instruction: customInstruction.isNotEmpty ? customInstruction : null,
        );
        if (!mounted) return;
        if (polished != null) cooklangCtrl.text = polished;
        if (mounted) {
          context.showSuccessSnackBar('Document mis en forme par l\'IA ✓');
        }
      } else {
        // Recette : raffinement CookLang
        final instruction = customInstruction.isNotEmpty
            ? customInstruction
            : 'Reformate et améliore la mise en forme CookLang de cette recette : '
                  'assure-toi que tous les ingrédients sont bien balisés avec @, '
                  'que les timers sont au bon format ~{qty%unit}, '
                  'et que les sections sont bien organisées.';
        final result = await DraftReviewService.refineRecipe(
          gemini: gemini,
          currentTitre: titleCtrl.text.trim().isEmpty
              ? recipe.titre
              : titleCtrl.text.trim(),
          currentCooklang: cooklangCtrl.text,
          formIngredients: formIngredients,
          currentTags: recipe.tags,
          currentPortions:
              int.tryParse(portionsCtrl.text.trim()) ?? recipe.portions,
          instruction: instruction,
        );
        if (!mounted) return;
        if (result.cooklang != null) cooklangCtrl.text = result.cooklang!;
        if (result.titre != null) titleCtrl.text = result.titre!;
        if (result.ingredients != null) setIngredients(result.ingredients!);
        if (mounted) {
          context.showSuccessSnackBar(RecipeAiUiCopy.successRecipeRefined);
          final why = result.justification;
          if (why != null && why.isNotEmpty) {
            await showDialog<void>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Explication de l\'IA'),
                content: Text(why),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
            );
          }
        }
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.doRefine',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Erreur IA : $e');
      }
    } finally {
      if (mounted) setState(() => _aiRefining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recipeAsync = ref.watch(recipeDetailProvider(widget.recipeId));
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return recipeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(recipeDetailProvider(widget.recipeId)),
        ),
      ),
      data: (recipe) {
        if (recipe == null) {
          if (_isDeleting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Recette introuvable')),
          );
        }
        initFormFromRecipe(recipe, useDraft: true);

        final myUid = ref.watch(appUserProvider).value?.uid ?? '';
        final isOwner = recipe.createdBy == myUid;
        final isAdmin = ref.watch(isAdminProvider);
        final ownerName = !isOwner
            ? ref.watch(userByUidProvider(recipe.createdBy)).value?.displayName
            : null;

        if (widget.autoOpenAiRefine && !_aiDialogAutoOpened && isOwner) {
          _aiDialogAutoOpened = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _showRefineDialog(recipe);
          });
        }

        final scaffold = Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: titleCtrl,
                  builder: (context, value, _) {
                    final liveTitle = value.text.trim().isNotEmpty
                        ? value.text.trim()
                        : recipe.titre;
                    return Text(liveTitle, overflow: TextOverflow.ellipsis);
                  },
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Brouillon',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSecondaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        recipe.sourceRecipeId != null
                            ? 'Copie de travail - l\'originale reste intacte'
                            : 'Brouillon issu d\'un scan',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (recipe.bookTitre != null)
                  Text(
                    [
                      recipe.bookTitre!,
                      if (recipe.pageNumber != null)
                        'pg\u00a0${recipe.pageNumber}',
                    ].join(', '),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                if (ownerName != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.person_outline,
                        size: AppIconSize.badge,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        ownerName,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
              ],
            ),
            actions: [
              SourceViewerButton(
                sourceFileUrl: recipe.sourceFileUrl,
                sourceFileName: recipe.sourceFileName,
                additionalSourceFileUrls: recipe.additionalSourceFileUrls,
              ),
              if (isOwner) ...[
                IconButton(
                  icon: _aiRefining
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome_outlined),
                  tooltip: RecipeAiUiCopy.appBarActionTooltip,
                  onPressed: (saving || _aiRefining)
                      ? null
                      : () => _showRefineDialog(recipe),
                ),
                FilledButton.icon(
                  onPressed: (saving || _aiRefining)
                      ? null
                      : () => _validate(recipe),
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Valider'),
                ),
                PopupMenuButton<_DraftOverflowAction>(
                  tooltip: 'Autres actions',
                  icon: const Icon(Icons.more_vert),
                  enabled: !saving,
                  onSelected: (action) => switch (action) {
                    _DraftOverflowAction.clearSourceFile => _clearSourceFile(
                      recipe,
                    ),
                    _DraftOverflowAction.delete => _confirmDelete(recipe),
                  },
                  itemBuilder: (ctx) => [
                    if ((recipe.sourceFileUrl ?? '').isNotEmpty)
                      const PopupMenuItem(
                        value: _DraftOverflowAction.clearSourceFile,
                        child: ListTile(
                          // Pas le maillon brisé : il dit « détacher du livre »
                          // partout ailleurs dans l'application. Ici on efface
                          // un fichier, ce n'est pas le même geste.
                          leading: Icon(Icons.folder_delete_outlined),
                          title: Text('Supprimer le scan source'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    PopupMenuItem(
                      value: _DraftOverflowAction.delete,
                      child: ListTile(
                        leading: Icon(
                          Icons.delete_outline,
                          color: Theme.of(ctx).colorScheme.error,
                        ),
                        title: Text(
                          'Supprimer le brouillon',
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.error,
                          ),
                        ),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
              ] else
                IconButton(
                  icon: const Icon(Icons.copy_outlined),
                  tooltip: 'Copier comme mon brouillon',
                  onPressed: saving ? null : () => _copyAsDraft(recipe, myUid),
                ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: isWide
                ? DraftReviewWideBody(
                    recipe: recipe,
                    isOwner: isOwner,
                    isAdmin: isAdmin,
                    data: _formData(recipe),
                  )
                : DraftReviewNarrowBody(
                    recipe: recipe,
                    isOwner: isOwner,
                    isAdmin: isAdmin,
                    data: _formData(recipe),
                  ),
          ),
        );

        // Toujours retourner un Stack pour préserver le DefaultTabController
        // (et donc l'onglet actif) quand l'enhancer s'ouvre/se ferme.
        return Stack(
          children: [
            scaffold,
            if (_aiRefining)
              const AiProcessingOverlay(
                title: RecipeAiUiCopy.processingTitle,
                message: RecipeAiUiCopy.processingMessage,
              ),
            if (_showingIllEnhancer && _enhancerBytes != null)
              Positioned.fill(
                child: ImageEnhancerScreen(
                  imageBytes: _enhancerBytes!,
                  title: _enhancerMode == EnhancerMode.studio
                      ? 'Atelier de retouche'
                      : _enhancerMode == EnhancerMode.crop
                      ? 'Recadrer la photo'
                      : 'Améliorer les couleurs',
                  mode: _enhancerMode,
                  onResult: (result) =>
                      _onIllustrationEnhancerResult(recipe, result),
                ),
              ),
          ],
        );
      },
    );
  }

  /// Change le type de page et met à jour Firestore immédiatement.
  Future<void> _changePageType(Recipe recipe, PageType newType) async {
    try {
      await ref
          .read(recipeRepositoryProvider)
          .updatePageType(recipe.id, newType);
      // Le stream Firestore va déclencher un rebuild avec le nouveau type.
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.changePageType',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showSnackBar('Erreur : $e');
    }
  }

  DraftReviewFormData _formData(Recipe recipe) => DraftReviewFormData(
    titleCtrl: titleCtrl,
    portionsCtrl: portionsCtrl,
    difficultyCtrl: difficultyCtrl,
    prepTimeCtrl: prepTimeCtrl,
    cookTimeCtrl: cookTimeCtrl,
    pageNumberCtrl: pageNumberCtrl,
    cooklangCtrl: cooklangCtrl,
    saving: saving,
    aiRefining: _aiRefining,
    enhancingAiIndex: _enhancingAiIndex,
    selectedBookId: selectedBookId,
    selectedCuisines: selectedCuisines,
    selectedDishTypes: selectedDishTypes,
    suggestingTags: suggestingTags,
    formIngredients: formIngredients,
    onBookChanged: setBook,
    onCuisinesChanged: setCuisines,
    onDishTypesChanged: setDishTypes,
    onIngredientsChanged: setIngredients,
    onUploadImage: _uploadImageFromGallery,
    onExtractIllustrations: () => _doExtractIllustrations(recipe),
    onExtractFromOriginal: () => _startExtractFromOriginal(recipe),
    onEnhanceIllustration: (i, mode) =>
        _startEnhanceIllustration(recipe, i, mode),
    onEnhanceAi: (i) => _enhanceIllustrationAi(recipe, i),
    onShowRefineDialog: () => _showRefineDialog(recipe),
    onShowGallery: _showIllustrationGallery,
    onDeleteIllustration: (url) => _deleteIllustrationDirect(recipe, url),
    pageType: recipe.pageType,
    onPageTypeChanged: (newType) => _changePageType(recipe, newType),
  );

  Future<void> _validate(Recipe recipe) async {
    if (cooklangCtrl.text.trim().isEmpty) {
      context.showSnackBar('Le contenu est vide');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Valider ce brouillon ?'),
        content: Text(
          recipe.sourceRecipeId != null
              ? 'Vous validez cette copie de travail. La recette originale ne sera pas ecrasee.'
              : 'Vous validez ce brouillon. La recette sera ajoutée à votre bibliothèque.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setSaving(true);
    final syncedCooklang = syncAllMetaFields(cooklangCtrl.text.trim());
    final myUid = ref.read(appUserProvider).value?.uid ?? '';
    try {
      await ref
          .read(recipeRepositoryProvider)
          .validateDraft(
            recipeId: recipe.id,
            editedCooklang: syncedCooklang,
            titre: titleCtrl.text.trim().isEmpty
                ? recipe.titre
                : titleCtrl.text.trim(),
            callerUid: myUid,
            bookId: selectedBookId,
            bookTitre: selectedBookTitre,
            pageNumberOverride: int.tryParse(pageNumberCtrl.text.trim()),
            portionsOverride: int.tryParse(portionsCtrl.text.trim()),
            tagsOverride: RecipeTags(
              themes: recipe.tags.themes,
              cuisines: selectedCuisines,
              occasions: recipe.tags.occasions,
              dishTypes: selectedDishTypes,
              difficulty: difficultyCtrl.text.trim().isEmpty
                  ? null
                  : difficultyCtrl.text.trim(),
              prepTime: int.tryParse(prepTimeCtrl.text.trim()),
              cookTime: int.tryParse(cookTimeCtrl.text.trim()),
            ),
            ingredientsOverride: formIngredients,
            onNormalizationApplied:
                ({
                  required normalizedCooklang,
                  required normalizedIngredients,
                  required renamedUnits,
                  required renamedIngredients,
                }) {
                  cooklangCtrl.text = normalizedCooklang;
                  setIngredients(normalizedIngredients);
                  if (renamedUnits > 0 || renamedIngredients > 0) {
                    context.showSuccessSnackBar(
                      'Normalisation appliquée : '
                      '$renamedIngredients ingrédient(s), $renamedUnits unité(s).',
                    );
                  }
                },
          );
      if (mounted) {
        ref.invalidate(recipeDetailProvider(recipe.id));
        context.showSuccessSnackBar('Recette validée !');
        context.go('/recipes/${recipe.id}');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.validate',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setSaving(false);
    }
  }

  Future<void> _confirmDelete(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('Supprimer ce brouillon ?'),
        content: Text(
          '\u00ab\u00a0${recipe.titre}\u00a0\u00bb sera définitivement supprimé.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dlgCtx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _isDeleting = true);
      try {
        await ref.read(recipeRepositoryProvider).deleteRecipe(recipe.id);
        if (mounted) context.go('/drafts');
      } catch (e, st) {
        reportUnexpectedError(
          feature: 'draftReviewScreen.confirmDelete',
          error: e,
          stackTrace: st,
        );
        debugPrint('deleteRecipe failed: $e\n$st');
        if (mounted) {
          setState(() => _isDeleting = false);
          context.showErrorSnackBar('Échec de la suppression : $e');
        }
      }
    }
  }

  Future<void> _clearSourceFile(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer le scan source ?'),
        content: const Text(
          'Le fichier source sera dissocié de ce brouillon. '
          'Vous pourrez ensuite importer un nouveau scan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(recipeRepositoryProvider).clearSourceFile(recipe.id);
    if (!mounted) return;
    context.showSnackBar(
      'Scan source supprimé.',
      action: SnackBarAction(
        label: 'Nouveau scan',
        onPressed: () => context.push('/scan'),
      ),
    );
  }

  Future<void> _copyAsDraft(Recipe recipe, String myUid) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Copier ce brouillon ?'),
        content: Text(
          'Une copie de « ${recipe.titre} » sera créée dans vos brouillons.',
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
    if (confirmed != true || !mounted) return;
    try {
      final newId = await ref
          .read(recipeRepositoryProvider)
          .copyRecipeAsDraft(recipe: recipe, newOwnerUid: myUid);
      if (!mounted) return;
      context.go('/drafts/$newId');
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'draftReviewScreen.copyAsDraft',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Erreur : $e');
    }
  }
}
