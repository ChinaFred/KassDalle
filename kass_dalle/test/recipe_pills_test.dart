import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:kass_dalle/core/theme/app_theme.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_rating.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/recipe_detail_annotations.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/recipe_detail_screen.dart';
import 'package:kass_dalle/features/recipes/presentation/list/recipe_list_widgets.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_rating_colors.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_rating_widget.dart';

import 'support/test_backend.dart';

/// Rapport de contraste WCAG entre deux couleurs opaques.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

RecipeRating rating(int value) => RecipeRating(
  userId: 'uid-test',
  recipeId: 'r1',
  rating: value,
  updatedAt: DateTime(2026, 10, 20),
);

Future<void> pumpBadge(
  WidgetTester tester, {
  required int? value,
  bool readOnly = false,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myRatingProvider.overrideWith(
          (ref, id) => Stream.value(value == null ? null : rating(value)),
        ),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light,
        home: Scaffold(
          body: Center(
            child: RecipeRatingBadge(recipeId: 'r1', readOnly: readOnly),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('ratingColors', () {
    for (final entry in {
      'clair': AppTheme.light,
      'sombre': AppTheme.dark,
    }.entries) {
      for (final value in [3, 6, 9]) {
        test('note $value, thème ${entry.key} : contraste ≥ 4,5:1', () {
          final c = ratingColors(value, entry.value.colorScheme);
          expect(
            contrast(c.background, c.foreground),
            greaterThanOrEqualTo(4.5),
          );
        });
      }
    }

    test('paliers : 8-10 primary, 5-7 secondary, 0-4 error', () {
      final cs = AppTheme.light.colorScheme;
      expect(ratingColors(10, cs).background, cs.primaryContainer);
      expect(ratingColors(8, cs).foreground, cs.onPrimaryContainer);
      expect(ratingColors(7, cs).background, cs.secondaryContainer);
      expect(ratingColors(5, cs).foreground, cs.onSecondaryContainer);
      expect(ratingColors(4, cs).background, cs.errorContainer);
      expect(ratingColors(0, cs).foreground, cs.onErrorContainer);
    });
  });

  group('libellés', () {
    test('note', () {
      expect(
        ratingBadgeLabel(8, editable: true),
        'Ma note : 8 sur 10. Modifier',
      );
      expect(
        ratingBadgeLabel(null, editable: true),
        'Pas encore notée. Noter cette recette',
      );
      expect(ratingBadgeLabel(8, editable: false), 'Ma note : 8 sur 10');
      expect(ratingBadgeLabel(null, editable: false), 'Pas encore notée');
    });

    test('annotations : accord et types à zéro omis', () {
      expect(
        annotationCountsLabel((notes: 2, tips: 1, corrections: 1)),
        '2 remarques, 1 astuce, 1 correction',
      );
      expect(
        annotationCountsLabel((notes: 0, tips: 3, corrections: 0)),
        '3 astuces',
      );
      expect(annotationCountsLabel((notes: 0, tips: 0, corrections: 0)), '');
    });
  });

  group('RecipeRatingBadge', () {
    testWidgets('cible conforme et libellé lu', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBadge(tester, value: 8);

      expect(
        find.bySemanticsLabel(RegExp('Ma note : 8 sur 10')),
        findsOneWidget,
      );
      expect(find.byTooltip('Ma note : 8 sur 10. Modifier'), findsOneWidget);
      final size = tester.getSize(find.byType(InkWell));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('pas encore notée : « Noter cette recette »', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBadge(tester, value: null);
      expect(
        find.bySemanticsLabel('Pas encore notée. Noter cette recette'),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('lecture seule : ni bouton, ni « Modifier »', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpBadge(tester, value: 8, readOnly: true);
      expect(find.byType(InkWell), findsNothing);
      expect(find.bySemanticsLabel('Ma note : 8 sur 10'), findsOneWidget);
      handle.dispose();
    });

    for (final entry in {
      'clair': AppTheme.light,
      'sombre': AppTheme.dark,
    }.entries) {
      for (final value in [3, 6, 9]) {
        testWidgets('contraste du texte, note $value, thème ${entry.key}', (
          tester,
        ) async {
          final handle = tester.ensureSemantics();
          await pumpBadge(tester, value: value, theme: entry.value);
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          handle.dispose();
        });
      }
    }
  });

  group('AnnotationPills', () {
    testWidgets('une seule cible pour le groupe, conforme', (tester) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Center(
              child: AnnotationPills(
                counts: (notes: 2, tips: 1, corrections: 1),
                onTap: () => taps++,
              ),
            ),
          ),
        ),
      );
      expect(find.byType(InkWell), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          '2 remarques, 1 astuce, 1 correction. Voir les annotations',
        ),
        findsOneWidget,
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('aucune annotation : rien de dessiné', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: AnnotationPills(counts: (notes: 0, tips: 0, corrections: 0)),
        ),
      );
      expect(find.byType(Icon), findsNothing);
    });
  });

  group('Fiche', () {
    testWidgets('barre à 1000 px : note et annotations sans débordement', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final backend = TestBackend();
      await backend.seedRecipe(
        testRecipe(
          id: 'r1',
          titre: 'Une tarte aux pommes au titre assez long pour la barre',
          bookId: 'book-1',
        ),
      );
      await backend.seedBook(testBook(id: 'book-1', titre: 'Les classiques'));
      await backend.firestore
          .collection('recipe_ratings')
          .doc(RecipeRating.docId('uid-test', 'r1'))
          .set({
            'user_id': 'uid-test',
            'recipe_id': 'r1',
            'rating': 8,
            'updated_at': Timestamp.fromDate(DateTime(2026, 10, 20)),
          });
      for (final type in ['note', 'note', 'tip']) {
        await backend.firestore
            .collection('recipes')
            .doc('r1')
            .collection('annotations')
            .add({
              'uid': 'uid-test',
              'author_name': 'Moi',
              'text': 'Texte',
              'type': type,
              'created_at': Timestamp.fromDate(DateTime(2026, 10, 1)),
            });
      }

      await pumpScreen(
        tester,
        const RecipeDetailScreen(recipeId: 'r1'),
        backend: backend,
        surface: const Size(1000, 800),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.bySemanticsLabel(RegExp('Ma note : 8 sur 10')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('2 remarques, 1 astuce. Voir les annotations'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('Liste', () {
    testWidgets('appui sur la pastille : la fiche s\'ouvre', (tester) async {
      final handle = tester.ensureSemantics();
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: ListView(
                children: [
                  RecipeCard(
                    recipe: testRecipe(id: 'r1', titre: 'Tarte aux pommes'),
                    inBookContext: false,
                    canEdit: false,
                  ),
                ],
              ),
            ),
          ),
          GoRoute(
            path: '/recipes/:id',
            builder: (_, state) =>
                Scaffold(body: Text('Fiche ${state.pathParameters['id']}')),
          ),
        ],
      );
      final backend = TestBackend();
      for (final type in ['note', 'note', 'tip']) {
        await backend.firestore
            .collection('recipes')
            .doc('r1')
            .collection('annotations')
            .add({
              'uid': 'uid-test',
              'author_name': 'Moi',
              'text': 'Texte',
              'type': type,
              'created_at': Timestamp.fromDate(DateTime(2026, 10, 1)),
            });
      }
      await tester.pumpWidget(
        ProviderScope(
          retry: appProviderRetry,
          overrides: [
            ...backend.overrides,
            myRatingProvider.overrideWith((ref, id) => Stream.value(rating(8))),
          ],
          child: MaterialApp.router(
            theme: AppTheme.light,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Le contenu de la pastille est lu avec la tuile.
      expect(
        find.bySemanticsLabel(
          'Tarte aux pommes\nMa note : 8 sur 10\n2 remarques, 1 astuce',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byType(RatingPill));
      await tester.pumpAndSettle();
      expect(find.text('Fiche r1'), findsOneWidget);
      handle.dispose();
    });
  });
}
