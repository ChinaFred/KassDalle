import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../cooklang_preview.dart';

class RecipeEditScreen extends ConsumerStatefulWidget {
  final String recipeId;
  const RecipeEditScreen({super.key, required this.recipeId});

  @override
  ConsumerState<RecipeEditScreen> createState() => _RecipeEditScreenState();
}

class _RecipeEditScreenState extends ConsumerState<RecipeEditScreen> {
  final _titleCtrl = TextEditingController();
  final _cooklangCtrl = TextEditingController();
  bool _initialized = false;
  bool _saving = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _cooklangCtrl.dispose();
    super.dispose();
  }

  void _initFromRecipe(Recipe recipe) {
    if (_initialized) return;
    _titleCtrl.text = recipe.titre;
    _cooklangCtrl.text = recipe.rawCooklang;
    _initialized = true;
  }

  Future<void> _save(Recipe recipe) async {
    final titre = _titleCtrl.text.trim();
    if (titre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Le titre est obligatoire')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final updated = recipe.copyWith(
        titre: titre,
        rawCooklang: _cooklangCtrl.text,
        updatedAt: DateTime.now(),
      );
      await ref.read(recipeRepositoryProvider).updateRecipe(updated);
      // Invalide le cache pour recharger le détail
      ref.invalidate(recipeDetailProvider(widget.recipeId));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recette mise à jour')),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur : $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
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
                        width: 280,
                        child: _TitleField(ctrl: _titleCtrl, enabled: !_saving),
                      ),
                      const SizedBox(width: 16),
                      Expanded(child: _EditorPreviewTabs(ctrl: _cooklangCtrl, enabled: !_saving)),
                    ],
                  )
                : Column(
                    children: [
                      _TitleField(ctrl: _titleCtrl, enabled: !_saving),
                      const SizedBox(height: 12),
                      Expanded(child: _EditorPreviewTabs(ctrl: _cooklangCtrl, enabled: !_saving)),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _TitleField extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  const _TitleField({required this.ctrl, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: ctrl,
      enabled: enabled,
      decoration: const InputDecoration(
        labelText: 'Titre',
        border: OutlineInputBorder(),
      ),
    );
  }
}

class _EditorPreviewTabs extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  const _EditorPreviewTabs({required this.ctrl, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            tabs: [Tab(text: 'Édition'), Tab(text: 'Aperçu')],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _CooklangEditor(ctrl: ctrl, enabled: enabled),
                CooklangPreview(ctrl: ctrl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CooklangEditor extends StatelessWidget {
  final TextEditingController ctrl;
  final bool enabled;
  const _CooklangEditor({required this.ctrl, required this.enabled});

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
