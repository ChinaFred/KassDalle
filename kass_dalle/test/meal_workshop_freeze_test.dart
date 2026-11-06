import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/search/data/meal_workshop_functions.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_freeze.dart';
import 'package:kass_dalle/features/search/domain/meal_workshop_menu.dart';

/// « Figer le repas » : doublons de titre, texte de la boîte accordé, compte
/// des lignes, et lecture d'un échec d'appel. Fonctions pures.
void main() {
  Recipe recipe(String id, String titre, {String? book}) => Recipe(
    id: id,
    titre: titre,
    bookTitre: book,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    createdBy: 'moi',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  WorkshopCourse course(
    String title, {
    String role = 'plat',
    String? recipeId,
    List<String> sides = const [],
  }) => WorkshopCourse.fromJson({
    'role': role,
    'title': title,
    'recipe_id': recipeId,
    'sides': [
      for (final s in sides) {'label': s},
    ],
  });

  group('doublons de titre', () {
    test('sans casse ni accents ; une recette liée n\'est pas un doublon', () {
      final menu = WorkshopMenu(
        portions: 4,
        courses: [
          course('Velouté de potimarron', role: 'entree'),
          course('blanquette de VEAU'),
          course('Tarte aux poires', role: 'dessert', recipeId: 'r3'),
        ],
      );
      final duplicates = workshopTitleDuplicates(menu, [
        recipe('r1', 'Blanquette de veau', book: 'Le Grand Livre'),
        recipe('r2', 'Blanquette de veau', book: 'Autre livre'),
        recipe('r3', 'Tarte aux poires'),
      ]);
      expect(duplicates.length, 1);
      expect(duplicates.single.courseIndex, 1);
      // La première recette qui correspond, dans l'ordre reçu.
      expect(duplicates.single.recipe.id, 'r1');
      expect(
        duplicates.single.line,
        '« Blanquette de veau » existe dans Le Grand Livre',
      );
      expect(
        WorkshopTitleDuplicate(
          courseIndex: 0,
          recipe: recipe('r9', 'Sans'),
        ).line,
        '« Sans » existe dans Sans livre',
      );
    });

    test('la clé de titre replie casse, accents et ponctuation', () {
      expect(workshopTitleKey('Blanquette de veau'), 'blanquette de veau');
      expect(workshopTitleKey('BLANQUETTE  DE VEAU !'), 'blanquette de veau');
      expect(
        workshopTitleKey('Pâtes à l\'ail'),
        workshopTitleKey('pates a l ail'),
      );
    });
  });

  group('texte de la boîte', () {
    test('accordé au nombre de plats, de recettes liées et de parts', () {
      expect(
        freezeDialogSummary(toWrite: 3, linked: 1, portions: 6),
        '3 plats seront rédigés par l\'IA, pour 6 parts : un appel chacun. '
        '1 recette existante reste liée telle quelle, avec ses propres parts.',
      );
      expect(
        freezeDialogSummary(toWrite: 1, linked: 0, portions: 4),
        '1 plat sera rédigé par l\'IA, pour 4 parts : un appel.',
      );
      expect(
        freezeDialogSummary(toWrite: 2, linked: 2, portions: 1),
        '2 plats seront rédigés par l\'IA, pour 1 part : un appel chacun. '
        '2 recettes existantes restent liées telles quelles, avec leurs '
        'propres parts.',
      );
      // Tous les doublons liés : aucun appel.
      expect(
        freezeDialogSummary(toWrite: 0, linked: 2, portions: 4),
        'Aucun plat ne sera rédigé : 2 recettes existantes seront liées.',
      );
      expect(
        freezeDialogSummary(toWrite: 0, linked: 1, portions: 4),
        'Aucun plat ne sera rédigé : 1 recette existante sera liée.',
      );
    });

    test('un figement sans plat à rédiger : pied et compte rendu', () {
      expect(linkedOnlyLine(2), '2 recettes liées');
      expect(linkedOnlyLine(1), '1 recette liée');
      expect(freezeLinkedOnlyMessage(2), 'Repas figé : 2 recettes liées.');
      expect(freezeLinkedOnlyMessage(1), 'Repas figé : 1 recette liée.');
    });

    test('les accompagnements d\'un plat à rédiger sont cités', () {
      final one = WorkshopMenu(
        portions: 4,
        courses: [
          course('Bar rôti', sides: const ['riz', 'carottes glacées']),
          course('Riz pilaf', recipeId: 'r1', sides: const ['salade']),
        ],
      );
      expect(freezeSidesLines(one), [
        'Accompagnements cités dans la recette du plat, sans recette à part : '
            'riz, carottes glacées.',
      ]);
      final two = WorkshopMenu(
        portions: 4,
        courses: [
          course('Bar rôti', sides: const ['riz']),
          course('Poulet', sides: const ['frites']),
        ],
      );
      expect(freezeSidesLines(two), [
        'Accompagnements cités dans la recette de « Bar rôti », sans recette '
            'à part : riz.',
        'Accompagnements cités dans la recette de « Poulet », sans recette '
            'à part : frites.',
      ]);
      expect(
        freezeSidesLines(WorkshopMenu(portions: 4, courses: [course('Sec')])),
        isEmpty,
      );
    });

    test('les autres libellés, accordés', () {
      expect(MealWorkshopBook.kassDalle.label, 'Mes créations Kass\'Dalle ✨');
      expect(MealWorkshopBook.libres.label, 'Mes recettes libres');
      expect(
        freezeFooterLine(created: 3, linked: 1),
        '3 brouillons créés · 1 recette liée',
      );
      expect(
        freezeFooterLine(created: 1, linked: 2),
        '1 brouillon créé · 2 recettes liées',
      );
      expect(
        menuFooterLine(toWrite: 2, linked: 1),
        '2 plats à rédiger · 1 recette liée',
      );
      expect(
        freezeDoneMessage(created: 3, bookTitle: 'Mes créations Kass\'Dalle ✨'),
        '3 brouillons créés dans « Mes créations Kass\'Dalle ✨ ».',
      );
      expect(
        freezePartialMessage(notWritten: 1, created: 2),
        '1 plat non rédigé. 2 brouillons créés.',
      );
      expect(
        leaveAfterPartialFreezeTitle(2),
        '2 plats ne sont pas rédigés. Quitter sans enregistrer ?',
      );
      expect(
        newConversationAfterPartialFreezeTitle(1),
        '1 plat n\'est pas rédigé. Nouvelle conversation ?',
      );
    });
  });

  group('lignes du figement', () {
    final menu = WorkshopMenu(
      portions: 4,
      courses: [
        course('Velouté', role: 'entree'),
        course('Blanquette', recipeId: 'r1'),
        course('Tarte', role: 'dessert'),
        course('Sorbet', role: 'sorbet'),
      ],
    );

    test('les comptes : créés, liées, non rédigés', () {
      final lines = <FreezeLineState>[
        const FreezeDraftCreated('d1'),
        const FreezeLinked('r1'),
        FreezeFailed(StateError('x')),
        const FreezeBudgetStopped('Limite atteinte.'),
      ];
      expect(freezeCreatedCount(lines), 1);
      expect(freezeLinkedCount(lines), 1);
      expect(freezeNotWrittenCount(menu, lines), 2);
    });

    test('tout rédigé : rien à redire ; une liée illisible ne compte pas', () {
      final lines = <FreezeLineState>[
        const FreezeDraftCreated('d1'),
        const FreezeLinkedUnreadable(),
        const FreezeDraftCreated('d2'),
        const FreezeDraftCreated('d3'),
      ];
      expect(freezeNotWrittenCount(menu, lines), 0);
      expect(freezeLinkedCount(lines), 0);
    });

    test('en attente ou en cours : pas encore rédigé', () {
      final lines = <FreezeLineState>[
        const FreezeWaiting(),
        const FreezeWaiting(),
        const FreezeWriting(),
        const FreezeWaiting(),
      ];
      // La recette liée en attente n'est pas un plat à rédiger.
      expect(freezeNotWrittenCount(menu, lines), 3);
    });

    test('ce qui se rejoue', () {
      expect(freezeLineRetryable(FreezeFailed(StateError('x'))), isTrue);
      expect(freezeLineRetryable(const FreezeNoRecipe()), isTrue);
      expect(freezeLineRetryable(const FreezeLinkedUnreadable()), isTrue);
      expect(
        freezeLineRetryable(
          FreezeSaveFailed(recipe('r', 't'), StateError('x')),
        ),
        isTrue,
      );
      expect(freezeLineRetryable(const FreezeBudgetStopped('x')), isFalse);
      expect(freezeLineRetryable(const FreezePermissionDenied()), isFalse);
      expect(freezeLineRetryable(const FreezeDraftCreated('d')), isFalse);
    });
  });

  group('lecture d\'un échec d\'appel', () {
    test('plafond du jour : sans carte, le plafond est lu', () {
      final f = describeWorkshopFailure(
        GeminiCallableException('resource-exhausted', 'Plafond.', {
          'reason': kWorkshopDailyQuotaReason,
          'limit': 30,
          'remaining': 0,
        }),
      );
      expect(f.kind, WorkshopFailureKind.dailyQuota);
      expect(f.limit, 30);
      expect(f.retryable, isFalse);
    });

    test(
      'budget d\'IA du jour : le message du serveur, sans « Réessayer »',
      () {
        final f = describeWorkshopFailure(
          GeminiCallableException(
            'resource-exhausted',
            'Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui.',
            {'scope': 'ai_budget', 'reason': 'cost'},
          ),
        );
        expect(f.kind, WorkshopFailureKind.aiBudget);
        expect(
          f.message,
          'Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui.',
        );
        expect(f.retryable, isFalse);
      },
    );

    test('réponse illisible : facturée et comptée, avec « Réessayer »', () {
      final f = describeWorkshopFailure(
        GeminiCallableException(
          'internal',
          'L\'IA n\'a pas rendu de réponse lisible.',
          {
            'reason': kWorkshopUnreadableReason,
            'quota': {'limit': 30, 'remaining': 26},
          },
        ),
      );
      expect(f.kind, WorkshopFailureKind.unreadable);
      expect(f.retryable, isTrue);
      expect(f.quota?.remaining, 26);
      expect(f.message, 'L\'IA n\'a pas rendu de réponse lisible.');
    });

    test('rôle retiré, entrée refusée, réseau', () {
      final denied = describeWorkshopFailure(
        GeminiCallableException('permission-denied', '', null),
      );
      expect(denied.kind, WorkshopFailureKind.permissionDenied);
      expect(denied.message, 'L\'IA est réservée aux éditeurs.');
      expect(denied.retryable, isFalse);

      final refused = describeWorkshopFailure(
        GeminiCallableException('invalid-argument', 'Conversation terminée', {
          'reason': kWorkshopMaxTurnsReason,
        }),
      );
      expect(refused.kind, WorkshopFailureKind.refused);
      expect(refused.message, 'Conversation terminée.');
      expect(refused.retryable, isFalse);

      final network = describeWorkshopFailure(
        FirebaseFunctionsException(code: 'unavailable', message: 'down'),
      );
      expect(network.kind, WorkshopFailureKind.other);
      expect(network.message, 'Connexion perdue.');
      expect(network.retryable, isTrue);

      // Fournisseur saturé : `resource-exhausted` sans détails.
      final saturated = describeWorkshopFailure(
        GeminiCallableException('resource-exhausted', '', null),
      );
      expect(saturated.kind, WorkshopFailureKind.other);
      expect(saturated.message, 'Service d\'IA saturé.');
      expect(saturated.retryable, isTrue);
    });
  });
}
