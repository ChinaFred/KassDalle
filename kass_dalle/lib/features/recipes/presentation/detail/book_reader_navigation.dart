import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/recipe.dart';
import '../../../../core/theme/app_icon_size.dart';

class BookReadingContext {
  final String? bookId;
  final String? bookTitre;
  final String? bookCoverUrl;
  final bool showUnattached;

  const BookReadingContext({
    this.bookId,
    this.bookTitre,
    this.bookCoverUrl,
    this.showUnattached = false,
  });

  bool get isEnabled => (bookId ?? '').isNotEmpty;

  Map<String, String> toQueryParameters() => {
    if ((bookId ?? '').isNotEmpty) 'bookId': bookId!,
    if ((bookTitre ?? '').isNotEmpty) 'bookTitre': bookTitre!,
    if ((bookCoverUrl ?? '').isNotEmpty) 'bookCoverUrl': bookCoverUrl!,
    if (showUnattached) 'showUnattached': 'true',
  };
}

class BookReadingPosition {
  final List<Recipe> items;
  final int currentIndex;

  const BookReadingPosition({required this.items, required this.currentIndex});

  Recipe get current => items[currentIndex];
  Recipe? get previous => currentIndex > 0 ? items[currentIndex - 1] : null;
  Recipe? get next =>
      currentIndex + 1 < items.length ? items[currentIndex + 1] : null;
  int get total => items.length;
  String get progressLabel => '${currentIndex + 1} / $total';
}

BookReadingPosition? resolveBookReadingPosition(
  List<Recipe> items,
  String currentId,
) {
  if (items.isEmpty) return null;
  final currentIndex = items.indexWhere((item) => item.id == currentId);
  if (currentIndex < 0) return null;
  return BookReadingPosition(items: items, currentIndex: currentIndex);
}

String buildReaderRecipeLocation(
  String recipeId,
  BookReadingContext context, {
  bool scrollToAnnotations = false,
}) {
  final query = context.toQueryParameters();
  if (scrollToAnnotations) query['anchor'] = 'annotations';
  return Uri(
    path: '/recipes/$recipeId',
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

String buildReaderBookPageLocation(String pageId, BookReadingContext context) {
  final query = context.toQueryParameters();
  return Uri(
    path: '/book-pages/$pageId',
    queryParameters: query.isEmpty ? null : query,
  ).toString();
}

class BookReaderViewport extends StatelessWidget {
  final Widget child;
  final BookReadingPosition? position;
  final ValueChanged<Recipe> onOpen;
  final bool enableNavigation;

  const BookReaderViewport({
    super.key,
    required this.child,
    required this.position,
    required this.onOpen,
    this.enableNavigation = true,
  });

  @override
  Widget build(BuildContext context) {
    final position = this.position;
    if (position == null || position.total < 2) return child;

    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowLeft):
            _BookReaderPreviousIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight): _BookReaderNextIntent(),
      },
      child: Actions(
        actions: {
          _BookReaderPreviousIntent: CallbackAction<_BookReaderPreviousIntent>(
            onInvoke: (_) {
              final previous = position.previous;
              if (previous != null) onOpen(previous);
              return null;
            },
          ),
          _BookReaderNextIntent: CallbackAction<_BookReaderNextIntent>(
            onInvoke: (_) {
              final next = position.next;
              if (next != null) onOpen(next);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: enableNavigation,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragEnd: !enableNavigation
                ? null
                : (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (velocity <= -250 && position.next != null) {
                      onOpen(position.next!);
                    } else if (velocity >= 250 && position.previous != null) {
                      onOpen(position.previous!);
                    }
                  },
            child: child,
          ),
        ),
      ),
    );
  }
}

class BookReaderBottomBar extends StatelessWidget {
  final BookReadingPosition? position;
  final ValueChanged<Recipe> onOpen;
  final bool showProgressChip;

  const BookReaderBottomBar({
    super.key,
    required this.position,
    required this.onOpen,
    this.showProgressChip = true,
  });

  @override
  Widget build(BuildContext context) {
    final position = this.position;
    if (position == null || position.total < 2) return const SizedBox.shrink();

    return SafeArea(
      top: false,
      child: Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: position.previous == null
                      ? null
                      : () => onOpen(position.previous!),
                  icon: const Icon(Icons.chevron_left),
                  label: Text(
                    position.previous?.titre ?? 'Début du livre',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (showProgressChip)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Chip(
                    avatar: const Icon(
                      Icons.menu_book_outlined,
                      size: AppIconSize.inline,
                    ),
                    label: Text(position.progressLabel),
                    visualDensity: VisualDensity.compact,
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: position.next == null
                      ? null
                      : () => onOpen(position.next!),
                  icon: const Icon(Icons.chevron_right),
                  iconAlignment: IconAlignment.end,
                  label: Text(
                    position.next?.titre ?? 'Fin du livre',
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookReaderPreviousIntent extends Intent {
  const _BookReaderPreviousIntent();
}

class _BookReaderNextIntent extends Intent {
  const _BookReaderNextIntent();
}
