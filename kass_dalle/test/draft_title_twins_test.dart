import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/draft_title_twins.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_widgets.dart';

Recipe _draft(
  String id, {
  String titre = 'Rouget',
  String? key = 'rouget',
  String? book = 'b1',
  int? page,
  RecipeDuplicateRef? duplicateOf,
}) => Recipe(
  id: id,
  titre: titre,
  langue: 'fr',
  rawCooklang: 'Posez le filet.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.draft,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  bookId: book,
  pageNumber: page,
  titreKey: key,
  duplicateOf: duplicateOf,
);

Widget _tile(Recipe r, {DraftTitleTwins? twins, double width = 360}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: QueueDraftTile(
            recipe: r,
            twins: twins,
            isSelected: false,
            isSelecting: false,
            onTap: () {},
            onLongPress: () {},
            onValidate: () {},
            onDelete: () {},
          ),
        ),
      ),
    );

void main() {
  group('draftTitleTwins', () {
    test('même livre, même clé : les deux côtés sont rapprochés', () {
      final a = _draft('a');
      final b = _draft('b');
      final r = draftTitleTwins([a, b]);
      expect(r['a']!.first.id, 'b');
      expect(r['b']!.first.id, 'a');
      expect(r['a']!.others, 0);
    });

    test('livres différents ou sans livre : aucun rapprochement', () {
      expect(draftTitleTwins([_draft('a'), _draft('b', book: 'b2')]), isEmpty);
      expect(
        draftTitleTwins([_draft('a', book: null), _draft('b', book: null)]),
        isEmpty,
      );
    });

    test('clé absente ou vide : aucun rapprochement', () {
      expect(draftTitleTwins([_draft('a', key: null), _draft('b')]), isEmpty);
      expect(
        draftTitleTwins([_draft('a', key: ''), _draft('b', key: '')]),
        isEmpty,
      );
    });

    test('pages connues et différentes : écartés ; une page absente passe', () {
      expect(
        draftTitleTwins([_draft('a', page: 3), _draft('b', page: 9)]),
        isEmpty,
      );
      expect(draftTitleTwins([_draft('a', page: 3), _draft('b')]).length, 2);
    });

    test('trois brouillons : le premier autre, et le compte des suivants', () {
      final r = draftTitleTwins([_draft('a'), _draft('b'), _draft('c')]);
      expect(r['a']!.first.id, 'b');
      expect(r['a']!.others, 1);
    });
  });

  group('QueueDraftTile', () {
    testWidgets('doublon local : pastille et détail', (tester) async {
      final a = _draft('a');
      final b = _draft('b', page: 3);
      await tester.pumpWidget(_tile(a, twins: draftTitleTwins([a, b])['a']));
      expect(find.text('Doublon'), findsOneWidget);
      expect(find.text('Même titre : « Rouget » (p. 3)'), findsOneWidget);
    });

    testWidgets('marque du serveur : une seule pastille, détail du serveur', (
      tester,
    ) async {
      final a = _draft(
        'a',
        duplicateOf: const RecipeDuplicateRef(titre: 'Rouget grillé', page: 3),
      );
      final b = _draft('b');
      await tester.pumpWidget(_tile(a, twins: draftTitleTwins([a, b])['a']));
      expect(find.text('Doublon'), findsOneWidget);
      expect(
        find.text('Doublon possible de « Rouget grillé » (p. 3)'),
        findsOneWidget,
      );
    });

    testWidgets('sans doublon : rien de plus', (tester) async {
      await tester.pumpWidget(_tile(_draft('a')));
      expect(find.text('Doublon'), findsNothing);
    });

    testWidgets('titre très long sur 360 dp : pas de débordement', (
      tester,
    ) async {
      final a = _draft('a', titre: 'Rouget ' * 20);
      final b = _draft('b', titre: 'Rouget ' * 20);
      await tester.pumpWidget(_tile(a, twins: draftTitleTwins([a, b])['a']));
      expect(tester.takeException(), isNull);
    });
  });

  test('Recipe.fromFirestore lit titre_key', () {
    final r = _draft('a');
    expect(r.titreKey, 'rouget');
  });
}
