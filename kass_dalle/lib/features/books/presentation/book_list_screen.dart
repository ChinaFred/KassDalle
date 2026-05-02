import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/book.dart';
import 'book_providers.dart';

class BookListScreen extends ConsumerWidget {
  const BookListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(accessibleBooksProvider);
    final canEdit = ref.watch(canEditProvider);
    final draftCount = ref.watch(draftBooksCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bibliothèque'),
        actions: [
          if (canEdit && draftCount > 0)
            IconButton(
              tooltip: 'Livres à valider',
              onPressed: () => context.push('/books/validation'),
              icon: Badge(
                label: Text('$draftCount'),
                child: const Icon(Icons.verified_outlined),
              ),
            ),
          if (canEdit) const SizedBox(width: 8),
          if (canEdit)
            FilledButton.tonalIcon(
              onPressed: () => context.push('/scan?mode=book-cover'),
              icon: const Icon(Icons.photo_camera_outlined),
              label: const Text('Scanner couverture'),
            ),
          if (canEdit) const SizedBox(width: 8),
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

          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 700) {
                return _BooksGrid(books: books, canEdit: canEdit);
              }
              return ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: 1,
                separatorBuilder: (_, __) => const SizedBox.shrink(),
                itemBuilder: (context, i) =>
                    _BooksCarousel(books: books, canEdit: canEdit),
              );
            },
          );
        },
      ),
    );
  }
}

class _BooksGrid extends StatelessWidget {
  final List<Book> books;
  final bool canEdit;

  const _BooksGrid({required this.books, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        childAspectRatio: 0.62,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: books.length,
      itemBuilder: (context, index) {
        final book = books[index];
        return _BookGridCard(book: book, canEdit: canEdit);
      },
    );
  }
}

class _BookGridCard extends StatelessWidget {
  final Book book;
  final bool canEdit;

  const _BookGridCard({required this.book, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCover = (book.urlCouverture ?? '').isNotEmpty;

    return GestureDetector(
      onTap: () => context.go(
        '/recipes?bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}&bookCoverUrl=${Uri.encodeQueryComponent(book.urlCouverture ?? '')}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant,
                      ),
                    ),
                    child: hasCover
                        ? CachedNetworkImage(
                            imageUrl: book.urlCouverture!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            placeholder: (_, __) => const Center(
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            errorWidget: (_, __, ___) => _NoCover(theme: theme),
                          )
                        : _NoCover(theme: theme),
                  ),
                ),
                if (canEdit)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: Material(
                      color: Colors.transparent,
                      child: _BookActionsMenu(book: book),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.titre,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _BooksCarousel extends StatefulWidget {
  final List<Book> books;
  final bool canEdit;

  const _BooksCarousel({required this.books, required this.canEdit});

  @override
  State<_BooksCarousel> createState() => _BooksCarouselState();
}

class _BooksCarouselState extends State<_BooksCarousel> {
  late final PageController _controller;
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.72);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 16),
        SizedBox(
          height: 420,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.books.length,
            onPageChanged: (value) => setState(() => _current = value),
            itemBuilder: (context, index) {
              final book = widget.books[index];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _BookCarouselCard(
                  book: book,
                  canEdit: widget.canEdit,
                  onLongPress: () => _showBookDetails(context, book),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 6,
          children: List.generate(widget.books.length, (index) {
            final selected = index == _current;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: selected ? 18 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(99),
              ),
            );
          }),
        ),
      ],
    );
  }

  void _showBookDetails(BuildContext context, Book book) {
    final details = <String>[
      'Titre: ${book.titre}',
      if ((book.sousTitre ?? '').isNotEmpty) 'Sous-titre: ${book.sousTitre}',
      'Auteur: ${book.auteur}',
      if ((book.editeur ?? '').isNotEmpty) 'Editeur: ${book.editeur}',
      if ((book.serie ?? '').isNotEmpty) 'Serie: ${book.serie}',
      if (book.annee != null) 'Annee: ${book.annee}',
      'Langue: ${book.langue.toUpperCase()}',
      if ((book.isbn ?? '').isNotEmpty) 'ISBN: ${book.isbn}',
      if ((book.description ?? '').isNotEmpty)
        'Description: ${book.description}',
      if (book.tags.isNotEmpty) 'Tags: ${book.tags.join(', ')}',
    ];

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Details du livre',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              ...details.map(
                (line) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(line),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookCarouselCard extends StatelessWidget {
  final Book book;
  final bool canEdit;
  final VoidCallback onLongPress;

  const _BookCarouselCard({
    required this.book,
    required this.canEdit,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCover = (book.urlCouverture ?? '').isNotEmpty;

    return GestureDetector(
      onLongPress: onLongPress,
      onTap: () => context.go(
        '/recipes?bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}&bookCoverUrl=${Uri.encodeQueryComponent(book.urlCouverture ?? '')}',
      ),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: theme.colorScheme.surfaceContainerHighest,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: hasCover
                      ? CachedNetworkImage(
                          imageUrl: book.urlCouverture!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          placeholder: (_, __) =>
                              const Center(child: CircularProgressIndicator()),
                          errorWidget: (_, __, ___) => _NoCover(theme: theme),
                        )
                      : _NoCover(theme: theme),
                ),

                if (canEdit)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.transparent,
                      child: _BookActionsMenu(book: book),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            book.titre,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _NoCover extends StatelessWidget {
  final ThemeData theme;

  const _NoCover({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Icon(
          Icons.menu_book_rounded,
          size: 74,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _BookActionsMenu extends ConsumerWidget {
  final Book book;

  const _BookActionsMenu({required this.book});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<_BookAction>(
          tooltip: 'Actions du livre',
          onSelected: (action) async {
            switch (action) {
              case _BookAction.scanDocument:
                context.push(
                  '/scan?mode=book-document&bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}',
                );
                break;
              case _BookAction.edit:
                context.push('/books/${book.id}/edit');
                break;
              case _BookAction.delete:
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Supprimer ce livre ?'),
                    content: Text(
                      'Le livre "${book.titre}" sera supprimé. Les recettes liées seront conservées mais détachées du livre.',
                    ),
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
                if (confirmed != true || !context.mounted) return;

                try {
                  await ref
                      .read(recipeRepositoryProvider)
                      .detachAllRecipesFromBook(book.id);
                  await ref.read(bookRepositoryProvider).deleteBook(book.id);

                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Livre supprimé. Les recettes restent disponibles en recettes libres.',
                      ),
                    ),
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
                }
                break;
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem<_BookAction>(
              value: _BookAction.scanDocument,
              child: Row(
                children: [
                  Icon(Icons.auto_stories_outlined),
                  SizedBox(width: 8),
                  Text('Scanner des pages du livre'),
                ],
              ),
            ),
            PopupMenuItem<_BookAction>(
              value: _BookAction.edit,
              child: Row(
                children: [
                  Icon(Icons.edit_outlined),
                  SizedBox(width: 8),
                  Text('Modifier'),
                ],
              ),
            ),
            PopupMenuItem<_BookAction>(
              value: _BookAction.delete,
              child: Row(
                children: [
                  Icon(Icons.delete_outline),
                  SizedBox(width: 8),
                  Text('Supprimer'),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

enum _BookAction { scanDocument, edit, delete }
