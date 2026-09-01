import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/book.dart';
import '../domain/book_order.dart';

/// Une seule définition de grille : la version réordonnable doit poser les
/// couvertures exactement comme la version figée, sinon le rangement change
/// d'allure d'une section à l'autre.
const kBooksGridDelegate = SliverGridDelegateWithMaxCrossAxisExtent(
  maxCrossAxisExtent: 220,
  childAspectRatio: 0.62,
  crossAxisSpacing: 12,
  mainAxisSpacing: 12,
);

/// Grille de livres que l'on range au doigt.
///
/// Flutter n'offre pas de grille réordonnable : `ReorderableListView` range des
/// lignes, pas des cases. Le geste est donc monté à la main — un
/// [LongPressDraggable] par couverture, un [DragTarget] par emplacement.
///
/// **La liste ne bouge pas pendant le glissement.** C'est la règle qui rend le
/// geste fiable, et la version qui décalait les voisines en direct l'a apprise
/// à ses dépens : chaque décalage reconstruisait les cases sous le doigt, si
/// bien que la cible changeait d'identité en cours de route. Le premier
/// déplacement passait, les suivants partaient en cafouillage. Ici rien ne
/// bouge tant que le doigt est posé : l'emplacement visé s'éclaire, et le
/// rangement n'a lieu qu'au lâcher.
class ReorderableBooksGridSliver extends StatefulWidget {
  final List<Book> books;

  /// Rendu d'une couverture. Passé de l'extérieur : la grille sait ranger, pas
  /// dessiner.
  final Widget Function(BuildContext context, Book book) itemBuilder;

  /// Faux pour une grille en lecture seule (livres d'un autre membre).
  final bool enabled;

  /// Appelé au lâcher, avec l'ordre complet et définitif.
  final ValueChanged<List<Book>> onReorder;

  final EdgeInsetsGeometry padding;

  const ReorderableBooksGridSliver({
    super.key,
    required this.books,
    required this.itemBuilder,
    required this.onReorder,
    this.enabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
  });

  @override
  State<ReorderableBooksGridSliver> createState() =>
      _ReorderableBooksGridSliverState();
}

class _ReorderableBooksGridSliverState
    extends State<ReorderableBooksGridSliver> {
  /// Bande, en pixels, où le glissement entraîne le défilement de la page.
  static const double _autoScrollZone = 72;
  static const double _autoScrollStep = 12;

  late List<Book> _books = List.of(widget.books);

  /// Livre en cours de déplacement. Écrit **sans** `setState` : reconstruire la
  /// grille pendant un glissement est exactement ce qu'on cherche à éviter.
  String? _draggingId;

  /// Ordre écrit mais pas encore renvoyé par Firestore.
  List<String>? _pendingOrder;

  Timer? _autoScrollTimer;
  double _autoScrollDirection = 0;

  @override
  void didUpdateWidget(covariant ReorderableBooksGridSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pendant un glissement, la liste locale fait foi : adopter celle du flux
    // couperait le geste en cours.
    if (_draggingId != null) return;

    final pending = _pendingOrder;
    if (pending != null &&
        _sameOrder(widget.books, applyBookOrder(widget.books, pending))) {
      _pendingOrder = null;
    }
    final incoming = _pendingOrder == null
        ? widget.books
        : applyBookOrder(widget.books, _pendingOrder!);
    // Le CONTENU compte autant que l'ordre.
    //
    // La comparaison ne portait que sur les identifiants. Une couverture
    // remplacée, un titre corrigé, un livre validé ne déplacent rien : la
    // grille gardait donc sa copie locale et continuait d'afficher l'ancienne
    // valeur. Le flux Firestore livrait la bonne, personne ne la regardait, et
    // aucune erreur ne le disait.
    if (!_sameBooks(_books, incoming)) {
      setState(() => _books = List.of(incoming));
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    super.dispose();
  }

  /// Même ordre **et** mêmes instances.
  ///
  /// `identical` suffit et ne coûte rien : chaque instantané Firestore
  /// reconstruit ses `Book`, tandis qu'un simple rebuild du parent rend les
  /// mêmes instances. Comparer champ par champ demanderait d'énumérer les
  /// vingt champs du modèle, et d'y penser à chaque champ ajouté.
  static bool _sameBooks(List<Book> a, List<Book> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  static bool _sameOrder(List<Book> a, List<Book> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Le livre déplacé prend la place de celui sur lequel on l'a lâché.
  void _dropOnto(String draggedId, String targetId) {
    final from = _books.indexWhere((b) => b.id == draggedId);
    final to = _books.indexWhere((b) => b.id == targetId);
    if (from < 0 || to < 0 || from == to) return;

    final reordered = List.of(_books);
    reordered.insert(to, reordered.removeAt(from));

    final previous = _pendingOrder ?? bookOrderIds(widget.books);
    final ids = bookOrderIds(reordered);
    setState(() => _books = reordered);
    if (_sameIds(ids, previous)) return;

    _pendingOrder = ids;
    widget.onReorder(reordered);
  }

  // ── Défilement automatique en bord d'écran ────────────────────────────────

  void _autoScrollIfNeeded(Offset globalPosition) {
    final scrollable = Scrollable.maybeOf(context);
    final box = scrollable?.context.findRenderObject();
    if (scrollable == null || box is! RenderBox) {
      _stopAutoScroll();
      return;
    }
    final dy = box.globalToLocal(globalPosition).dy;
    final double direction;
    if (dy < _autoScrollZone) {
      direction = -1;
    } else if (dy > box.size.height - _autoScrollZone) {
      direction = 1;
    } else {
      _stopAutoScroll();
      return;
    }
    if (_autoScrollTimer != null && _autoScrollDirection == direction) return;

    _stopAutoScroll();
    _autoScrollDirection = direction;
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final position = scrollable.position;
      final target = (position.pixels + direction * _autoScrollStep).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (target != position.pixels) position.jumpTo(target);
    });
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _autoScrollDirection = 0;
  }

  @override
  Widget build(BuildContext context) {
    return SliverPadding(
      padding: widget.padding,
      sliver: SliverGrid(
        gridDelegate: kBooksGridDelegate,
        delegate: SliverChildBuilderDelegate(
          _buildCell,
          childCount: _books.length,
          // Sans cette clé et sa recherche, un livre déplacé changerait de
          // case sans que son élément suive : le rangement se reporterait sur
          // la couverture voisine.
          findChildIndexCallback: (key) {
            if (key is! ValueKey<String>) return null;
            final index = _books.indexWhere((b) => b.id == key.value);
            return index < 0 ? null : index;
          },
        ),
      ),
    );
  }

  Widget _buildCell(BuildContext context, int index) {
    final book = _books[index];
    final child = widget.itemBuilder(context, book);

    if (!widget.enabled || _books.length < 2) {
      return KeyedSubtree(key: ValueKey(book.id), child: child);
    }

    return KeyedSubtree(
      key: ValueKey(book.id),
      child: LayoutBuilder(
        builder: (context, constraints) => DragTarget<String>(
          onWillAcceptWithDetails: (details) => details.data != book.id,
          onAcceptWithDetails: (details) => _dropOnto(details.data, book.id),
          builder: (context, candidate, rejected) => _DropHighlight(
            active: candidate.isNotEmpty,
            child: LongPressDraggable<String>(
              data: book.id,
              hapticFeedbackOnStart: true,
              feedback: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  child: Opacity(
                    opacity: 0.92,
                    child: IgnorePointer(
                      child: widget.itemBuilder(context, book),
                    ),
                  ),
                ),
              ),
              childWhenDragging: const _EmptyBookSlot(),
              onDragStarted: () => _draggingId = book.id,
              onDragUpdate: (details) =>
                  _autoScrollIfNeeded(details.globalPosition),
              onDragEnd: (_) => _endDrag(),
              onDraggableCanceled: (_, _) => _endDrag(),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  void _endDrag() {
    _stopAutoScroll();
    _draggingId = null;
  }
}

/// Liseré posé sur l'emplacement visé — sans lui, rien ne dit où le livre va
/// se ranger.
class _DropHighlight extends StatelessWidget {
  final bool active;
  final Widget child;

  const _DropHighlight({required this.active, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.primary, width: 2),
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
      ),
      child: child,
    );
  }
}

/// Emplacement laissé libre par la couverture en cours de déplacement.
class _EmptyBookSlot extends StatelessWidget {
  const _EmptyBookSlot();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: theme.colorScheme.surfaceContainerHighest.withValues(
                alpha: 0.4,
              ),
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
          ),
        ),
        const SizedBox(height: 6),
        const SizedBox(height: 36),
      ],
    );
  }
}
