import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../cooklang_preview.dart';
import '../source_viewer.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';

class RecipeDetailScreen extends ConsumerWidget {
  final String recipeId;
  const RecipeDetailScreen({super.key, required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipeAsync = ref.watch(recipeDetailProvider(recipeId));
    final user = ref.watch(appUserProvider).valueOrNull;

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

        final ctrl = TextEditingController(text: recipe.rawCooklang);
        final canEdit =
            user != null && (user.canEdit || user.uid == recipe.createdBy);

        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(recipe.titre),
                if (recipe.bookTitre != null)
                  Text(
                    recipe.bookTitre!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
            actions: [
              SourceViewerButton(
                sourceFileUrl: recipe.sourceFileUrl,
                sourceFileName: recipe.sourceFileName,
              ),
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Modifier la recette',
                  onPressed: () => context.push('/recipes/${recipe.id}/edit'),
                ),
            ],
          ),
          body: _RecipeDetailBody(recipeId: recipeId, ctrl: ctrl),
          floatingActionButton: user != null
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.comment_outlined),
                  label: const Text('Annoter'),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => _AnnotationDialog(recipeId: recipeId),
                  ),
                )
              : null,
        );
      },
    );
  }
}

// ── Body : preview + liste annotations ──────────────────────────────────────

class _RecipeDetailBody extends ConsumerWidget {
  final String recipeId;
  final TextEditingController ctrl;
  const _RecipeDetailBody({required this.recipeId, required this.ctrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotationsAsync = ref.watch(annotationsProvider(recipeId));

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: CooklangPreview(ctrl: ctrl)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Annotations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
          ),
        ),
        annotationsAsync.when(
          loading: () => const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) =>
              SliverToBoxAdapter(child: Center(child: Text('Erreur : $e'))),
          data: (annotations) {
            if (annotations.isEmpty) {
              return const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'Aucune annotation. Soyez le premier !',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              );
            }
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => _AnnotationTile(
                  annotation: annotations[i],
                  recipeId: recipeId,
                ),
                childCount: annotations.length,
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}

// ── Tile annotation ──────────────────────────────────────────────────────────

class _AnnotationTile extends ConsumerWidget {
  final Annotation annotation;
  final String recipeId;
  const _AnnotationTile({required this.annotation, required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).valueOrNull;
    final isOwner = user?.uid == annotation.uid;
    final isAdmin = user?.isAdmin ?? false;
    final theme = Theme.of(context);

    final (icon, color, label) = switch (annotation.type) {
      AnnotationType.note => (
        Icons.sticky_note_2_outlined,
        theme.colorScheme.secondaryContainer,
        'Note',
      ),
      AnnotationType.tip => (
        Icons.lightbulb_outline,
        theme.colorScheme.tertiaryContainer,
        'Astuce',
      ),
      AnnotationType.correction => (
        Icons.build_circle_outlined,
        theme.colorScheme.errorContainer,
        'Correction',
      ),
    };

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Icon(icon, size: 18),
        ),
        title: Text(annotation.text),
        subtitle: Text(
          '${annotation.authorName} · $label',
          style: theme.textTheme.bodySmall,
        ),
        trailing: (isOwner || isAdmin)
            ? PopupMenuButton<_AnnotationAction>(
                onSelected: (action) async {
                  if (action == _AnnotationAction.edit) {
                    final result = await showDialog<_AnnotationEditResult>(
                      context: context,
                      builder: (_) => _AnnotationDialog(
                        recipeId: recipeId,
                        existing: annotation,
                      ),
                    );
                    if (result != null) {
                      await updateAnnotation(
                        ref: ref,
                        recipeId: recipeId,
                        annotationId: annotation.id,
                        text: result.text,
                        type: result.type,
                      );
                    }
                  } else {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Supprimer l\'annotation ?'),
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
                    if (confirmed == true) {
                      await deleteAnnotation(
                        ref: ref,
                        recipeId: recipeId,
                        annotationId: annotation.id,
                      );
                    }
                  }
                },
                itemBuilder: (_) => [
                  if (isOwner)
                    const PopupMenuItem(
                      value: _AnnotationAction.edit,
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Modifier'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: _AnnotationAction.delete,
                    child: ListTile(
                      leading: Icon(Icons.delete_outline),
                      title: Text('Supprimer'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

enum _AnnotationAction { edit, delete }

class _AnnotationEditResult {
  final String text;
  final AnnotationType type;
  const _AnnotationEditResult({required this.text, required this.type});
}

// ── Dialog création / édition annotation ────────────────────────────────────

class _AnnotationDialog extends ConsumerStatefulWidget {
  final String recipeId;
  final Annotation? existing;
  const _AnnotationDialog({required this.recipeId, this.existing});

  @override
  ConsumerState<_AnnotationDialog> createState() => _AnnotationDialogState();
}

class _AnnotationDialogState extends ConsumerState<_AnnotationDialog> {
  late final TextEditingController _textCtrl;
  late AnnotationType _type;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.existing?.text ?? '');
    _type = widget.existing?.type ?? AnnotationType.note;
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _saving = true);
    try {
      if (widget.existing == null) {
        await addAnnotation(
          ref: ref,
          recipeId: widget.recipeId,
          text: text,
          type: _type,
        );
        if (mounted) Navigator.pop(context);
      } else {
        if (mounted) {
          Navigator.pop(
            context,
            _AnnotationEditResult(text: text, type: _type),
          );
        }
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
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? 'Modifier l\'annotation' : 'Nouvelle annotation'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<AnnotationType>(
              segments: const [
                ButtonSegment(
                  value: AnnotationType.note,
                  label: Text('Note'),
                  icon: Icon(Icons.sticky_note_2_outlined),
                ),
                ButtonSegment(
                  value: AnnotationType.tip,
                  label: Text('Astuce'),
                  icon: Icon(Icons.lightbulb_outline),
                ),
                ButtonSegment(
                  value: AnnotationType.correction,
                  label: Text('Correction'),
                  icon: Icon(Icons.build_circle_outlined),
                ),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _textCtrl,
              autofocus: true,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Texte',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isEdit ? 'Mettre à jour' : 'Ajouter'),
        ),
      ],
    );
  }
}
