import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../annotations/domain/annotation.dart';
import '../../../annotations/presentation/annotation_providers.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/utils/platform_utils.dart';

// ── Couleurs badge annotation ──────────────────────────────────────────────

Color annotNoteColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? const Color(0xFF1565C0) // blue.shade800
    : const Color(0xFFBBDEFB); // blue.shade100

Color annotNoteFg(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.white
    : const Color(0xFF0D47A1); // blue.shade900

// ── Badge annotation (avec onTap, pour AppBar) ────────────────────────────

class DetailAnnotBadge extends StatelessWidget {
  final IconData icon;
  final int count;
  final Color color;
  final Color foregroundColor;
  final VoidCallback onTap;
  const DetailAnnotBadge({
    super.key,
    required this.icon,
    required this.count,
    required this.color,
    required this.foregroundColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: foregroundColor),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: TextStyle(fontSize: 11, color: foregroundColor),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tile annotation ────────────────────────────────────────────────────────

enum AnnotationAction { edit, delete }

class AnnotationEditResult {
  final String text;
  final AnnotationType type;
  const AnnotationEditResult({required this.text, required this.type});
}

class AnnotationTile extends ConsumerWidget {
  final Annotation annotation;
  final String recipeId;
  const AnnotationTile({
    super.key,
    required this.annotation,
    required this.recipeId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).value;
    final isOwner = user?.uid == annotation.uid;
    final isAdmin = user?.isAdmin ?? false;
    final theme = Theme.of(context);

    final (icon, color, label) = switch (annotation.type) {
      AnnotationType.note => (
        Icons.sticky_note_2_outlined,
        Colors.blue.shade100,
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
            ? PopupMenuButton<AnnotationAction>(
                onSelected: (action) async {
                  if (action == AnnotationAction.edit) {
                    final result = await showDialog<AnnotationEditResult>(
                      context: context,
                      builder: (_) => AnnotationDialog(
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
                      value: AnnotationAction.edit,
                      child: ListTile(
                        leading: Icon(Icons.edit_outlined),
                        title: Text('Modifier'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: AnnotationAction.delete,
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

// ── Dialog création / édition annotation ────────────────────────────────────

class AnnotationDialog extends ConsumerStatefulWidget {
  final String recipeId;
  final Annotation? existing;
  const AnnotationDialog({super.key, required this.recipeId, this.existing});

  @override
  ConsumerState<AnnotationDialog> createState() => _AnnotationDialogState();
}

class _AnnotationDialogState extends ConsumerState<AnnotationDialog> {
  late final TextEditingController _textCtrl;
  late AnnotationType _type;
  bool _saving = false;

  String _inputHintForType(AnnotationType type) => switch (type) {
    AnnotationType.note => 'Ajouter une note utile',
    AnnotationType.tip => 'Partager une astuce pratique',
    AnnotationType.correction => 'Demander une correction precise',
  };

  String _inputLabelForType(AnnotationType type) => switch (type) {
    AnnotationType.note => 'Ajouter une note',
    AnnotationType.tip => 'Ajouter une astuce',
    AnnotationType.correction => 'Demander une correction',
  };

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
          Navigator.pop(context, AnnotationEditResult(text: text, type: _type));
        }
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeDetailAnnotations.submit',
        error: e,
        stackTrace: stackTrace,
      );
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
    final isMobileCompact = MediaQuery.sizeOf(context).width < PlatformUtils.compactDetailBreakpoint;
    return AlertDialog(
      title: Text(isEdit ? 'Modifier l\'annotation' : 'Nouvelle annotation'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SegmentedButton<AnnotationType>(
              segments: [
                ButtonSegment(
                  value: AnnotationType.note,
                  label: isMobileCompact ? null : const Text('Note'),
                  icon: const Icon(Icons.sticky_note_2_outlined),
                ),
                ButtonSegment(
                  value: AnnotationType.tip,
                  label: isMobileCompact ? null : const Text('Astuce'),
                  icon: const Icon(Icons.lightbulb_outline),
                ),
                ButtonSegment(
                  value: AnnotationType.correction,
                  label: isMobileCompact ? null : const Text('Correction'),
                  icon: const Icon(Icons.build_circle_outlined),
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
              decoration: InputDecoration(
                labelText: _inputLabelForType(_type),
                hintText: _inputHintForType(_type),
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
