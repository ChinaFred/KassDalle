import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/book.dart';
import 'book_providers.dart';

class BookValidationScreen extends ConsumerWidget {
  const BookValidationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draftsAsync = ref.watch(draftBooksProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Livres à valider')),
      body: draftsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (books) {
          if (books.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.verified_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Aucun livre à valider',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: books.length,
            separatorBuilder: (_, __) => const SizedBox(height: 16),
            itemBuilder: (context, i) => _DraftBookCard(book: books[i]),
          );
        },
      ),
    );
  }
}

class _DraftBookCard extends ConsumerStatefulWidget {
  final Book book;
  const _DraftBookCard({required this.book});

  @override
  ConsumerState<_DraftBookCard> createState() => _DraftBookCardState();
}

class _DraftBookCardState extends ConsumerState<_DraftBookCard> {
  bool _validating = false;

  Future<void> _validate() async {
    setState(() => _validating = true);
    try {
      final validated = Book(
        id: widget.book.id,
        titre: widget.book.titre,
        sousTitre: widget.book.sousTitre,
        editeur: widget.book.editeur,
        serie: widget.book.serie,
        auteur: widget.book.auteur,
        annee: widget.book.annee,
        langue: widget.book.langue,
        isbn: widget.book.isbn,
        description: widget.book.description,
        urlCouverture: widget.book.urlCouverture,
        tags: widget.book.tags,
        reviewStatus: BookReviewStatus.validated,
        createdBy: widget.book.createdBy,
        createdAt: widget.book.createdAt,
        updatedAt: DateTime.now(),
        sharedWith: widget.book.sharedWith,
        sourceFileUrl: widget.book.sourceFileUrl,
        sourceFileName: widget.book.sourceFileName,
        aiProcessedAt: widget.book.aiProcessedAt,
      );
      await ref.read(bookRepositoryProvider).updateBook(validated);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${widget.book.titre}" validé !')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = widget.book;
    final hasCover = (book.urlCouverture ?? '').isNotEmpty;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Couverture
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 80,
                height: 110,
                child: hasCover
                    ? CachedNetworkImage(
                        imageUrl: book.urlCouverture!,
                        fit: BoxFit.cover,
                        errorWidget: (_, __, ___) =>
                            _PlaceholderCover(theme: theme),
                      )
                    : _PlaceholderCover(theme: theme),
              ),
            ),
            const SizedBox(width: 16),
            // Champs structurés
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.titre,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if ((book.sousTitre ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      book.sousTitre!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  _FieldRow(label: 'Auteur', value: book.auteur),
                  if ((book.editeur ?? '').isNotEmpty)
                    _FieldRow(label: 'Éditeur', value: book.editeur!),
                  if ((book.serie ?? '').isNotEmpty)
                    _FieldRow(label: 'Série', value: book.serie!),
                  if (book.annee != null)
                    _FieldRow(label: 'Année', value: '${book.annee}'),
                  _FieldRow(label: 'Langue', value: book.langue.toUpperCase()),
                  if ((book.isbn ?? '').isNotEmpty)
                    _FieldRow(label: 'ISBN', value: book.isbn!),
                  if (book.tags.isNotEmpty)
                    _FieldRow(label: 'Tags', value: book.tags.join(', ')),
                  if ((book.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      book.description!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _validating ? null : _validate,
                        icon: _validating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline, size: 18),
                        label: const Text('Valider'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _validating
                            ? null
                            : () => context.push('/books/${book.id}/edit'),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Modifier'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FieldRow extends StatelessWidget {
  final String label;
  final String value;
  const _FieldRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: RichText(
        text: TextSpan(
          style: theme.textTheme.bodySmall,
          children: [
            TextSpan(
              text: '$label : ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }
}

class _PlaceholderCover extends StatelessWidget {
  final ThemeData theme;
  const _PlaceholderCover({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.menu_book_rounded,
          size: 32,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
