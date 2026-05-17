import 'dart:typed_data';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/presentation/image_enhancer_screen.dart';
import '../../../../core/services/gemini_service.dart';
import '../../../../features/admin/data/token_usage_repository.dart';
import '../../../../features/admin/presentation/admin_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import '../source_viewer.dart';
import '../edit/ingredient_list_editor.dart';
import '../edit/recipe_form_mixin.dart';
import '../edit/recipe_meta_panel.dart';
import '../edit/recipe_cooklang_editor.dart';
import 'draft_review_service.dart';
import 'draft_review_widgets.dart';

const _geminiApiKey = String.fromEnvironment(
  'GEMINI_API_KEY',
  defaultValue: '',
);

class DraftReviewScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const DraftReviewScreen({super.key, required this.recipeId});

  @override
  ConsumerState<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends ConsumerState<DraftReviewScreen>
    with RecipeFormMixin<DraftReviewScreen> {
  bool _aiRefining = false;
  final _refineCtrl = TextEditingController();

  // Enhancer inline pour les illustrations
  Uint8List? _enhancerBytes;
  int? _enhancingIndex;
  bool _showingIllEnhancer = false;
  EnhancerMode _enhancerMode = EnhancerMode.crop;

  @override
  void dispose() {
    _refineCtrl.dispose();
    super.dispose();
  }

  /// Ouvre un dialogue pour saisir une instruction IA, puis lance le raffinement.
  Future<void> _showRefineDialog(Recipe recipe) async {
    if (_geminiApiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Clé API Gemini non configurée')),
      );
      return;
    }
    _refineCtrl.clear();
    // Checkbox état local au dialogue
    bool alsoExtract = false;
    final isSourceImage = _isImageUrl(
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
              Text('Améliorer avec l\'IA'),
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
      final bytes = await FirebaseStorage.instance
          .refFromURL(url)
          .getData(20 * 1024 * 1024);
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

  /// Supprime une illustration par son URL après confirmation.
  Future<void> _removeIllustrationByUrl(Recipe recipe, String url) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette photo ?'),
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
    if (confirmed != true || !mounted) return;
    final newUrls = List<String>.from(recipe.imageUrls)..remove(url);
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(recipe.id, newUrls);
  }

  /// Reçoit le résultat de l'enhancer, upload et met à jour Firestore.
  Future<void> _onIllustrationEnhancerResult(
    Recipe recipe,
    Uint8List? result,
  ) async {
    setState(() => _showingIllEnhancer = false);
    if (result == null || _enhancingIndex == null) return;
    final index = _enhancingIndex!;
    setState(() => _aiRefining = true);
    try {
      final uid =
          FirebaseAuth.instance.currentUser?.uid ??
          ref.read(appUserProvider).value?.uid ??
          '';
      final ts = DateTime.now().millisecondsSinceEpoch;
      final snap = await FirebaseStorage.instance
          .ref('illustrations/$uid/${ts}_enhanced.jpg')
          .putData(result, SettableMetadata(contentType: 'image/jpeg'));
      final newUrl = await snap.ref.getDownloadURL();
      final newUrls = List<String>.from(recipe.imageUrls);
      if (index < newUrls.length) newUrls[index] = newUrl;
      await ref
          .read(recipeRepositoryProvider)
          .updateRecipeIllustrations(recipe.id, newUrls);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Photo améliorée ✓'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _aiRefining = false);
    }
  }

  /// Retourne true si l'URL/nom de fichier correspond à une image JPEG ou PNG.
  bool _isImageUrl(String? url, String? fileName) {
    final lower = (fileName ?? url ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  /// Télécharge le scan source, détecte et extrait les régions culinaires
  /// via Gemini, puis met à jour les illustrations de la recette.
  Future<void> _doExtractIllustrations(Recipe recipe) async {
    final url = recipe.sourceFileUrl;
    if (url == null || url.isEmpty) return;
    if (!_isImageUrl(url, recipe.sourceFileName)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Extraction disponible uniquement pour les images JPEG/PNG',
            ),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    setState(() => _aiRefining = true);
    try {
      final uid =
          FirebaseAuth.instance.currentUser?.uid ??
          ref.read(appUserProvider).value?.uid ??
          '';
      final gemini = GeminiService(
        _geminiApiKey,
        onTokenUsage: TokenUsageRepository.makeCallback(
          uid,
          ref.read(tokenUsageRepositoryProvider),
        ),
      );
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${result.urls.length} illustration(s) extraite(s) ✓',
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Aucune illustration trouvée dans le scan'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur extraction : $e')));
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
      final uid =
          FirebaseAuth.instance.currentUser?.uid ??
          ref.read(appUserProvider).value?.uid ??
          '';
      final gemini = GeminiService(
        _geminiApiKey,
        onTokenUsage: TokenUsageRepository.makeCallback(
          uid,
          ref.read(tokenUsageRepositoryProvider),
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recette améliorée par l\'IA ✓'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur IA : $e')));
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
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Recette introuvable')),
          );
        }
        initFormFromRecipe(recipe, useDraft: true);

        final myUid = ref.watch(appUserProvider).value?.uid ?? '';
        final isOwner = recipe.createdBy == myUid;
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
                  tooltip: 'Améliorer avec l\'IA',
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
                ? _buildWide(recipe, isOwner: isOwner)
                : _buildNarrow(recipe, isOwner: isOwner),
          ),
        );

        if (_showingIllEnhancer && _enhancerBytes != null) {
          return Stack(
            children: [
              scaffold,
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
        }
        return scaffold;
      },
    );
  }

  String _pageTypeLabel(PageType t) => switch (t) {
    PageType.technique => 'Technique culinaire',
    PageType.equipment => 'Matériel & ustensiles',
    PageType.ingredientNote => 'Note sur les ingrédients',
    PageType.other => 'Page de livre',
    _ => 'Page de livre',
  };

  Widget _buildWide(Recipe recipe, {required bool isOwner}) {
    // Page non-recette : vue simplifiée
    if (recipe.pageType != PageType.recipe) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: RecipeMetaPanel(
                titleCtrl: titleCtrl,
                portionsCtrl: portionsCtrl,
                difficultyCtrl: difficultyCtrl,
                prepTimeCtrl: prepTimeCtrl,
                cookTimeCtrl: cookTimeCtrl,
                pageNumberCtrl: pageNumberCtrl,
                saving: saving,
                selectedBookId: selectedBookId,
                onBookChanged: setBook,
                recipe: recipe,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    tabs: [
                      Tab(text: 'Contenu'),
                      Tab(text: 'Photos'),
                    ],
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        SingleChildScrollView(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Chip(
                                label: Text(_pageTypeLabel(recipe.pageType)),
                                visualDensity: VisualDensity.compact,
                              ),
                              const SizedBox(height: 16),
                              SelectableText(
                                cooklangCtrl.text,
                                style: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.copyWith(height: 1.6),
                              ),
                            ],
                          ),
                        ),
                        DraftIllustrationsTab(
                          recipe: recipe,
                          isOwner: isOwner,
                          aiRefining: _aiRefining,
                          saving: saving,
                          onExtract: () => _doExtractIllustrations(recipe),
                          onCrop: isOwner
                              ? (i) => _startEnhanceIllustration(
                                  recipe,
                                  i,
                                  EnhancerMode.crop,
                                )
                              : null,
                          onColor: isOwner
                              ? (i) => _startEnhanceIllustration(
                                  recipe,
                                  i,
                                  EnhancerMode.color,
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: RecipeMetaPanel(
              titleCtrl: titleCtrl,
              portionsCtrl: portionsCtrl,
              difficultyCtrl: difficultyCtrl,
              prepTimeCtrl: prepTimeCtrl,
              cookTimeCtrl: cookTimeCtrl,
              pageNumberCtrl: pageNumberCtrl,
              saving: saving,
              selectedBookId: selectedBookId,
              onBookChanged: setBook,
              recipe: recipe,
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: DefaultTabController(
            length: 4,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'CookLang'),
                    Tab(text: 'Aperçu'),
                    Tab(text: 'Ingrédients'),
                    Tab(text: 'Photos'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      RecipeCooklangEditor(
                        ctrl: cooklangCtrl,
                        enabled: !saving && !_aiRefining,
                        showHelp: true,
                        onProcessWithAI: () => _showRefineDialog(recipe),
                        aiProcessing: _aiRefining,
                      ),
                      CooklangPreview(
                        ctrl: cooklangCtrl,
                        overrideIngredients: formIngredients,
                        illustrationUrls: recipe.imageUrls.isNotEmpty
                            ? recipe.imageUrls
                            : null,
                        onDeleteIllustration: isOwner
                            ? (url) => _removeIllustrationByUrl(recipe, url)
                            : null,
                      ),
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: IngredientListEditor(
                          initialIngredients: formIngredients,
                          enabled: !saving,
                          onChanged: setIngredients,
                        ),
                      ),
                      DraftIllustrationsTab(
                        recipe: recipe,
                        isOwner: isOwner,
                        aiRefining: _aiRefining,
                        saving: saving,
                        onExtract: () => _doExtractIllustrations(recipe),
                        onCrop: isOwner
                            ? (i) => _startEnhanceIllustration(
                                recipe,
                                i,
                                EnhancerMode.crop,
                              )
                            : null,
                        onColor: isOwner
                            ? (i) => _startEnhanceIllustration(
                                recipe,
                                i,
                                EnhancerMode.color,
                              )
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildNarrow(Recipe recipe, {required bool isOwner}) {
    final hasSource =
        recipe.sourceFileUrl != null && recipe.sourceFileUrl!.isNotEmpty;

    // Page non-recette : vue simplifiée (Informations / Contenu / Photos / Original)
    if (recipe.pageType != PageType.recipe) {
      return DefaultTabController(
        length: hasSource ? 4 : 3,
        child: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                const Tab(text: 'Informations'),
                const Tab(text: 'Contenu'),
                const Tab(text: 'Photos'),
                if (hasSource) const Tab(text: 'Original'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 16),
                    child: RecipeMetaPanel(
                      titleCtrl: titleCtrl,
                      portionsCtrl: portionsCtrl,
                      difficultyCtrl: difficultyCtrl,
                      prepTimeCtrl: prepTimeCtrl,
                      cookTimeCtrl: cookTimeCtrl,
                      pageNumberCtrl: pageNumberCtrl,
                      saving: saving,
                      selectedBookId: selectedBookId,
                      onBookChanged: setBook,
                      recipe: recipe,
                    ),
                  ),
                  SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Chip(
                          label: Text(_pageTypeLabel(recipe.pageType)),
                          visualDensity: VisualDensity.compact,
                        ),
                        const SizedBox(height: 16),
                        SelectableText(
                          cooklangCtrl.text,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(height: 1.6),
                        ),
                      ],
                    ),
                  ),
                  DraftIllustrationsTab(
                    recipe: recipe,
                    isOwner: isOwner,
                    aiRefining: _aiRefining,
                    saving: saving,
                    onExtract: () => _doExtractIllustrations(recipe),
                    onCrop: isOwner
                        ? (i) => _startEnhanceIllustration(
                            recipe,
                            i,
                            EnhancerMode.crop,
                          )
                        : null,
                    onColor: isOwner
                        ? (i) => _startEnhanceIllustration(
                            recipe,
                            i,
                            EnhancerMode.color,
                          )
                        : null,
                  ),
                  if (hasSource)
                    DraftSourcePreviewPanel(
                      sourceFileUrl: recipe.sourceFileUrl,
                      sourceFileName: recipe.sourceFileName,
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return DefaultTabController(
      length: hasSource ? 6 : 5,
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              const Tab(text: 'Informations'),
              const Tab(text: 'CookLang'),
              const Tab(text: 'Aperçu'),
              const Tab(text: 'Ingrédients'),
              const Tab(text: 'Photos'),
              if (hasSource) const Tab(text: 'Original'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 16),
                  child: RecipeMetaPanel(
                    titleCtrl: titleCtrl,
                    portionsCtrl: portionsCtrl,
                    difficultyCtrl: difficultyCtrl,
                    prepTimeCtrl: prepTimeCtrl,
                    cookTimeCtrl: cookTimeCtrl,
                    pageNumberCtrl: pageNumberCtrl,
                    saving: saving,
                    selectedBookId: selectedBookId,
                    onBookChanged: setBook,
                    recipe: recipe,
                  ),
                ),
                RecipeCooklangEditor(
                  ctrl: cooklangCtrl,
                  enabled: !saving && !_aiRefining,
                  showHelp: true,
                  onProcessWithAI: () => _showRefineDialog(recipe),
                  aiProcessing: _aiRefining,
                ),
                CooklangPreview(
                  ctrl: cooklangCtrl,
                  overrideIngredients: formIngredients,
                  illustrationUrls: recipe.imageUrls.isNotEmpty
                      ? recipe.imageUrls
                      : null,
                  onDeleteIllustration: isOwner
                      ? (url) => _removeIllustrationByUrl(recipe, url)
                      : null,
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !saving,
                    onChanged: setIngredients,
                  ),
                ),
                DraftIllustrationsTab(
                  recipe: recipe,
                  isOwner: isOwner,
                  aiRefining: _aiRefining,
                  saving: saving,
                  onExtract: () => _doExtractIllustrations(recipe),
                  onCrop: isOwner
                      ? (i) => _startEnhanceIllustration(
                          recipe,
                          i,
                          EnhancerMode.crop,
                        )
                      : null,
                  onColor: isOwner
                      ? (i) => _startEnhanceIllustration(
                          recipe,
                          i,
                          EnhancerMode.color,
                        )
                      : null,
                ),
                if (hasSource)
                  DraftSourcePreviewPanel(
                    sourceFileUrl: recipe.sourceFileUrl,
                    sourceFileName: recipe.sourceFileName,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _validate(Recipe recipe) async {
    if (cooklangCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Le contenu est vide')));
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
              cuisines: recipe.tags.cuisines,
              occasions: recipe.tags.occasions,
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Recette validée !'),
            duration: Duration(seconds: 2),
          ),
        );
        context.go('/recipes/${recipe.id}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
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
      await ref.read(recipeRepositoryProvider).deleteRecipe(recipe.id);
      if (mounted) context.go('/drafts');
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Scan source supprimé.'),
        action: SnackBarAction(
          label: 'Nouveau scan',
          onPressed: () => context.push('/scan'),
        ),
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
