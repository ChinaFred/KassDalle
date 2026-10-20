import 'package:flutter/material.dart';

import 'work_queue_batch.dart';
import '../../../books/domain/book.dart';
import '../../../books/presentation/book_picker_field.dart';
import '../../domain/recipe.dart';
import '../../../../core/utils/platform_utils.dart';

/// Demande dans quel livre ranger [drafts]. Rend le livre choisi, `null` si
/// l'utilisateur annule.
Future<Book?> showAssignBookSheet(
  BuildContext context, {
  required List<Book> books,
  required List<Recipe> drafts,
}) {
  final content = AssignBookSheet(books: books, drafts: drafts);
  if (MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint) {
    return showDialog<Book>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: content,
        ),
      ),
    );
  }
  return showModalBottomSheet<Book>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => content,
  );
}

/// Contenu de la feuille « Ranger dans un livre » : le sélecteur, ce que le
/// rangement change, puis « Annuler » et « Ranger (N) ».
class AssignBookSheet extends StatefulWidget {
  final List<Book> books;
  final List<Recipe> drafts;

  const AssignBookSheet({super.key, required this.books, required this.drafts});

  @override
  State<AssignBookSheet> createState() => _AssignBookSheetState();
}

class _AssignBookSheetState extends State<AssignBookSheet> {
  Book? _book;

  void _onChanged(String? id, String? _) {
    setState(() {
      _book = widget.books.where((b) => b.id == id).firstOrNull;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = _book;
    final impact = book == null
        ? null
        : bookAssignmentImpact(widget.drafts, book.id);
    final notes = <String>[
      if (impact != null && impact.changing > 0)
        '${countOf(impact.changing, 'brouillon change', 'brouillons changent')}'
            ' de livre.',
      if (impact != null && impact.withPageNumber > 0)
        'Le numéro de page est conservé tel quel : celui '
            '${impact.withPageNumber >= 2 ? 'de certains brouillons' : 'd\'un brouillon'}'
            ' peut ne plus correspondre au nouveau livre.',
      if (impact != null && book!.isPrivate && impact.changing > 0)
        'Ce livre est privé : les brouillons qui changent de livre deviennent privés.',
    ];
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            16,
            24,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ranger dans un livre', style: theme.textTheme.titleLarge),
              const SizedBox(height: 16),
              BookPickerField(
                books: widget.books,
                selectedBookId: book?.id,
                onChanged: _onChanged,
              ),
              for (final note in notes) ...[
                const SizedBox(height: 12),
                Text(note, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: OverflowBar(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Annuler'),
                    ),
                    FilledButton(
                      onPressed: book == null
                          ? null
                          : () => Navigator.pop(context, book),
                      child: Text('Ranger (${widget.drafts.length})'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
