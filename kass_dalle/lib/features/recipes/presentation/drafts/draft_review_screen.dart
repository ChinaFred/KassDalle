import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
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

        return Scaffold(
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
                        _IllustrationsTab(
                          recipe: recipe,
                          isOwner: isOwner,
                          aiRefining: _aiRefining,
                          saving: saving,
                          onExtract: () => _doExtractIllustrations(recipe),
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
                      ),
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: IngredientListEditor(
                          initialIngredients: formIngredients,
                          enabled: !saving,
                          onChanged: setIngredients,
                        ),
                      ),
                      _IllustrationsTab(
                        recipe: recipe,
                        isOwner: isOwner,
                        aiRefining: _aiRefining,
                        saving: saving,
                        onExtract: () => _doExtractIllustrations(recipe),
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
                  _IllustrationsTab(
                    recipe: recipe,
                    isOwner: isOwner,
                    aiRefining: _aiRefining,
                    saving: saving,
                    onExtract: () => _doExtractIllustrations(recipe),
                  ),
                  if (hasSource)
                    _SourcePreviewPanel(
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
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !saving,
                    onChanged: setIngredients,
                  ),
                ),
                _IllustrationsTab(
                  recipe: recipe,
                  isOwner: isOwner,
                  aiRefining: _aiRefining,
                  saving: saving,
                  onExtract: () => _doExtractIllustrations(recipe),
                ),
                if (hasSource)
                  _SourcePreviewPanel(
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

// ── Onglet illustrations ──────────────────────────────────────────────────────

class _IllustrationsTab extends ConsumerWidget {
  final Recipe recipe;
  final bool isOwner;
  final bool aiRefining;
  final bool saving;
  final VoidCallback? onExtract;

  const _IllustrationsTab({
    required this.recipe,
    required this.isOwner,
    required this.aiRefining,
    required this.saving,
    this.onExtract,
  });

  bool _isImageSource(String? url, String? fileName) {
    final lower = (fileName ?? url ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  Future<void> _removeAt(BuildContext context, WidgetRef ref, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer cette photo ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final newUrls = List<String>.from(recipe.imageUrls)..removeAt(index);
    await ref
        .read(recipeRepositoryProvider)
        .updateRecipeIllustrations(recipe.id, newUrls);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canExtract =
        isOwner &&
        onExtract != null &&
        _isImageSource(recipe.sourceFileUrl, recipe.sourceFileName);

    if (recipe.imageUrls.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.photo_library_outlined,
                size: 64,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Aucune photo détectée',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                canExtract
                    ? 'L\'IA n\'a pas encore analysé le scan, ou n\'a trouvé\naucune photo culinaire dans ce document.'
                    : 'Aucune illustration n\'a été associée à ce brouillon.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (canExtract) ...[
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: (aiRefining || saving) ? null : onExtract,
                  icon: aiRefining
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_search_outlined),
                  label: const Text('Extraire les illustrations'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Text(
                '${recipe.imageUrls.length} photo(s)',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (canExtract)
                TextButton.icon(
                  onPressed: (aiRefining || saving) ? null : onExtract,
                  icon: aiRefining
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 16),
                  label: const Text('Ré-extraire'),
                ),
            ],
          ),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 260,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 4 / 3,
            ),
            itemCount: recipe.imageUrls.length,
            itemBuilder: (ctx, i) => _IllustrationCard(
              url: recipe.imageUrls[i],
              onDelete: isOwner ? () => _removeAt(context, ref, i) : null,
            ),
          ),
        ),
      ],
    );
  }
}

class _IllustrationCard extends StatelessWidget {
  final String url;
  final VoidCallback? onDelete;

  const _IllustrationCard({required this.url, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            placeholder: (_, _) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, _, _) => Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Center(child: Icon(Icons.broken_image, size: 40)),
            ),
          ),
        ),
        if (onDelete != null)
          Positioned(
            top: 4,
            right: 4,
            child: Material(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onDelete,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Icons.close, size: 16, color: Colors.white),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Panneau d'apercu du document source ──────────────────────────────────────

class _SourcePreviewPanel extends StatelessWidget {
  final String? sourceFileUrl;
  final String? sourceFileName;

  const _SourcePreviewPanel({
    required this.sourceFileUrl,
    required this.sourceFileName,
  });

  bool get _isImage {
    final lower = (sourceFileName ?? sourceFileUrl ?? '').toLowerCase();
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png');
  }

  @override
  Widget build(BuildContext context) {
    if (sourceFileUrl == null) return const SizedBox.shrink();
    if (_isImage) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: CachedNetworkImage(
            imageUrl: sourceFileUrl!,
            fit: BoxFit.contain,
            placeholder: (_, _) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, _, _) =>
                const Center(child: Icon(Icons.broken_image, size: 64)),
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.picture_as_pdf, size: 64),
          const SizedBox(height: 16),
          Text(sourceFileName ?? 'Document source'),
          const SizedBox(height: 16),
          SourceViewerButton(
            sourceFileUrl: sourceFileUrl,
            sourceFileName: sourceFileName,
          ),
        ],
      ),
    );
  }
}
