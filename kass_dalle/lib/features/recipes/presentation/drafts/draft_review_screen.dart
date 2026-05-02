import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../../../books/presentation/book_providers.dart';
import '../../../books/domain/book.dart';
import '../cooklang_preview.dart';
import '../source_viewer.dart';
import '../edit/ingredient_list_editor.dart';

class DraftReviewScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const DraftReviewScreen({super.key, required this.recipeId});

  @override
  ConsumerState<DraftReviewScreen> createState() => _DraftReviewScreenState();
}

class _DraftReviewScreenState extends ConsumerState<DraftReviewScreen> {
  final _titleCtrl = TextEditingController();
  final _cooklangCtrl = TextEditingController();
  final _portionsCtrl = TextEditingController();
  final _difficultyCtrl = TextEditingController();
  final _prepTimeCtrl = TextEditingController();
  final _cookTimeCtrl = TextEditingController();
  List<RecipeIngredient> _ingredients = const [];
  String? _selectedBookId;
  String? _selectedBookTitre;
  bool _initialized = false;
  bool _saving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _cooklangCtrl.dispose();
    _portionsCtrl.dispose();
    _difficultyCtrl.dispose();
    _prepTimeCtrl.dispose();
    _cookTimeCtrl.dispose();
    super.dispose();
  }

  void _initFromRecipe(Recipe recipe) {
    if (_initialized) return;
    _titleCtrl.text = recipe.titre;
    _cooklangCtrl.text = recipe.draftCooklang ?? recipe.rawCooklang;
    _portionsCtrl.text = recipe.portions?.toString() ?? '';
    _difficultyCtrl.text = recipe.tags.difficulty ?? '';
    _prepTimeCtrl.text = recipe.tags.prepTime?.toString() ?? '';
    _cookTimeCtrl.text = recipe.tags.cookTime?.toString() ?? '';
    _ingredients = List<RecipeIngredient>.from(recipe.ingredients);
    _selectedBookId = recipe.bookId;
    _selectedBookTitre = recipe.bookTitre;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final recipeAsync = ref.watch(recipeDetailProvider(widget.recipeId));
    final booksAsync = ref.watch(myBooksProvider);
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
        _initFromRecipe(recipe);

        return Scaffold(
          appBar: AppBar(
            title: Text(recipe.titre),
            actions: [
              // Voir l'original
              SourceViewerButton(
                sourceFileUrl: recipe.sourceFileUrl,
                sourceFileName: recipe.sourceFileName,
              ),
              // Supprimer
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Supprimer',
                onPressed: _saving ? null : () => _confirmDelete(recipe),
              ),
              // Valider
              FilledButton.icon(
                onPressed: _saving ? null : () => _validate(recipe),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: const Text('Valider'),
              ),
              const SizedBox(width: 8),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 320,
                        child: SingleChildScrollView(
                          child: _MetaPanel(
                            titleCtrl: _titleCtrl,
                            selectedBookId: _selectedBookId,
                            selectedBookTitre: _selectedBookTitre,
                            booksAsync: booksAsync,
                            recipe: recipe,
                            saving: _saving,
                            portionsCtrl: _portionsCtrl,
                            difficultyCtrl: _difficultyCtrl,
                            prepTimeCtrl: _prepTimeCtrl,
                            cookTimeCtrl: _cookTimeCtrl,
                            ingredients: _ingredients,
                            onIngredientsChanged: (v) =>
                                setState(() => _ingredients = v),
                            onBookChanged: (id, titre) => setState(() {
                              _selectedBookId = id;
                              _selectedBookTitre = titre;
                            }),
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
                                  Tab(text: 'Édition'),
                                  Tab(text: 'Aperçu'),
                                ],
                              ),
                              Expanded(
                                child: TabBarView(
                                  children: [
                                    _CooklangEditor(
                                      ctrl: _cooklangCtrl,
                                      enabled: !_saving,
                                    ),
                                    CooklangPreview(ctrl: _cooklangCtrl),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                : _buildNarrowLayout(recipe, booksAsync),
          ),
        );
      },
    );
  }

  Widget _buildNarrowLayout(Recipe recipe, AsyncValue<List<Book>> booksAsync) {
    final hasSource =
        recipe.sourceFileUrl != null && recipe.sourceFileUrl!.isNotEmpty;
    return DefaultTabController(
      length: hasSource ? 4 : 3,
      child: Column(
        children: [
          TabBar(
            tabs: [
              const Tab(text: 'Informations'),
              const Tab(text: 'CookLang'),
              const Tab(text: 'Aperçu'),
              if (hasSource) const Tab(text: 'Original'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 16),
                  child: _MetaPanel(
                    titleCtrl: _titleCtrl,
                    selectedBookId: _selectedBookId,
                    selectedBookTitre: _selectedBookTitre,
                    booksAsync: booksAsync,
                    recipe: recipe,
                    saving: _saving,
                    portionsCtrl: _portionsCtrl,
                    difficultyCtrl: _difficultyCtrl,
                    prepTimeCtrl: _prepTimeCtrl,
                    cookTimeCtrl: _cookTimeCtrl,
                    ingredients: _ingredients,
                    onIngredientsChanged: (v) =>
                        setState(() => _ingredients = v),
                    onBookChanged: (id, titre) => setState(() {
                      _selectedBookId = id;
                      _selectedBookTitre = titre;
                    }),
                  ),
                ),
                _CooklangEditor(ctrl: _cooklangCtrl, enabled: !_saving),
                CooklangPreview(ctrl: _cooklangCtrl),
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

  /// Insère, remplace ou supprime la ligne `>> key: value` dans le CookLang.
  String _syncMeta(String cooklang, String key, String? value) {
    final lines = cooklang.split('\n');
    final newLine = value != null && value.isNotEmpty
        ? '>> $key: $value'
        : null;
    final pattern = RegExp(
      '^>>\\s*${RegExp.escape(key)}\\s*:',
      caseSensitive: false,
    );
    final idx = lines.indexWhere((l) => pattern.hasMatch(l.trim()));
    if (newLine == null) {
      if (idx >= 0) lines.removeAt(idx);
    } else if (idx >= 0) {
      lines[idx] = newLine;
    } else {
      final lastMeta = lines.lastIndexWhere((l) => l.trim().startsWith('>>'));
      lines.insert(lastMeta >= 0 ? lastMeta + 1 : 0, newLine);
    }
    return lines.join('\n');
  }

  /// Synchronise tous les champs structurés dans le texte CookLang.
  String _syncAllMeta(String cooklang) {
    var c = cooklang;
    c = _syncMeta(c, 'titre', _titleCtrl.text.trim());
    c = _syncMeta(
      c,
      'portions',
      _portionsCtrl.text.trim().isEmpty ? null : _portionsCtrl.text.trim(),
    );
    c = _syncMeta(
      c,
      'prep_time',
      _prepTimeCtrl.text.trim().isEmpty ? null : _prepTimeCtrl.text.trim(),
    );
    c = _syncMeta(
      c,
      'cook_time',
      _cookTimeCtrl.text.trim().isEmpty ? null : _cookTimeCtrl.text.trim(),
    );
    return c;
  }

  Future<void> _validate(Recipe recipe) async {
    if (_cooklangCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le contenu CookLang est vide')),
      );
      return;
    }
    setState(() => _saving = true);
    final portionsValue = int.tryParse(_portionsCtrl.text.trim());
    final syncedCooklang = _syncAllMeta(_cooklangCtrl.text.trim());
    try {
      await ref
          .read(recipeRepositoryProvider)
          .validateDraft(
            recipeId: recipe.id,
            editedCooklang: syncedCooklang,
            titre: _titleCtrl.text.trim().isEmpty
                ? recipe.titre
                : _titleCtrl.text.trim(),
            bookId: _selectedBookId,
            bookTitre: _selectedBookTitre,
            portionsOverride: portionsValue,
            tagsOverride: RecipeTags(
              themes: recipe.tags.themes,
              cuisines: recipe.tags.cuisines,
              occasions: recipe.tags.occasions,
              difficulty: _difficultyCtrl.text.trim().isEmpty
                  ? null
                  : _difficultyCtrl.text.trim(),
              prepTime: int.tryParse(_prepTimeCtrl.text.trim()),
              cookTime: int.tryParse(_cookTimeCtrl.text.trim()),
            ),
            ingredientsOverride: _ingredients,
          );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recette validée !')));
        context.go('/drafts');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete(Recipe recipe) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Supprimer ce brouillon ?'),
        content: Text('« ${recipe.titre} » sera définitivement supprimé.'),
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
}

// ── Panneau d'informations ────────────────────────────────────────────────────

class _MetaPanel extends StatelessWidget {
  final TextEditingController titleCtrl;
  final String? selectedBookId;
  final String? selectedBookTitre;
  final AsyncValue<List<Book>> booksAsync;
  final Recipe recipe;
  final bool saving;
  final TextEditingController portionsCtrl;
  final TextEditingController difficultyCtrl;
  final TextEditingController prepTimeCtrl;
  final TextEditingController cookTimeCtrl;
  final List<RecipeIngredient> ingredients;
  final ValueChanged<List<RecipeIngredient>> onIngredientsChanged;
  final void Function(String? id, String? titre) onBookChanged;

  const _MetaPanel({
    required this.titleCtrl,
    required this.selectedBookId,
    required this.selectedBookTitre,
    required this.booksAsync,
    required this.recipe,
    required this.saving,
    required this.portionsCtrl,
    required this.difficultyCtrl,
    required this.prepTimeCtrl,
    required this.cookTimeCtrl,
    required this.ingredients,
    required this.onIngredientsChanged,
    required this.onBookChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: titleCtrl,
          enabled: !saving,
          decoration: const InputDecoration(
            labelText: 'Titre de la recette',
            prefixIcon: Icon(Icons.title),
          ),
        ),
        const SizedBox(height: 16),
        booksAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (books) => DropdownButtonFormField<String>(
            decoration: const InputDecoration(
              labelText: 'Livre',
              prefixIcon: Icon(Icons.menu_book_outlined),
            ),
            initialValue: selectedBookId,
            items: [
              const DropdownMenuItem<String>(
                value: null,
                child: Text('Aucun livre'),
              ),
              ...books.map(
                (b) => DropdownMenuItem(value: b.id, child: Text(b.titre)),
              ),
            ],
            onChanged: saving
                ? null
                : (val) {
                    final titre = val == null
                        ? null
                        : books.firstWhere((b) => b.id == val).titre;
                    onBookChanged(val, titre);
                  },
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: portionsCtrl,
          enabled: !saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Portions',
            prefixIcon: Icon(Icons.groups_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: difficultyCtrl,
          enabled: !saving,
          decoration: const InputDecoration(
            labelText: 'Difficulte',
            prefixIcon: Icon(Icons.bolt_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: prepTimeCtrl,
          enabled: !saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Temps preparation (min)',
            prefixIcon: Icon(Icons.timer_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: cookTimeCtrl,
          enabled: !saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Temps cuisson (min)',
            prefixIcon: Icon(Icons.local_fire_department_outlined),
          ),
        ),
        const SizedBox(height: 16),
        IngredientListEditor(
          initialIngredients: ingredients,
          enabled: !saving,
          onChanged: onIngredientsChanged,
        ),
        const SizedBox(height: 24),
        if (recipe.sourceFileName != null) ...[
          Text('Source', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.attach_file, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  recipe.sourceFileName!,
                  style: Theme.of(context).textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        if (recipe.aiProcessedAt != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.smart_toy_outlined, size: 16),
              const SizedBox(width: 6),
              Text(
                'Analysé le ${_fmt(recipe.aiProcessedAt!)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}

// ── Éditeur CookLang ──────────────────────────────────────────────────────────

class _CooklangEditor extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;

  const _CooklangEditor({required this.ctrl, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('CookLang', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(width: 8),
            Tooltip(
              message:
                  'Format CookLang :\n@ingredient{qté%unité}\n#équipement{}\n~{durée%unité}\n>> clé: valeur',
              child: Icon(
                Icons.help_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: TextField(
            controller: ctrl,
            enabled: enabled,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              hintText:
                  '>> titre: Ma recette\n>> portions: 4\n\nMélangez @farine{200%g} et @oeufs{2}...',
              alignLabelWithHint: true,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Panneau d'aperçu du document source ──────────────────────────────────────

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
            placeholder: (_, __) =>
                const Center(child: CircularProgressIndicator()),
            errorWidget: (_, __, ___) =>
                const Center(child: Icon(Icons.broken_image, size: 64)),
          ),
        ),
      );
    }
    // PDF ou autre : bouton d'ouverture externe
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
