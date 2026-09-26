import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:firebase_core/firebase_core.dart';

import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/books/presentation/book_picker_field.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_screen.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_edit_screen.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';

import '../support/test_backend.dart';

void main() {
  group('Parcours 4 — édition d\'une recette', () {
    testWidgets('le formulaire s\'ouvre garni du contenu existant', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(
        testRecipe(id: 'r1', titre: 'Blanquette de veau'),
      );

      await pumpScreen(
        tester,
        const RecipeEditScreen(recipeId: 'r1'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(TextField, 'Blanquette de veau'),
        findsOneWidget,
      );
    });

    testWidgets(
      'le champ Livre montre le livre de la recette et liste les livres '
      'dans l\'ordre de la bibliothèque',
      (tester) async {
        final backend = TestBackend();
        // Par date de modification, l'ordre naturel serait A, B, C.
        await backend.seedBook(
          testBook(
            id: 'b-a',
            titre: 'Livre A',
            updatedAt: DateTime.utc(2026, 6, 3),
          ),
        );
        await backend.seedBook(
          testBook(
            id: 'b-b',
            titre: 'Livre B',
            updatedAt: DateTime.utc(2026, 6, 2),
          ),
        );
        await backend.seedBook(
          testBook(
            id: 'b-c',
            titre: 'Livre C',
            updatedAt: DateTime.utc(2026, 6, 1),
          ),
        );
        await backend.firestore
            .collection('users')
            .doc('uid-test')
            .collection('preferences')
            .doc('book_order')
            .set({
              'book_ids': ['b-c', 'b-a', 'b-b'],
            });
        await backend.seedRecipe(
          testRecipe(id: 'r1', titre: 'Blanquette de veau', bookId: 'b-b'),
        );

        await pumpScreen(
          tester,
          const RecipeEditScreen(recipeId: 'r1'),
          backend: backend,
        );
        await tester.pumpAndSettle();

        final field = find.descendant(
          of: find.byType(BookPickerField),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(field).controller!.text, 'Livre B');

        await tester.tap(field);
        await tester.pumpAndSettle();

        final labels = tester
            .widgetList<MenuItemButton>(find.byType(MenuItemButton))
            .map((b) => ((b.child as Padding).child as Text).data)
            .toList();
        expect(labels, ['Livre C', 'Livre A', 'Livre B']);
      },
    );

    testWidgets('une recette effacée entre-temps ne montre pas d\'exception', (
      tester,
    ) async {
      final backend = TestBackend();

      await pumpScreen(
        tester,
        const RecipeEditScreen(recipeId: 'disparue'),
        backend: backend,
      );
      await tester.pumpAndSettle();

      expect(find.text('Recette introuvable'), findsOneWidget);
    });

    testWidgets('une erreur de lecture affiche l\'état partagé', (
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
                  code: 'unavailable',
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            locale: Locale('fr'),
            home: RecipeEditScreen(recipeId: 'r1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.text('Connexion perdue'), findsOneWidget);
      expect(find.text('Réessayer'), findsOneWidget);
    });
  });

  group('Parcours 5 — la file des brouillons', () {
    testWidgets('les brouillons de l\'utilisateur y figurent', (tester) async {
      final backend = TestBackend();
      await backend.seedRecipe(
        testRecipe(
          id: 'd1',
          titre: 'Scan du 3 mai',
          reviewStatus: ReviewStatus.draft,
        ),
      );

      await pumpScreen(tester, const WorkQueueScreen(), backend: backend);
      await tester.pumpAndSettle();

      expect(find.text('Scan du 3 mai'), findsOneWidget);
    });

    testWidgets('une recette validée n\'encombre pas la file', (tester) async {
      final backend = TestBackend();
      await backend.seedRecipe(testRecipe(id: 'v1', titre: 'Déjà publiée'));

      await pumpScreen(tester, const WorkQueueScreen(), backend: backend);
      await tester.pumpAndSettle();

      expect(find.text('Déjà publiée'), findsNothing);
    });

    testWidgets('la file se tire pour se rafraîchir', (tester) async {
      final backend = TestBackend();

      await pumpScreen(tester, const WorkQueueScreen(), backend: backend);
      await tester.pumpAndSettle();

      expect(find.byType(RefreshIndicator), findsOneWidget);
    });
  });

  group('Parcours 6 — le planning', () {
    testWidgets('un planning vide invite à en créer un', (tester) async {
      final backend = TestBackend();

      await pumpScreen(tester, const PlanningScreen(), backend: backend);
      await tester.pumpAndSettle();

      expect(find.text('Aucun repas planifié'), findsOneWidget);
      expect(find.text('Nouveau planning'), findsOneWidget);
    });

    testWidgets('le planning se tire pour se rafraîchir', (tester) async {
      final backend = TestBackend();

      await pumpScreen(tester, const PlanningScreen(), backend: backend);
      await tester.pumpAndSettle();

      expect(find.byType(RefreshIndicator), findsOneWidget);
    });
  });
}
