import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';
import '../source_viewer.dart';
import '../edit/ingredient_list_editor.dart';
import '../edit/recipe_form_mixin.dart';
import '../edit/recipe_meta_panel.dart';
import '../edit/recipe_cooklang_editor.dart';

class DraftReviewScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const DraftReviewScreen({super.key, required this.recipeId});

  @override
  ConsumerState<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends ConsumerState<DraftReviewScreen>
    with RecipeFormMixin<DraftReviewScreen> {
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
            ? ref
                  .watch(userByUidProvider(recipe.createdBy))
                  .value
                  ?.displayName
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
            child: isWide ? _buildWide(recipe) : _buildNarrow(recipe),
          ),
        );
      },
    );
  }

  Widget _buildWide(Recipe recipe) {
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
            length: 3,
            child: Column(
              children: [
                const TabBar(
                  tabs: [
                    Tab(text: 'CookLang'),
                    Tab(text: 'Aperçu'),
                    Tab(text: 'Ingrédients'),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      RecipeCooklangEditor(
                        ctrl: cooklangCtrl,
                        enabled: !saving,
                        showHelp: true,
                      ),
                      CooklangPreview(
                        ctrl: cooklangCtrl,
                        overrideIngredients: formIngredients,
                      ),
                      SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: IngredientListEditor(
                          initialIngredients: formIngredients,
                          enabled: !saving,
                          onChanged: setIngredients,
                        ),
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

  Widget _buildNarrow(Recipe recipe) {
    final hasSource =
        recipe.sourceFileUrl != null && recipe.sourceFileUrl!.isNotEmpty;
    return DefaultTabController(
      length: hasSource ? 5 : 4,
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
                  enabled: !saving,
                  showHelp: true,
                ),
                CooklangPreview(
                  ctrl: cooklangCtrl,
                  overrideIngredients: formIngredients,
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !saving,
                    onChanged: setIngredients,
                  ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le contenu CookLang est vide')),
      );
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recette validée !')));
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
