import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/book.dart';
import '../domain/book_order.dart';
import 'book_providers.dart';
import 'delete_book_flow.dart';
import 'export_my_books_flow.dart';
import 'reorderable_books_grid.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_providers.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/widgets/app_network_image.dart';

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
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Ajouter à partir d\'un PDF ou d\'un EPUB'),
              subtitle: const Text(
                'Créer le livre depuis le fichier, puis en extraire les recettes.',
              ),
              onTap: () => Navigator.of(ctx).pop(_BookCreationMethod.fromFile),
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
      case _BookCreationMethod.fromFile:
        context.push('/scan?mode=book-document');
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
      // Un lecteur ne crée pas de recette : il n'a pas besoin des livres
      // système qui les reçoivent, et les règles lui en refusent la création.
      if (user != null && user.canEdit) {
        final repo = ref.read(bookRepositoryProvider);
        final displayName = user.displayName;
        final gemini = ref.read(geminiServiceProvider);
        unawaited(
          repo.ensureSystemBooks(
            user.uid,
            displayName,
            ensureWebBook: gemini.ensureWebBook,
          ),
        );
      }
    });
  }

  /// Recharge la bibliothèque : geste « tirer pour rafraîchir » et bouton
  /// Réessayer passent par ici. On attend la première valeur, sinon
  /// l'indicateur disparaît avant que les livres n'arrivent.
  Future<void> _refreshBooks() async {
    ref.invalidate(myBooksProvider);
    ref.invalidate(bookOrderProvider);
    ref.invalidate(groupMemberBooksProvider);
    await ref.read(myBooksProvider.future);
  }

  /// Enregistre le rangement choisi au doigt.
  ///
  /// L'ordre est une préférence de lecteur : il s'écrit sous l'utilisateur, et
  /// jamais dans les documents `books`, que toute la famille partage.
  Future<void> _saveBookOrder(List<Book> ordered) async {
    final uid = ref.read(appUserProvider).value?.uid;
    if (uid == null) return;
    try {
      await ref
          .read(bookRepositoryProvider)
          .saveBookOrder(uid, bookOrderIds(ordered));
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'bookListScreen.saveBookOrder',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar(
        "L'ordre des livres n'a pas pu être enregistré : $e",
      );
    }
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
    final myBooksAsync = ref.watch(myBooksOrderedProvider);
    final groupBooksAsync = ref.watch(groupMemberBooksProvider);
    final canEdit = ref.watch(canEditProvider);
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';

    // Group member books by ownerUid
    final booksByOwner = <String, List<Book>>{};
    for (final book in groupBooksAsync.value ?? []) {
      (booksByOwner[book.createdBy] ??= []).add(book);
    }

    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return Scaffold(
      // « Ajouter » vit en bas à droite dans Recettes, Planning et Groupes.
      // Ici seul, il vivait en haut de la barre : le geste le plus fréquent
      // de l'application changeait de place selon l'écran.
      appBar: AppBar(
        title: const Text('Bibliothèque'),
        actions: [
          if (myBooksAsync.value?.isNotEmpty ?? false)
            IconButton(
              tooltip: 'Exporter mes livres en PDF',
              icon: const Icon(Icons.picture_as_pdf_outlined),
              onPressed: () => exportMyBooksAsZip(
                context: context,
                ref: ref,
                books: myBooksAsync.value!,
              ),
            ),
          // Le « tirer pour rafraîchir » du corps n'existe pas à la souris.
          if (isWide)
            IconButton(
              tooltip: 'Actualiser la bibliothèque',
              icon: const Icon(Icons.refresh),
              onPressed: _refreshBooks,
            ),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: _openAddBookFlow,
              icon: const Icon(Icons.add),
              label: const Text('Ajouter un livre'),
            )
          : null,
      body: RefreshIndicator(
        onRefresh: _refreshBooks,
        child: myBooksAsync.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(error: e, onRetry: _refreshBooks),
          data: (myBooks) {
            final hasGroupBooks = booksByOwner.isNotEmpty;

            if (myBooks.isEmpty && !hasGroupBooks) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.library_books_outlined,
                      size: AppIconSize.hero,
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
                  hint: canEdit && myBooks.length > 1
                      ? 'Maintenez un livre pour le déplacer'
                      : null,
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
                      : ReorderableBooksGridSliver(
                          books: myBooks,
                          enabled: canEdit,
                          onReorder: _saveBookOrder,
                          itemBuilder: (_, book) =>
                              _BookGridCard(book: book, canEdit: canEdit),
                        ),

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
      ),
    );
  }
}

enum _BookCreationMethod { scanCover, fromFile, manual }

// ── En-tête de section ─────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  /// Indication discrète affichée à droite du titre — le glisser-déposer ne
  /// s'annonce autrement par rien à l'écran.
  final String? hint;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.hint,
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
              Expanded(
                child: Text(
                  hint ?? '',
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
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
    final name = ref.watch(memberNameProvider(ownerUid));
    return _SectionHeader(
      title: switch (name) {
        null => 'Livres de …',
        UserProfile.fallbackName => 'Livres d\'un membre',
        _ => 'Livres de $name',
      },
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
        gridDelegate: kBooksGridDelegate,
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
                          // Image de couverture. `AppNetworkImage` n'expose
                          // pas de semanticLabel : c'est le Semantics qui
                          // donne à la vignette un nom pour TalkBack, sans
                          // quoi la grille n'est qu'une suite d'images muettes.
                          Semantics(
                            image: true,
                            label: 'Couverture de ${book.titre}',
                            child: Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: hasCover
                                  ? AppNetworkImage(
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
                // Un livre privé ne se distingue d'un autre par rien : même
                // couverture, même place dans la grille. Le cadenas est le seul
                // moyen de savoir, avant d'y ranger une recette, qu'on la
                // soustrait à la famille.
                if (book.isPrivate)
                  Positioned(
                    top: 4,
                    left: 4,
                    child: Tooltip(
                      message: 'Livre privé — vous seul le voyez',
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.lock_outline,
                            size: 16,
                            color: Colors.white,
                            semanticLabel: 'Livre privé',
                          ),
                        ),
                      ),
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
          Icons.menu_book_outlined,
          size: AppIconSize.hero,
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
          icon: const Icon(
            Icons.more_vert,
            color: Colors.white,
            size: AppIconSize.small,
          ),
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
                await confirmAndDeleteBook(
                  context: context,
                  ref: ref,
                  bookId: book.id,
                  bookTitre: book.titre,
                  bookIsPrivate: book.isPrivate,
                );
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
