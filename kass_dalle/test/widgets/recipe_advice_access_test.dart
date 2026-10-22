import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/widgets/error_message.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/recipes/data/plating_repository.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_advice_access.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/dressing_coach_section.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/nutrition_details_section.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';

import '../support/test_backend.dart';

/// Conseils et calculs écrits sur la recette : seuls son créateur et un
/// administrateur les déclenchent (faille 5 de l'audit, v0.23.9). Les autres
/// ne voient pas le bouton, et l'écran dit pourquoi.
class _FakeErrorReports extends Fake implements ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'id';
  }
}

void main() {
  late TestBackend backend;
  late _FakeErrorReports reports;

  setUp(() {
    backend = TestBackend();
    reports = _FakeErrorReports();
  });

  Future<void> seedAdvice(String recipeId) =>
      backend.firestore.collection('recipes').doc(recipeId).update({
        'plating_advice': {
          'complexite': 'simple',
          'resume': 'Un lit, puis le reste.',
          'etapes': [
            {'titre': 'Le lit', 'geste': 'Étaler le confit.'},
          ],
        },
      });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      ProviderScope(
        retry: appProviderRetry,
        overrides: [
          ...backend.overrides,
          errorReportServiceProvider.overrideWithValue(reports),
          platingRepositoryProvider.overrideWithValue(
            PlatingRepository(firestore: backend.firestore),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('DressingCoachSection sans conseil enregistré', () {
    testWidgets('le créateur peut en demander un', (tester) async {
      final recipe = testRecipe();
      await backend.seedRecipe(recipe);
      await pump(tester, DressingCoachSection(recipe: recipe, canEdit: true));

      expect(find.text('Demander un dressage sur mesure'), findsOneWidget);
      expect(find.text(kPlatingAdviceReservedMessage), findsNothing);
    });

    testWidgets('un autre compte lit l\'explication, sans bouton', (
      tester,
    ) async {
      final recipe = testRecipe(createdBy: 'uid-autre');
      await backend.seedRecipe(recipe);
      await pump(tester, DressingCoachSection(recipe: recipe, canEdit: false));

      expect(find.text('Demander un dressage sur mesure'), findsNothing);
      expect(find.text(kPlatingAdviceReservedMessage), findsOneWidget);
    });
  });

  group('DressingCoachSection avec un conseil enregistré', () {
    testWidgets('le créateur éditeur illustre et régénère', (tester) async {
      final recipe = testRecipe();
      await backend.seedRecipe(recipe);
      await seedAdvice(recipe.id);
      await pump(tester, DressingCoachSection(recipe: recipe, canEdit: true));

      expect(find.text('Illustrer cette étape'), findsOneWidget);
      expect(find.text('Régénérer'), findsOneWidget);
    });

    // L'IA qui modifie une recette est réservée aux éditeurs (v0.24.65) : la
    // fiche passe
    // `canEnrichRecipe`, faux pour un lecteur même créateur. Il lit le conseil
    // enregistré, sans « Régénérer » ni visuels.
    testWidgets('le créateur lecteur lit le conseil, sans régénérer', (
      tester,
    ) async {
      backend = TestBackend(user: testUser(role: UserRole.reader));
      final recipe = testRecipe();
      await backend.seedRecipe(recipe);
      await seedAdvice(recipe.id);
      await pump(tester, DressingCoachSection(recipe: recipe, canEdit: false));

      expect(find.text('Un lit, puis le reste.'), findsOneWidget);
      expect(find.text('Illustrer cette étape'), findsNothing);
      expect(find.text('Régénérer'), findsNothing);
    });

    testWidgets(
      'un lecteur ne régénère pas, même si l\'écran le laisse passer',
      (tester) async {
        backend = TestBackend(user: testUser(role: UserRole.reader));
        final recipe = testRecipe();
        await backend.seedRecipe(recipe);
        await seedAdvice(recipe.id);
        await pump(tester, DressingCoachSection(recipe: recipe, canEdit: true));

        expect(find.text('Régénérer'), findsNothing);
        expect(find.text('Intégrer à la recette'), findsNothing);
      },
    );

    testWidgets('un autre compte lit le conseil, sans action', (tester) async {
      final recipe = testRecipe(createdBy: 'uid-autre');
      await backend.seedRecipe(recipe);
      await seedAdvice(recipe.id);
      await pump(tester, DressingCoachSection(recipe: recipe, canEdit: false));

      expect(find.text('Un lit, puis le reste.'), findsOneWidget);
      expect(find.text('Illustrer cette étape'), findsNothing);
      expect(find.text('Régénérer'), findsNothing);
    });
  });

  group('NutritionDetailsSection sans nutrition calculée', () {
    testWidgets('avec le droit : bouton Calculer', (tester) async {
      await pump(
        tester,
        NutritionDetailsSection(
          recipe: testRecipe(),
          selectedPortions: null,
          onRecompute: () async {},
        ),
      );
      expect(find.text('Calculer'), findsOneWidget);
    });

    testWidgets('sans le droit : explication, sans bouton', (tester) async {
      await pump(
        tester,
        NutritionDetailsSection(
          recipe: testRecipe(createdBy: 'uid-autre'),
          selectedPortions: null,
          onRecompute: null,
        ),
      );
      expect(find.text('Calculer'), findsNothing);
      expect(find.text(kNutritionReservedMessage), findsOneWidget);
    });

    testWidgets('plafond d\'IA atteint : le message du serveur s\'affiche', (
      tester,
    ) async {
      const serverMessage =
          'Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui. '
          'Réessayez demain.';
      await pump(
        tester,
        NutritionDetailsSection(
          recipe: testRecipe(),
          selectedPortions: null,
          onRecompute: () async => throw FirebaseFunctionsException(
            code: 'resource-exhausted',
            message: serverMessage,
            details: {'reason': 'cost', 'scope': kAiBudgetScope},
          ),
        ),
      );
      await tester.tap(find.text('Calculer'));
      await tester.pumpAndSettle();

      expect(
        find.text('Nutrition non calculée. $serverMessage'),
        findsOneWidget,
      );
      expect(reports.features, ['nutritionDetailsSection.recompute']);
    });

    testWidgets('échec du calcul : message lisible, sans texte brut', (
      tester,
    ) async {
      await pump(
        tester,
        NutritionDetailsSection(
          recipe: testRecipe(),
          selectedPortions: null,
          onRecompute: () async => throw FirebaseFunctionsException(
            code: 'internal',
            message: 'Le traitement a échoué.',
          ),
        ),
      );
      await tester.tap(find.text('Calculer'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Nutrition non calculée. Une erreur inattendue est survenue.',
        ),
        findsOneWidget,
      );
      expect(reports.features, ['nutritionDetailsSection.recompute']);
    });
  });
}
