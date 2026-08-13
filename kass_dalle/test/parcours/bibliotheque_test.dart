import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/books/presentation/book_list_screen.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';

import '../support/test_backend.dart';

/// Parcours 1 — la bibliothèque, premier écran vu après connexion.
void main() {
  testWidgets('un lecteur sans livre voit l\'état vide, sans bouton d\'ajout', (
    tester,
  ) async {
    final backend = TestBackend(user: testUser(role: UserRole.reader));
    await pumpScreen(tester, const BookListScreen(), backend: backend);
    await tester.pumpAndSettle();

    expect(find.text('Aucun livre pour le moment'), findsOneWidget);
    expect(find.text('Ajouter un livre'), findsNothing);
  });

  testWidgets('un éditeur sans livre se voit proposer d\'en ajouter un', (
    tester,
  ) async {
    final backend = TestBackend(user: testUser(role: UserRole.editor));
    await pumpScreen(tester, const BookListScreen(), backend: backend);
    await tester.pumpAndSettle();

    expect(find.text('Aucun livre pour le moment'), findsOneWidget);
    expect(find.text('Ajouter un livre'), findsWidgets);
  });

  testWidgets('les livres de l\'utilisateur s\'affichent sous « Mes livres »', (
    tester,
  ) async {
    final backend = TestBackend();
    await backend.seedBook(testBook(id: 'b1', titre: 'Les classiques'));
    await backend.seedBook(testBook(id: 'b2', titre: 'Pâtisserie'));

    await pumpScreen(tester, const BookListScreen(), backend: backend);
    await tester.pumpAndSettle();

    expect(find.text('Mes livres'), findsOneWidget);
    expect(find.text('Les classiques'), findsOneWidget);
    expect(find.text('Pâtisserie'), findsOneWidget);
  });

  testWidgets('une lecture refusée affiche un message lisible, pas l\'exception', (
    tester,
  ) async {
    final backend = TestBackend();

    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        retry: appProviderRetry,
        overrides: [
          ...backend.overrides,
          myBooksProvider.overrideWith(
            (ref) => Stream.error(
              FirebaseException(
                plugin: 'cloud_firestore',
                code: 'permission-denied',
              ),
            ),
          ),
        ],
        child: const MaterialApp(
          locale: Locale('fr'),
          home: BookListScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.text('Accès refusé'), findsOneWidget);
    expect(find.textContaining('permission-denied'), findsNothing);
  });
}
