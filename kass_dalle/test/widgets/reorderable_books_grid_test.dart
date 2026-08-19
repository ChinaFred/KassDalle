import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/reorderable_books_grid.dart';

Book _book(String id) {
  final now = DateTime(2026, 1, 1);
  return Book(
    id: id,
    titre: id,
    auteur: 'Kassbi',
    langue: 'fr',
    tags: const [],
    createdBy: 'uid',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  /// Ordre des couvertures tel qu'il est **posé à l'écran**, et non tel que la
  /// grille le croit : c'est la position peinte qui trahit un rangement raté.
  List<String> visibleOrder(WidgetTester tester, List<String> ids) {
    final placed = <String, double>{};
    for (final id in ids) {
      final finder = find.text(id);
      if (finder.evaluate().isEmpty) continue;
      placed[id] = tester.getTopLeft(finder.first).dx;
    }
    final sorted = placed.keys.toList()
      ..sort((a, b) => placed[a]!.compareTo(placed[b]!));
    return sorted;
  }

  Future<void> dragOnto(WidgetTester tester, String from, String onto) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(from)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    // Deux temps : le premier lève la couverture, le second la pose sur sa
    // cible. Un seul saut n'entre jamais dans l'emplacement visé.
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text(onto).last));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Widget harness(List<Book> books, ValueChanged<List<Book>> onReorder) {
    return MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          slivers: [
            ReorderableBooksGridSliver(
              books: books,
              onReorder: onReorder,
              itemBuilder: (_, book) => Center(child: Text(book.titre)),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('un livre lâché sur un autre prend sa place', (tester) async {
    final books = ['a', 'b', 'c', 'd'].map(_book).toList();
    List<String>? saved;

    await tester.pumpWidget(
      harness(books, (list) => saved = list.map((b) => b.id).toList()),
    );

    await dragOnto(tester, 'a', 'c');

    expect(saved, ['b', 'c', 'a', 'd']);
    expect(visibleOrder(tester, ['a', 'b', 'c', 'd']), ['b', 'c', 'a', 'd']);
  });

  testWidgets('reculer un livre le pose bien à la place visée', (tester) async {
    final books = ['a', 'b', 'c', 'd'].map(_book).toList();
    List<String>? saved;

    await tester.pumpWidget(
      harness(books, (list) => saved = list.map((b) => b.id).toList()),
    );

    await dragOnto(tester, 'd', 'b');

    expect(saved, ['a', 'd', 'b', 'c']);
  });

  testWidgets('trois déplacements de suite : le second ne cafouille pas', (
    tester,
  ) async {
    final books = ['a', 'b', 'c', 'd'].map(_book).toList();
    List<String>? saved;

    await tester.pumpWidget(
      harness(books, (list) => saved = list.map((b) => b.id).toList()),
    );

    // Le flux Firestore ne renvoie rien entre les gestes : la grille doit
    // rester rangeable sur son seul état local. C'est le scénario qui
    // échouait quand la liste se réordonnait sous le doigt.
    await dragOnto(tester, 'a', 'c');
    expect(saved, ['b', 'c', 'a', 'd']);

    await dragOnto(tester, 'b', 'd');
    expect(saved, ['c', 'a', 'd', 'b']);

    await dragOnto(tester, 'd', 'c');
    expect(saved, ['d', 'c', 'a', 'b']);
    expect(visibleOrder(tester, ['a', 'b', 'c', 'd']), ['d', 'c', 'a', 'b']);
  });

  testWidgets('un livre lâché sur lui-même n\'écrit rien', (tester) async {
    final books = ['a', 'b', 'c'].map(_book).toList();
    var calls = 0;

    await tester.pumpWidget(harness(books, (_) => calls++));

    final gesture = await tester.startGesture(tester.getCenter(find.text('a')));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(4, 4));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(calls, 0);
  });

  testWidgets('une grille en lecture seule ne se range pas', (tester) async {
    final books = ['a', 'b', 'c'].map(_book).toList();
    var calls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              ReorderableBooksGridSliver(
                books: books,
                enabled: false,
                onReorder: (_) => calls++,
                itemBuilder: (_, book) => Center(child: Text(book.titre)),
              ),
            ],
          ),
        ),
      ),
    );

    await dragOnto(tester, 'a', 'c');

    expect(calls, 0);
    expect(visibleOrder(tester, ['a', 'b', 'c']), ['a', 'b', 'c']);
  });
}
