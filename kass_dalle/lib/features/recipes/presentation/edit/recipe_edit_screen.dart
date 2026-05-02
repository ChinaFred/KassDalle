import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../../../books/presentation/book_providers.dart';
import '../../../books/domain/book.dart';
import '../cooklang_preview.dart';
import 'ingredient_list_editor.dart';

class RecipeEditScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const RecipeEditScreen({super.key, required this.recipeId});

  @override
  ConsumerState<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _RecipeEditScreenState extends ConsumerState<RecipeEditScreen> {
  final _titleCtrl = TextEditingController();
  final _cooklangCtrl = TextEditingController();
  final _portionsCtrl = TextEditingController();
  final _difficultyCtrl = TextEditingController();
  final _prepTimeCtrl = TextEditingController();
  final _cookTimeCtrl = TextEditingController();
  final _pageNumberCtrl = TextEditingController();
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
    _pageNumberCtrl.dispose();
    super.dispose();
  }

  void _initFromRecipe(Recipe recipe) {
    if (_initialized) return;
    _titleCtrl.text = recipe.titre;
    _cooklangCtrl.text = recipe.rawCooklang;
    _portionsCtrl.text = recipe.portions?.toString() ?? '';
    _difficultyCtrl.text = recipe.tags.difficulty ?? '';
    _prepTimeCtrl.text = recipe.tags.prepTime?.toString() ?? '';
    _cookTimeCtrl.text = recipe.tags.cookTime?.toString() ?? '';
    _ingredients = List<RecipeIngredient>.from(recipe.ingredients);
    _selectedBookId = recipe.bookId;
    _selectedBookTitre = recipe.bookTitre;
    _pageNumberCtrl.text = recipe.pageNumber?.toString() ?? '';
    _initialized = true;
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

  Future<void> _save(Recipe recipe) async {
    final titre = _titleCtrl.text.trim();
    if (titre.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Le titre est obligatoire')));
      return;
    }
    setState(() => _saving = true);
    final portionsValue = int.tryParse(_portionsCtrl.text.trim());
    final syncedCooklang = _syncAllMeta(_cooklangCtrl.text);
    try {
      final updated = recipe.copyWith(
        titre: titre,
        rawCooklang: syncedCooklang,
        portions: portionsValue,
        bookId: _selectedBookId,
        bookTitre: _selectedBookTitre,
        pageNumber: int.tryParse(_pageNumberCtrl.text.trim()),
        tags: recipe.tags.copyWith(
          difficulty: _difficultyCtrl.text.trim().isEmpty
              ? null
              : _difficultyCtrl.text.trim(),
          prepTime: int.tryParse(_prepTimeCtrl.text.trim()),
          cookTime: int.tryParse(_cookTimeCtrl.text.trim()),
        ),
        ingredients: _ingredients,
        updatedAt: DateTime.now(),
      );
      await ref.read(recipeRepositoryProvider).updateRecipe(updated);
      // Invalide le cache pour recharger le détail
      ref.invalidate(recipeDetailProvider(widget.recipeId));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Recette mise à jour')));
        context.pop();
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
            title: const Text('Modifier la recette'),
            actions: [
              FilledButton.icon(
                onPressed: _saving ? null : () => _save(recipe),
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: const Text('Enregistrer'),
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
                        width: 300,
                        child: SingleChildScrollView(
                          child: _MetaPanel(
                            titleCtrl: _titleCtrl,
                            portionsCtrl: _portionsCtrl,
                            difficultyCtrl: _difficultyCtrl,
                            prepTimeCtrl: _prepTimeCtrl,
                            cookTimeCtrl: _cookTimeCtrl,
                            pageNumberCtrl: _pageNumberCtrl,
                            saving: _saving,
                            selectedBookId: _selectedBookId,
                            booksAsync: booksAsync,
                            onBookChanged: (id, titre) => setState(() {
                              _selectedBookId = id;
                              _selectedBookTitre = titre;
                            }),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _EditorPreviewTabs(
                          ctrl: _cooklangCtrl,
                          enabled: !_saving,
                          ingredients: _ingredients,
                          onIngredientsChanged: (v) =>
                              setState(() => _ingredients = v),
                        ),
                      ),
                    ],
                  )
                : DefaultTabController(
                    length: 4,
                    child: Column(
                      children: [
                        const TabBar(
                          isScrollable: true,
                          tabAlignment: TabAlignment.start,
                          tabs: [
                            Tab(text: 'Informations'),
                            Tab(text: 'CookLang'),
                            Tab(text: 'Aperçu'),
                            Tab(text: 'Ingrédients'),
                          ],
                        ),
                        Expanded(
                          child: TabBarView(
                            children: [
                              SingleChildScrollView(
                                padding: const EdgeInsets.only(top: 16),
                                child: _MetaPanel(
                                  titleCtrl: _titleCtrl,
                                  portionsCtrl: _portionsCtrl,
                                  difficultyCtrl: _difficultyCtrl,
                                  prepTimeCtrl: _prepTimeCtrl,
                                  cookTimeCtrl: _cookTimeCtrl,
                                  pageNumberCtrl: _pageNumberCtrl,
                                  saving: _saving,
                                  selectedBookId: _selectedBookId,
                                  booksAsync: booksAsync,
                                  onBookChanged: (id, titre) => setState(() {
                                    _selectedBookId = id;
                                    _selectedBookTitre = titre;
                                  }),
                                ),
                              ),
                              _CooklangEditorExpanded(
                                ctrl: _cooklangCtrl,
                                enabled: !_saving,
                              ),
                              CooklangPreview(ctrl: _cooklangCtrl),
                              SingleChildScrollView(
                                padding: const EdgeInsets.all(16),
                                child: IngredientListEditor(
                                  initialIngredients: _ingredients,
                                  enabled: !_saving,
                                  onChanged: (v) =>
                                      setState(() => _ingredients = v),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        );
      },
    );
  }
}

// ── Panneau de métadonnées ──────────────────────────────────────────────────

class _MetaPanel extends StatelessWidget {
  final TextEditingController titleCtrl;
  final TextEditingController portionsCtrl;
  final TextEditingController difficultyCtrl;
  final TextEditingController prepTimeCtrl;
  final TextEditingController cookTimeCtrl;
  final TextEditingController pageNumberCtrl;
  final bool saving;
  final String? selectedBookId;
  final AsyncValue<List<Book>> booksAsync;
  final void Function(String? id, String? titre) onBookChanged;

  const _MetaPanel({
    required this.titleCtrl,
    required this.portionsCtrl,
    required this.difficultyCtrl,
    required this.prepTimeCtrl,
    required this.cookTimeCtrl,
    required this.pageNumberCtrl,
    required this.saving,
    required this.selectedBookId,
    required this.booksAsync,
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
            labelText: 'Difficulté',
            prefixIcon: Icon(Icons.bolt_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: prepTimeCtrl,
          enabled: !saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Temps préparation (min)',
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
        booksAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (books) => DropdownButtonFormField<String>(
            decoration: const InputDecoration(
              labelText: 'Livre',
              prefixIcon: Icon(Icons.menu_book_outlined),
            ),
            value: selectedBookId,
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
        const SizedBox(height: 12),
        TextField(
          controller: pageNumberCtrl,
          enabled: !saving,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Page dans le livre',
            prefixIcon: Icon(Icons.bookmark_outline),
          ),
        ),
      ],
    );
  }
}

// ── Éditeur + aperçu (layout large) ────────────────────────────────────────

class _EditorPreviewTabs extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  final List<RecipeIngredient> ingredients;
  final ValueChanged<List<RecipeIngredient>> onIngredientsChanged;
  const _EditorPreviewTabs({
    required this.ctrl,
    required this.enabled,
    required this.ingredients,
    required this.onIngredientsChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
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
                _CooklangEditorExpanded(ctrl: ctrl, enabled: enabled),
                CooklangPreview(ctrl: ctrl),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: ingredients,
                    enabled: enabled,
                    onChanged: onIngredientsChanged,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CooklangEditorExpanded extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  const _CooklangEditorExpanded({required this.ctrl, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
      decoration: const InputDecoration(
        hintText: 'Contenu CookLang…',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.all(12),
      ),
    );
  }
}
