import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/book.dart';
import 'book_providers.dart';

class BookListScreen extends ConsumerWidget {
  const BookListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(accessibleBooksProvider);
    final canEdit = ref.watch(canEditProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bibliothèque'),
        actions: [
          if (canEdit)
            FilledButton.icon(
              onPressed: () => context.push('/books/new'),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter un livre'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: booksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (books) {
          if (books.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.library_books_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Aucun livre pour le moment',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (canEdit)
                    FilledButton.icon(
                      onPressed: () => context.push('/books/new'),
                      icon: const Icon(Icons.add),
                      label: const Text('Ajouter un livre manuellement'),
                    ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: books.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) =>
                _BookTile(book: books[i], canEdit: canEdit),
          );
        },
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/books/new'),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter'),
            )
          : null,
    );
  }
}

class _BookTile extends StatelessWidget {
  final Book book;
  final bool canEdit;

  const _BookTile({required this.book, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      book.auteur,
      if (book.editeur != null && book.editeur!.isNotEmpty) book.editeur!,
      if (book.serie != null && book.serie!.isNotEmpty) 'Serie: ${book.serie}',
      if (book.annee != null) '${book.annee}',
      book.langue.toUpperCase(),
    ].join(' • ');

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primaryContainer,
        child: Icon(
          Icons.menu_book_rounded,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
      title: Text(book.titre),
      subtitle: Text(
        [
          if (book.sousTitre != null && book.sousTitre!.isNotEmpty)
            book.sousTitre!,
          meta,
        ].join('\n'),
      ),
      trailing: canEdit
          ? IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Modifier le livre',
              onPressed: () => context.push('/books/${book.id}/edit'),
            )
          : null,
      onTap: () => context.go(
        '/recipes?bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}',
      ),
    );
  }
}
