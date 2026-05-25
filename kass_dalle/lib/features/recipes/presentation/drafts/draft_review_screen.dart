import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/gemini_providers.dart';
import '../../../../features/admin/presentation/admin_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import '../source_viewer.dart';
import '../detail/recipe_detail_illustrations.dart';
import '../edit/ingredient_list_editor.dart';
import '../edit/recipe_form_mixin.dart';
import '../edit/recipe_meta_panel.dart';
import '../editor/hybrid_recipe_editor.dart';
import '../editor/markdown_editor.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../data/draft_review_service.dart';
import 'draft_review_body.dart';
import 'draft_review_widgets.dart';

class DraftReviewScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const DraftReviewScreen({super.key, required this.recipeId});

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
  EnhancerMode _enhancerMode = EnhancerMode.crop;

  // Index actuellement en cours d'amélioration AI (perspective + couleurs Gemini)
  int? _enhancingAiIndex;

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
              Icon(Icons.auto_awesome),
              SizedBox(width: 8),
              Text('Améliorer la mise en forme avec l\'IA'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Décrivez ce que vous voulez améliorer (optionnel) :',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _refineCtrl,
                autofocus: true,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText:
                      'Ex : "Corrige les ingrédients mal balisés, ajoute des sections…"',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Si vide : reformatage et corrections automatiques.',
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
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Annuler'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text('Améliorer'),
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
    } catch (e) {
      if (mounted) {
        setState(() => _aiRefining = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur chargement : $e')));
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
      // ignore: avoid_print
      print('[enhanceAI] error: $e\n$st');
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
    final newUrls = List<String>.from(recipe.imageUrls)..remove(url);
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(recipe.id, newUrls);
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
      if (index != null && index < newUrls.length) {
        newUrls[index] = newUrl; // Remplacement
      } else {
        newUrls.add(newUrl); // Ajout
      }
      await ref
          .read(recipeRepositoryProvider)
          .updateRecipeIllustrations(recipe.id, newUrls);
      if (mounted) {
        context.showSuccessSnackBar(
          index != null ? 'Photo améliorée ✓' : 'Illustration extraite ✓',
        );
      }
    } catch (e) {
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
        _enhancerMode = EnhancerMode.crop;
        _aiRefining = false;
      });
    } catch (e) {
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
    } catch (e) {
      if (mounted) {
        context.showSnackBar('Erreur extraction : $e');
      }
    } finally {
      if (mounted) setState(() => _aiRefining = false);
    }
  }

  Future<void> _doRefine(Recipe recipe, String customInstruction) async {
    final instruction = customInstruction.isNotEmpty
        ? customInstruction
        : 'Reformate et améliore la mise en forme CookLang de cette recette : '
              'assure-toi que tous les ingrédients sont bien balisés avec @, '
              'que les timers sont au bon format ~{qty%unit}, '
              'et que les sections sont bien organisées.';
    setState(() => _aiRefining = true);
    try {
      final gemini = ref.read(geminiServiceProvider);
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
        context.showSuccessSnackBar('Recette améliorée par l\'IA ✓');
      }
    } catch (e) {
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
    final isWide = MediaQuery.of(context).size.width >= 800;

    return recipeAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Erreur')),
        body: Center(child: Text('$e')),
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

        final scaffold = Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(recipe.titre, overflow: TextOverflow.ellipsis),
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
                        size: 11,
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
              if (isOwner && (recipe.sourceFileUrl ?? '').isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.link_off),
                  tooltip: 'Supprimer le scan source',
                  onPressed: saving ? null : () => _clearSourceFile(recipe),
                ),
              if (isOwner) ...[
                IconButton(
                  icon: _aiRefining
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome),
                  tooltip: 'Améliorer la mise en forme avec l\'IA',
                  onPressed: (saving || _aiRefining)
                      ? null
                      : () => _showRefineDialog(recipe),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Supprimer',
                  onPressed: saving ? null : () => _confirmDelete(recipe),
                ),
                FilledButton.icon(
                  onPressed: saving ? null : () => _validate(recipe),
                  icon: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: const Text('Valider'),
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
            if (_showingIllEnhancer && _enhancerBytes != null)
              Positioned.fill(
                child: ImageEnhancerScreen(
                  imageBytes: _enhancerBytes!,
                  title: _enhancerMode == EnhancerMode.crop
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
  );

  Future<void> _validate(Recipe recipe) async {
    if (cooklangCtrl.text.trim().isEmpty) {
      context.showSnackBar('Le contenu est vide');
      return;
    }
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
          );
      if (mounted) {
        ref.invalidate(recipeDetailProvider(recipe.id));
        context.showSuccessSnackBar('Recette validée !');
        context.go('/recipes/${recipe.id}');
      }
    } catch (e) {
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
      builder: (_) => AlertDialog(
        title: const Text('Supprimer ce brouillon ?'),
        content: Text(
          '\u00ab\u00a0${recipe.titre}\u00a0\u00bb sera définitivement supprimé.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
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
        debugPrint('deleteRecipe failed: $e\n$st');
        if (mounted) {
          setState(() => _isDeleting = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Échec de la suppression : $e')),
          );
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
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
    }
  }
}
