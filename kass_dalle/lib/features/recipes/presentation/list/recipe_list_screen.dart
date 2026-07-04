import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../books/domain/book.dart';
import '../../../books/presentation/book_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../source_viewer.dart';
import 'recipe_list_body.dart';
import 'recipe_list_widgets.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/services/book_pdf_export.dart';
import '../../../../core/services/recipe_pdf_export.dart';
import '../../../../core/utils/platform_utils.dart';

enum _BookMenuAction { edit, attach, exportPdf, delete }

enum _DeleteBookMode { detach, deleteAll }

class RecipeListScreen extends ConsumerStatefulWidget {
  final String? bookId;
  final String? bookTitre;
  final String? bookCoverUrl;
  final bool showUnattached;
  const RecipeListScreen({
    super.key,
    this.bookId,
    this.bookTitre,
    this.bookCoverUrl,
    this.showUnattached = false,
  });

  @override
  ConsumerState<RecipeListScreen> createState() => _RecipeListScreenState();
}

class _RecipeListScreenState extends ConsumerState<RecipeListScreen> {
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  void _onItemSelect(String id) {
    setState(() {
      if (!_selectionMode) _selectionMode = true;
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  void _exitSelectionMode() => setState(() {
    _selectionMode = false;
    _selectedIds.clear();
  });

  Future<void> _deleteSelected(BuildContext context) async {
    final count = _selectedIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer la sélection ?'),
        content: Text(
          '$count élément(s) sera/seront supprimé(s) définitivement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final repo = ref.read(recipeRepositoryProvider);
    final ids = _selectedIds.toList();
    for (final id in ids) {
      try {
        await repo.deleteRecipe(id);
      } catch (_) {}
    }
    _exitSelectionMode();
    if (!context.mounted) return;
    context.showSuccessSnackBar('$count élément(s) supprimé(s).');
  }

  @override
  Widget build(BuildContext context) {
    final canEdit = ref.watch(canEditProvider);
    final currentUser = ref.watch(appUserProvider).value;
    final inBookContext = (widget.bookId ?? '').isNotEmpty;

    // Badge "à valider" selon le contexte
    final draftCount = inBookContext
        ? ref.watch(draftsByBookCountProvider(widget.bookId!)).value ?? 0
        : ref.watch(draftsUnattachedCountProvider).value ?? 0;

    final AsyncValue<List<Recipe>> recipesAsync = inBookContext
        ? (widget.showUnattached
              ? ref.watch(libresRecipesProvider(widget.bookId!))
              : ref.watch(allPagesByBookProvider(widget.bookId!)))
        : ref.watch(unattachedRecipesProvider);

    // Chargement des métadonnées du livre pour la section "À propos"
    final bookAsync = inBookContext
        ? ref.watch(bookByIdProvider(widget.bookId!))
        : const AsyncData<Book?>(null);
    final book = bookAsync.value;
    final ownerUid = book?.createdBy;
    final isOtherUsersBook =
        inBookContext &&
        ownerUid != null &&
        ownerUid.isNotEmpty &&
        ownerUid != currentUser?.uid;
    final ownerAsync = isOtherUsersBook
        ? ref.watch(userByUidProvider(ownerUid))
        : const AsyncData(null);
    final ownerName = ownerAsync.asData?.value?.displayName.trim();
    final baseBookTitle =
        book?.titre ?? widget.bookTitre ?? 'Recettes du livre';
    final bookTitle = (ownerName != null && ownerName.isNotEmpty)
        ? '$baseBookTitle ($ownerName)'
        : baseBookTitle;

    final hasCover = inBookContext && (widget.bookCoverUrl ?? '').isNotEmpty;

    final titleWidget = inBookContext
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasCover) ...[
                GestureDetector(
                  onTap: () => _showCoverZoom(context, widget.bookCoverUrl!),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.network(
                      widget.bookCoverUrl!,
                      width: 32,
                      height: 44,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Flexible(
                child: Text(
                  bookTitle,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ],
          )
        : const Text('Recettes libres');

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Annuler la sélection',
                onPressed: _exitSelectionMode,
              )
            : null,
        title: _selectionMode
            ? Text('${_selectedIds.length} sélectionné(s)')
            : titleWidget,
        backgroundColor: _selectionMode
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
        actions: _selectionMode
            ? [
                if (_selectedIds.isNotEmpty)
                  IconButton(
                    tooltip: 'Supprimer la sélection',
                    icon: Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    onPressed: () => _deleteSelected(context),
                  ),
              ]
            : [
                if (draftCount > 0)
                  IconButton(
                    tooltip: 'Recettes à valider',
                    onPressed: () => context.push('/drafts'),
                    icon: Badge(
                      label: Text('$draftCount'),
                      child: const Icon(Icons.edit_note_outlined),
                    ),
                  ),
                if (inBookContext && canEdit)
                  IconButton(
                    tooltip:
                        'Ajouter des pages dans ce livre à partir d'
                        'une photo ou d'
                        'un fichier',
                    icon: const Icon(Icons.photo_camera_outlined),
                    onPressed: () => _goToScan(context),
                  ),
                if (inBookContext &&
                    (bookAsync.value?.sourceFileUrl ?? '').isNotEmpty)
                  SourceViewerButton(
                    sourceFileUrl: bookAsync.value?.sourceFileUrl,
                    sourceFileName: bookAsync.value?.sourceFileName,
                  ),
                if (inBookContext && canEdit)
                  PopupMenuButton<_BookMenuAction>(
                    tooltip: 'Plus d\'options',
                    onSelected: (action) =>
                        _onBookMenuAction(context, action, book: book),
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: _BookMenuAction.edit,
                        child: ListTile(
                          leading: Icon(Icons.edit_outlined),
                          title: Text('Modifier le livre'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _BookMenuAction.attach,
                        child: ListTile(
                          leading: Icon(Icons.link_outlined),
                          title: Text('Attacher des recettes validées'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _BookMenuAction.exportPdf,
                        child: ListTile(
                          leading: Icon(Icons.picture_as_pdf_outlined),
                          title: Text('Exporter le livre en PDF'),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      if (bookAsync.value?.isSystemBook != true) ...[
                        const PopupMenuDivider(),
                        PopupMenuItem(
                          value: _BookMenuAction.delete,
                          child: ListTile(
                            leading: Icon(
                              Icons.delete_outline,
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                            title: Text(
                              'Supprimer le livre',
                              style: TextStyle(
                                color: Theme.of(ctx).colorScheme.error,
                              ),
                            ),
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ],
                  ),
              ],
      ),
      body: inBookContext
          ? RecipeListBookBody(
              book: bookAsync.value,
              bookId: widget.bookId,
              bookTitre: book?.titre ?? widget.bookTitre,
              bookCoverUrl: book?.urlCouverture ?? widget.bookCoverUrl,
              showUnattached: widget.showUnattached,
              recipesAsync: recipesAsync,
              canEdit: canEdit,
              selectionMode: _selectionMode,
              selectedIds: _selectedIds,
              onItemSelect: _onItemSelect,
            )
          : RecipeListFreeBody(
              myRecipesAsync: recipesAsync,
              canEdit: canEdit,
              selectionMode: _selectionMode,
              selectedIds: _selectedIds,
              onItemSelect: _onItemSelect,
            ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => inBookContext
                  ? _showAddActions(context)
                  : _showAddFreeActions(context),
              icon: const Icon(Icons.add),
              label: const Text('Ajouter'),
            )
          : null,
    );
  }

  // ── Livre : corps avec sections rétractables ─────────────────────────────

  Future<void> _onBookMenuAction(
    BuildContext context,
    _BookMenuAction action, {
    Book? book,
  }) async {
    switch (action) {
      case _BookMenuAction.edit:
        context.push('/books/${widget.bookId}/edit');
        break;
      case _BookMenuAction.attach:
        _showAttachDialog(context);
        break;
      case _BookMenuAction.exportPdf:
        await _exportBookPdf(context, book);
        break;
      case _BookMenuAction.delete:
        await _confirmDeleteBook(context);
        break;
    }
  }

  Future<void> _exportBookPdf(BuildContext context, Book? book) async {
    final bookId = widget.bookId;
    if (bookId == null || bookId.isEmpty) return;

    context.showSnackBar(
      'Generation du PDF du livre...',
      duration: const Duration(seconds: 2),
    );

    try {
      final pages = await ref
          .read(recipeRepositoryProvider)
          .getAllValidatedPagesByBook(bookId);

      if (!context.mounted) return;
      if (pages.isEmpty) {
        context.showSnackBar('Aucune page a exporter dans ce livre.');
        return;
      }

      final title = book?.titre ?? widget.bookTitre ?? 'Livre';
      final author = book?.auteur;
      final result = await exportBookToPdf(
        bookTitle: title,
        bookAuthor: author,
        pages: pages,
      );

      if (!context.mounted) return;
      context.showSnackBar(
        'Livre exporte en PDF',
        duration: const Duration(seconds: 8),
        action: PlatformUtils.isMobile
            ? SnackBarAction(
                label: 'Ouvrir',
                onPressed: () => openPdf(result.bytes, result.filename),
              )
            : null,
      );
    } catch (e) {
      if (!context.mounted) return;
      context.showErrorSnackBar('Erreur export PDF : $e');
    }
  }

  Future<void> _confirmDeleteBook(BuildContext context) async {
    final bookId = widget.bookId!;
    final bookTitre = widget.bookTitre ?? 'ce livre';
    final mode = await showDialog<_DeleteBookMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce livre ?'),
        content: Text('Que faire des recettes liées à "$bookTitre" ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Annuler'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, _DeleteBookMode.detach),
            child: const Text('Détacher les recettes'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, _DeleteBookMode.deleteAll),
            child: const Text('Supprimer aussi'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;
    try {
      if (mode == _DeleteBookMode.deleteAll) {
        await ref.read(recipeRepositoryProvider).deleteAllRecipesOfBook(bookId);
      } else {
        await ref
            .read(recipeRepositoryProvider)
            .detachAllRecipesFromBook(bookId);
      }
      await ref.read(bookRepositoryProvider).deleteBook(bookId);
      if (!mounted) return;
      this.context.go('/');
      this.context.showSuccessSnackBar(
        mode == _DeleteBookMode.deleteAll
            ? 'Livre et recettes supprimés.'
            : 'Livre supprimé. Les recettes restent disponibles en recettes libres.',
      );
    } catch (e) {
      if (!mounted) return;
      this.context.showErrorSnackBar('Erreur : $e');
    }
  }

  void _showCoverZoom(BuildContext context, String coverUrl) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 6,
                child: CachedNetworkImage(
                  imageUrl: coverUrl,
                  fit: BoxFit.contain,
                  placeholder: (_, _) => const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                  errorWidget: (_, _, _) => const Icon(
                    Icons.broken_image,
                    size: 64,
                    color: Colors.white54,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 16,
              right: 16,
              child: IconButton.filled(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goToScan(BuildContext context) {
    context.go(
      '/scan?mode=recipe&bookId=${widget.bookId}&bookTitre=${Uri.encodeQueryComponent(widget.bookTitre ?? '')}',
    );
  }

  void _goToScanFree(BuildContext context) {
    context.go('/scan?mode=recipe');
  }

  void _showAddFreeActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Scanner / importer un fichier'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _goToScanFree(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Saisie manuelle'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go('/recipes/new');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showAttachDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AttachRecipesDialog(
        bookId: widget.bookId!,
        bookTitre: widget.bookTitre ?? 'Livre',
      ),
    );
  }

  void _showAddActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Ajouter des pages'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _goToScan(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('Saisie manuelle'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                context.go(
                  '/recipes/new'
                  '?bookId=${Uri.encodeQueryComponent(widget.bookId!)}'
                  '&bookTitre=${Uri.encodeQueryComponent(widget.bookTitre ?? '')}',
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.link_outlined),
              title: const Text('Attacher des recettes validées'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showAttachDialog(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── En-têtes de section recettes libres ───────────────────────────────────────
