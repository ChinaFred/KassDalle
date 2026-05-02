import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/recipe.dart';
import '../../../books/presentation/book_providers.dart';

/// Shared metadata form panel used by draft review, recipe edit, and recipe
/// create screens.
///
/// Field order: Titre → Livre → Page → Portions → Difficulté → PrepTime → CookTime
/// When [recipe] is provided, an AI / source file footer is shown at the bottom
/// (used by the draft review flow only).
class RecipeMetaPanel extends ConsumerWidget {
  final TextEditingController titleCtrl;
  final TextEditingController portionsCtrl;
  final TextEditingController difficultyCtrl;
  final TextEditingController prepTimeCtrl;
  final TextEditingController cookTimeCtrl;
  final TextEditingController pageNumberCtrl;
  final bool saving;
  final String? selectedBookId;
  final void Function(String? id, String? titre) onBookChanged;

  /// When non-null, shows a source file / AI processing footer (draft only).
  final Recipe? recipe;

  const RecipeMetaPanel({
    super.key,
    required this.titleCtrl,
    required this.portionsCtrl,
    required this.difficultyCtrl,
    required this.prepTimeCtrl,
    required this.cookTimeCtrl,
    required this.pageNumberCtrl,
    required this.saving,
    required this.selectedBookId,
    required this.onBookChanged,
    this.recipe,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(myBooksProvider);

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
            // ignore: deprecated_member_use
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
        // ── Footer source / IA (brouillons seulement) ───────────────────────
        if (recipe != null) ...[
          const SizedBox(height: 24),
          if (recipe!.sourceFileName != null) ...[
            Text('Source', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.attach_file, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    recipe!.sourceFileName!,
                    style: Theme.of(context).textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (recipe!.aiProcessedAt != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.smart_toy_outlined, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Analysé le ${_fmt(recipe!.aiProcessedAt!)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ],
      ],
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/'
      '${dt.month.toString().padLeft(2, '0')}/'
      '${dt.year}';
}
