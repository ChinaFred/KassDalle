import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/assign_book_sheet.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_batch.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_widgets.dart';

import 'support/test_backend.dart';

void main() {
  group('assignBookToDraft', () {
    late TestBackend backend;
    setUp(() => backend = TestBackend());

    test('écrit le livre, garde le statut brouillon et la page', () async {
      await backend.seedBook(testBook(id: 'b2', titre: 'Desserts'));
      await backend.seedRecipe(
        testRecipe(
          id: 'd1',
          reviewStatus: ReviewStatus.draft,
          bookId: 'b1',
          pageNumber: 12,
        ),
      );

      await backend.recipes.assignBookToDraft(
        recipeId: 'd1',
        bookId: 'b2',
        bookTitre: 'Desserts',
      );

      final r = (await backend.recipes.getById('d1'))!;
      expect(r.bookId, 'b2');
      expect(r.bookTitre, 'Desserts');
      expect(r.reviewStatus, ReviewStatus.draft);
      expect(r.pageNumber, 12);
    });

    test('la confidentialité prend celle du livre', () async {
      await backend.seedBook(
        testBook(id: 'prive', titre: 'Secret', isPrivate: true),
      );
      await backend.seedRecipe(
        testRecipe(id: 'd1', reviewStatus: ReviewStatus.draft, bookId: 'b1'),
      );

      await backend.recipes.assignBookToDraft(
        recipeId: 'd1',
        bookId: 'prive',
        bookTitre: 'Secret',
      );

      expect((await backend.recipes.getById('d1'))!.isPrivate, isTrue);
    });
  });

  group('bookAssignmentImpact', () {
    test('compte les brouillons qui changent de livre et leurs pages', () {
      final drafts = [
        testRecipe(id: 'a', bookId: 'b1', pageNumber: 3),
        testRecipe(id: 'b', bookId: 'b2'),
        testRecipe(id: 'c', bookId: 'b9', pageNumber: 5),
        testRecipe(id: 'd', pageNumber: 7),
      ];
      final impact = bookAssignmentImpact(drafts, 'b9');
      expect(impact.changing, 2);
      expect(impact.withPageNumber, 1);
    });
  });

  test('bookAssignmentSummary', () {
    expect(
      bookAssignmentSummary(done: 3, failed: 0, bookTitre: 'Desserts'),
      '3 brouillons rangés dans « Desserts »',
    );
    expect(
      bookAssignmentSummary(done: 3, failed: 1, bookTitre: 'Desserts'),
      '2 brouillons rangés dans « Desserts », 1 en erreur',
    );
  });

  testWidgets('la barre affiche « Ranger (N) » seulement avec des brouillons', (
    tester,
  ) async {
    Widget bar(int? count) => MaterialApp(
      home: Scaffold(
        bottomNavigationBar: WorkQueueSelectionBar(
          validateCount: null,
          retryCount: null,
          deleteCount: 2,
          assignBookCount: count,
          onValidate: () {},
          onRetry: () {},
          onDelete: () {},
          onAssignBook: () {},
        ),
      ),
    );
    await tester.pumpWidget(bar(null));
    expect(find.text('Ranger (2)'), findsNothing);
    await tester.pumpWidget(bar(2));
    expect(find.text('Ranger (2)'), findsOneWidget);
  });

  testWidgets('la feuille active « Ranger (N) » après le choix d\'un livre', (
    tester,
  ) async {
    final books = [testBook(id: 'b1', titre: 'Desserts')];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AssignBookSheet(
            books: books,
            drafts: [
              testRecipe(id: 'a'),
              testRecipe(id: 'b'),
            ],
          ),
        ),
      ),
    );
    FilledButton button() =>
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(find.text('Ranger (2)'), findsOneWidget);
    expect(button().onPressed, isNull);

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Desserts').last);
    await tester.pumpAndSettle();
    expect(button().onPressed, isNotNull);
  });
}
