import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/book.dart';
import 'book_providers.dart';
import '../../../core/utils/context_extensions.dart';

class BookListScreen extends ConsumerStatefulWidget {
  const BookListScreen({super.key});

  @override
  ConsumerState<BookListScreen> createState() => _BookListScreenState();
}

class _BookListScreenState extends ConsumerState<BookListScreen> {
  final Set<String> _hiddenOwnerUids = {};

  Future<void> _openAddBookFlow() async {
    final choice = await showModalBottomSheet<_BookCreationMethod>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Scanner la couverture'),
              subtitle: const Text(
                'Créer un livre à partir d\'une photo de couverture.',
              ),
              onTap: () => Navigator.of(ctx).pop(_BookCreationMethod.scanCover),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Saisir manuellement'),
              subtitle: const Text(
                'Renseigner le livre sans passer par un scan.',
              ),
              onTap: () => Navigator.of(ctx).pop(_BookCreationMethod.manual),
            ),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) return;
    switch (choice) {
      case _BookCreationMethod.scanCover:
        context.push('/scan?mode=book-cover');
        break;
      case _BookCreationMethod.manual:
        context.push('/books/new');
        break;
    }
  }

  @override
  void initState() {
    super.initState();
    // Migration silencieuse : génère la couverture du livre IA s'il n'en a pas.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final user = ref.read(appUserProvider).value;
      if (user != null) {
        final repo = ref.read(bookRepositoryProvider);
        final displayName = user.displayName;
        unawaited(repo.ensureSystemBooks(user.uid, displayName));
      }
    });
  }

  void _toggleSection(String ownerUid) {
    setState(() {
      if (_hiddenOwnerUids.contains(ownerUid)) {
        _hiddenOwnerUids.remove(ownerUid);
      } else {
        _hiddenOwnerUids.add(ownerUid);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final myBooksAsync = ref.watch(myBooksProvider);
    final groupBooksAsync = ref.watch(groupMemberBooksProvider);
    final canEdit = ref.watch(canEditProvider);
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';

    // Group member books by ownerUid
    final booksByOwner = <String, List<Book>>{};
    for (final book in groupBooksAsync.value ?? []) {
      (booksByOwner[book.createdBy] ??= []).add(book);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bibliothèque'),
        actions: [
          if (canEdit)
            FilledButton.icon(
              onPressed: _openAddBookFlow,
              icon: const Icon(Icons.add),
              label: const Text('Ajouter un livre'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: myBooksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (myBooks) {
          final hasGroupBooks = booksByOwner.isNotEmpty;

          if (myBooks.isEmpty && !hasGroupBooks) {
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
                      onPressed: _openAddBookFlow,
                      icon: const Icon(Icons.add),
                      label: const Text('Ajouter un livre'),
                    ),
                ],
              ),
            );
          }

          return CustomScrollView(
            slivers: [
              // ── Mes livres ────────────────────────────────────────────────
              _SectionHeader(
                title: 'Mes livres',
                count: myBooks.length,
                expanded: !_hiddenOwnerUids.contains(myUid),
                onToggle: () => _toggleSection(myUid),
              ),
              if (!_hiddenOwnerUids.contains(myUid))
                myBooks.isEmpty
                    ? const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text('Aucun livre'),
                        ),
                      )
                    : _BooksGridSliver(books: myBooks, canEdit: canEdit),

              // ── Livres des membres ─────────────────────────────────────────
              for (final entry in booksByOwner.entries) ...[
                _MemberSectionHeader(
                  ownerUid: entry.key,
                  count: entry.value.length,
                  expanded: !_hiddenOwnerUids.contains(entry.key),
                  onToggle: () => _toggleSection(entry.key),
                ),
                if (!_hiddenOwnerUids.contains(entry.key))
                  _BooksGridSliver(books: entry.value, canEdit: false),
              ],

              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          );
        },
      ),
    );
  }
}

enum _BookCreationMethod { scanCover, manual }

// ── En-tête de section ─────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
          child: Row(
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Chip(
                label: Text('$count'),
                labelStyle: theme.textTheme.labelSmall,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              const Spacer(),
              Icon(
                expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemberSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _MemberSectionHeader({
    required this.ownerUid,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userByUidProvider(ownerUid));
    final name = userAsync.value?.displayName ?? '…';
    return _SectionHeader(
      title: 'Livres de $name',
      count: count,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

// ── Grille de livres (sliver) ──────────────────────────────────────────────────

class _BooksGridSliver extends StatelessWidget {
  final List<Book> books;
  final bool canEdit;

  const _BooksGridSliver({required this.books, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          childAspectRatio: 0.62,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) =>
              _BookGridCard(book: books[index], canEdit: canEdit),
          childCount: books.length,
        ),
      ),
    );
  }
}

// ── Carte livre (grille) ───────────────────────────────────────────────────────

class _BookGridCard extends StatelessWidget {
  final Book book;
  final bool canEdit;

  const _BookGridCard({required this.book, required this.canEdit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCover = (book.urlCouverture ?? '').isNotEmpty;

    return GestureDetector(
      onTap: () => context.push(
        '/recipes?bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}&bookCoverUrl=${Uri.encodeQueryComponent(book.urlCouverture ?? '')}${book.isLibresBook ? '&showUnattached=true' : ''}',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              // Clip.none pour que l'ombre portée déborde dans la gouttière
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        // Ombre ambiante douce
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.20),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                        // Ombre directionnelle (lumière venue du haut-gauche)
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.32),
                          blurRadius: 20,
                          offset: const Offset(6, 14),
                          spreadRadius: -4,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Stack(
                        children: [
                          // Image de couverture
                          Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: hasCover
                                ? CachedNetworkImage(
                                    imageUrl: book.urlCouverture!,
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                    height: double.infinity,
                                    filterQuality: FilterQuality.high,
                                    memCacheWidth: 660,
                                    placeholder: (_, _) => const Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    errorWidget: (_, _, _) =>
                                        _bookFallback(book, theme),
                                  )
                                : _bookFallback(book, theme),
                          ),
                          // Gradient tranche (spine) côté gauche
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.centerLeft,
                                  end: Alignment.centerRight,
                                  stops: const [0.0, 0.05, 0.12, 1.0],
                                  colors: [
                                    Colors.black.withValues(alpha: 0.40),
                                    Colors.black.withValues(alpha: 0.12),
                                    Colors.transparent,
                                    Colors.transparent,
                                  ],
                                ),
                              ),
                            ),
                          ),
                          // Léger vernis (reflet lumière en haut)
                          Positioned.fill(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: const [0.0, 0.30, 1.0],
                                  colors: [
                                    Colors.white.withValues(alpha: 0.10),
                                    Colors.transparent,
                                    Colors.black.withValues(alpha: 0.04),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (canEdit)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: _BookActionsMenu(book: book),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: Text(
              book.titre,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
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
                child: _BookGridCard(book: book, canEdit: widget.canEdit),
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
}

/// Retourne le widget fallback pour la couverture d'un livre :
/// image asset pour les livres système, icône générique sinon.
Widget _bookFallback(Book book, ThemeData theme) {
  final asset = book.defaultCoverAsset;
  if (asset != null) {
    return Image.asset(
      asset,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
    );
  }
  return _NoCover(theme: theme);
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
          size: 48,
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
          icon: const Icon(Icons.more_vert, color: Colors.white, size: 20),
          onSelected: (action) async {
            switch (action) {
              case _BookAction.scanPage:
                context.push(
                  '/scan?mode=recipe&bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}',
                );
                break;
              case _BookAction.scanDocument:
                context.push(
                  '/scan?mode=book-document&bookId=${book.id}&bookTitre=${Uri.encodeQueryComponent(book.titre)}',
                );
                break;
              case _BookAction.edit:
                context.push('/books/${book.id}/edit');
                break;
              case _BookAction.delete:
                final mode = await showDialog<_DeleteBookMode>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Supprimer ce livre ?'),
                    content: Text(
                      'Que faire des recettes liées à "${book.titre}" ?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Annuler'),
                      ),
                      OutlinedButton(
                        onPressed: () =>
                            Navigator.pop(ctx, _DeleteBookMode.detach),
                        child: const Text('Détacher les recettes'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(ctx).colorScheme.error,
                        ),
                        onPressed: () =>
                            Navigator.pop(ctx, _DeleteBookMode.deleteAll),
                        child: const Text('Supprimer aussi'),
                      ),
                    ],
                  ),
                );
                if (mode == null || !context.mounted) return;

                try {
                  if (mode == _DeleteBookMode.deleteAll) {
                    await ref
                        .read(recipeRepositoryProvider)
                        .deleteAllRecipesOfBook(book.id);
                  } else {
                    await ref
                        .read(recipeRepositoryProvider)
                        .detachAllRecipesFromBook(book.id);
                  }
                  await ref.read(bookRepositoryProvider).deleteBook(book.id);

                  if (!context.mounted) return;
                  context.showSuccessSnackBar(
                    mode == _DeleteBookMode.deleteAll
                        ? 'Livre et recettes supprimés.'
                        : 'Livre supprimé. Les recettes restent disponibles en recettes libres.',
                  );
                } catch (e) {
                  if (!context.mounted) return;
                  context.showErrorSnackBar('Erreur : $e');
                }
                break;
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem<_BookAction>(
              value: _BookAction.scanPage,
              child: Row(
                children: [
                  Icon(Icons.photo_camera_outlined),
                  SizedBox(width: 8),
                  Text('Scanner une recette'),
                ],
              ),
            ),
            if (!book.isSystemBook)
              const PopupMenuItem<_BookAction>(
                value: _BookAction.scanDocument,
                child: Row(
                  children: [
                    Icon(Icons.auto_stories_outlined),
                    SizedBox(width: 8),
                    Text('Importer un livre complet'),
                  ],
                ),
              ),
            const PopupMenuItem<_BookAction>(
              value: _BookAction.edit,
              child: Row(
                children: [
                  Icon(Icons.edit_outlined),
                  SizedBox(width: 8),
                  Text('Modifier'),
                ],
              ),
            ),
            if (!book.isSystemBook)
              const PopupMenuItem<_BookAction>(
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

enum _BookAction { scanPage, scanDocument, edit, delete }

enum _DeleteBookMode { detach, deleteAll }
