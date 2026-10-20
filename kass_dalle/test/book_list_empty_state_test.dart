import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_list_screen.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';

Book _book(String id) {
  final now = DateTime(2026, 1, 1);
  return Book(
    id: id,
    titre: 'Livre $id',
    auteur: 'Kassbi',
    langue: 'fr',
    tags: const [],
    createdBy: 'moi',
    createdAt: now,
    updatedAt: now,
  );
}

const _noGroupText =
    'Vous ne voyez que vos livres. Rejoignez un groupe familial pour voir '
    'ceux de vos proches.';

Future<void> _open(
  WidgetTester tester, {
  required bool canEdit,
  List<Book> myBooks = const [],
  Set<String> members = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        canEditProvider.overrideWithValue(canEdit),
        myBooksOrderedProvider.overrideWithValue(AsyncValue.data(myBooks)),
        groupMemberBooksProvider.overrideWith((ref) => Stream.value([])),
        groupMemberIdsProvider.overrideWithValue(AsyncValue.data(members)),
      ],
      child: const MaterialApp(home: BookListScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('bibliothèque vide d’un éditeur : ajouter un livre', (
    tester,
  ) async {
    await _open(tester, canEdit: true);
    expect(find.text('Aucun livre pour le moment'), findsOneWidget);
    expect(
      find.text(
        'Ajoutez votre premier livre : scan de la couverture, fichier PDF ou '
        'EPUB, ou saisie.',
      ),
      findsOneWidget,
    );
    expect(find.text('Ouvrir Groupes familiaux'), findsNothing);
  });

  testWidgets('bibliothèque vide d’un lecteur : rejoindre un groupe', (
    tester,
  ) async {
    await _open(tester, canEdit: false);
    expect(
      find.text(
        'Les livres de votre famille apparaissent ici quand vous rejoignez '
        'un groupe. Un proche vous y invite.',
      ),
      findsOneWidget,
    );
    expect(find.text('Ouvrir Groupes familiaux'), findsOneWidget);
    expect(find.text('Ajouter un livre'), findsNothing);
  });

  testWidgets('bibliothèque vide d’un lecteur déjà dans un groupe', (
    tester,
  ) async {
    await _open(tester, canEdit: false, members: {'proche'});
    expect(
      find.text(
        'Les livres de votre famille apparaîtront ici dès qu\'un proche en '
        'ajoutera un.',
      ),
      findsOneWidget,
    );
    expect(find.text('Ouvrir Groupes familiaux'), findsNothing);
    expect(find.text(_noGroupText), findsNothing);
  });

  testWidgets('l’écran vide défile, pour tirer et rafraîchir', (tester) async {
    await _open(tester, canEdit: false);
    expect(find.byType(Scrollable), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('sans groupe, la carte s’affiche sous « Mes livres »', (
    tester,
  ) async {
    await _open(tester, canEdit: false, myBooks: [_book('a')]);
    expect(find.text(_noGroupText), findsOneWidget);
    expect(find.text('Ouvrir Groupes familiaux'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(_noGroupText)).dy,
      greaterThan(tester.getTopLeft(find.text('Mes livres')).dy),
    );
  });

  testWidgets('avec un groupe, pas de carte', (tester) async {
    await _open(
      tester,
      canEdit: true,
      myBooks: [_book('a')],
      members: {'proche'},
    );
    expect(find.text(_noGroupText), findsNothing);
  });
}
