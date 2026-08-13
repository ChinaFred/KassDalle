import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/recipe_detail_screen.dart';
import 'package:kass_dalle/features/recipes/presentation/list/recipe_list_screen.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';

import '../support/test_backend.dart';

/// Parcours 2 et 3 — la liste des recettes d'un livre, puis le détail.
void main() {
  group('Parcours 2 — liste des recettes', () {
    testWidgets('les pages validées du livre s\'affichent', (tester) async {
      final backend = TestBackend();
      await backend.seedBook(testBook(id: 'book-1', titre: 'Les classiques'));
      await backend.seedRecipe(
        testRecipe(id: 'r1', titre: 'Blanquette', bookId: 'book-1'),
      );
      await backend.seedRecipe(
        testRecipe(id: 'r2', titre: 'Ratatouille', bookId: 'book-1'),
      );

      await pumpScreen(
        tester,
        const RecipeListScreen(bookId: 'book-1', bookTitre: 'Les classiques'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      expect(find.text('Blanquette'), findsOneWidget);
      expect(find.text('Ratatouille'), findsOneWidget);
    });

    testWidgets('un brouillon du livre n\'apparaît pas dans la liste validée', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedBook(testBook(id: 'book-1'));
      await backend.seedRecipe(
        testRecipe(id: 'r1', titre: 'Publiée', bookId: 'book-1'),
      );
      await backend.seedRecipe(
        testRecipe(
          id: 'r2',
          titre: 'Encore en chantier',
          bookId: 'book-1',
          reviewStatus: ReviewStatus.draft,
        ),
      );

      await pumpScreen(
        tester,
        const RecipeListScreen(bookId: 'book-1'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      expect(find.text('Publiée'), findsOneWidget);
      expect(find.text('Encore en chantier'), findsNothing);
    });

    testWidgets('la liste se rafraîchit à la demande (RefreshIndicator posé)', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedBook(testBook(id: 'book-1'));
      await backend.seedRecipe(testRecipe(id: 'r1', bookId: 'book-1'));

      await pumpScreen(
        tester,
        const RecipeListScreen(bookId: 'book-1'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      // Le geste « tirer pour rafraîchir » n'existait nulle part avant la
      // vague 2 ; sa présence sur la liste principale fait partie du contrat.
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    testWidgets('une erreur de flux montre un message lisible et un recours', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedBook(testBook(id: 'book-1'));

      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          retry: appProviderRetry,
          overrides: [
            ...backend.overrides,
            allPagesByBookProvider('book-1').overrideWith(
              (ref) => Stream.error(
                FirebaseException(
                  plugin: 'cloud_firestore',
                  code: 'unavailable',
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('fr'),
            home: RecipeListScreen(bookId: 'book-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Connexion perdue'), findsOneWidget);
      expect(find.text('Réessayer'), findsOneWidget);
    });
  });

  group('Parcours 3 — détail d\'une recette', () {
    testWidgets('le titre et les instructions de la recette s\'affichent', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(
        testRecipe(
          id: 'r1',
          titre: 'Blanquette de veau',
          rawCooklang: '>> portions: 4\nFaire revenir le @veau{800%g}.',
        ),
      );

      await pumpScreen(
        tester,
        const RecipeDetailScreen(recipeId: 'r1'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      expect(find.text('Blanquette de veau'), findsWidgets);
      // L'instruction est rendue en RichText : le nom de l'ingrédient y est
      // une puce insérée en WidgetSpan, pas du texte simple.
      expect(
        find.textContaining('Faire revenir', findRichText: true),
        findsWidgets,
      );
    });

    testWidgets('une recette absente le dit, sans exception affichée', (
      tester,
    ) async {
      final backend = TestBackend();

      await pumpScreen(
        tester,
        const RecipeDetailScreen(recipeId: 'inconnue'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      expect(find.text('Recette introuvable'), findsOneWidget);
    });

    testWidgets('une erreur de lecture passe par l\'état d\'erreur partagé', (
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
            recipeDetailProvider('r1').overrideWith(
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
            home: RecipeDetailScreen(recipeId: 'r1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.text('Accès refusé'), findsOneWidget);
      // Refus de droits : pas de bouton qui promette un résultat différent.
      expect(find.text('Réessayer'), findsNothing);
    });
  });
}
