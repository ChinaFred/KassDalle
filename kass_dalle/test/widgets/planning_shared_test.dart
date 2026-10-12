import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';

import '../support/test_backend.dart';

/// Plannings partagés, vus de l'écran du planning : le lecteur lit, ne
/// planifie pas ; l'éditeur voit son planning seul par défaut.
void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  PlannedMeal meal(String id, String uid, String titre, {int hour = 19}) {
    final now = DateTime.now();
    return PlannedMeal(
      id: id,
      uid: uid,
      recipeId: 'r-$id',
      recipeTitre: titre,
      plannedAt: DateTime(now.year, now.month, now.day, hour),
      durationMinutes: 30,
      justification: 'Choisie par Kass\'Dalle · volaille',
      createdAt: now,
    );
  }

  Future<void> pump(
    WidgetTester tester, {
    required UserRole role,
    Set<String> reach = const {},
    Map<String, List<PlannedMeal>> shared = const {},
    List<PlannedMeal> mine = const [],
    List<FamilyGroup> groups = const [],
    Size size = const Size(360, 800),
  }) async {
    final backend = TestBackend(
      user: testUser(role: role),
      plannedMeals: mine,
      groups: groups,
    );
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        retry: appProviderRetry,
        // Une seule portée : les providers dérivés (sélecteur des
        // plannings) lisent ces remplacements.
        overrides: [
          ...backend.overrides,
          planningReachProvider.overrideWith((ref) => Stream.value(reach)),
          sharedPlannedMealsProvider.overrideWith(
            (ref, uid) => Stream.value(shared[uid] ?? const []),
          ),
          memberNameProvider.overrideWith(
            (ref, uid) => uid == 'marie' ? 'Marie' : 'Paul',
          ),
        ],
        child: const MaterialApp(locale: Locale('fr'), home: PlanningScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('le lecteur lit le planning partagé, sans rien pour planifier', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(
      tester,
      role: UserRole.reader,
      reach: {'marie'},
      shared: {
        'marie': [meal('m1', 'marie', 'Poulet basquaise')],
      },
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Poulet basquaise'), findsOneWidget);
    expect(find.text('Plannings : Marie'), findsOneWidget);
    // L'étiquette du propriétaire, et rien de la mémoire des refus.
    expect(find.bySemanticsLabel(RegExp('Repas de Marie')), findsOneWidget);
    expect(find.textContaining('volaille'), findsNothing);
    // Ni création, ni menu, ni « Choisir une recette ».
    expect(find.text('Nouveau planning'), findsNothing);
    expect(find.byType(PopupMenuButton<PlanningMealAction>), findsNothing);
    expect(find.text('Choisir une recette'), findsNothing);
    semantics.dispose();
  });

  testWidgets('le lecteur sans groupe est invité à en rejoindre un', (
    tester,
  ) async {
    await pump(tester, role: UserRole.reader);

    expect(
      find.text('Vous ne faites partie d\'aucun groupe familial.'),
      findsOneWidget,
    );
    expect(find.text('Voir les groupes familiaux'), findsOneWidget);
  });

  testWidgets('le lecteur membre sans partage est renseigné, sans bouton', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      groups: [
        FamilyGroup(
          id: 'g1',
          name: 'Famille',
          ownerId: 'marie',
          memberIds: const ['marie', 'uid-test'],
          createdAt: DateTime.utc(2026),
        ),
      ],
    );

    expect(
      find.text('Aucun planning n\'est partagé avec vous.'),
      findsOneWidget,
    );
    expect(find.text('Voir les groupes familiaux'), findsNothing);
  });

  testWidgets('les anciens repas du lecteur : décochés, seul « Supprimer »', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      reach: {'marie'},
      mine: [meal('own', 'uid-test', 'Gratin')],
      shared: {
        'marie': [meal('m1', 'marie', 'Poulet basquaise')],
      },
    );

    expect(find.text('Gratin'), findsNothing);
    await tester.tap(find.text('Plannings : Marie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mon planning'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();

    expect(find.text('Gratin'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
    await tester.pumpAndSettle();
    expect(find.text('Supprimer'), findsOneWidget);
    expect(find.text('Changer la recette'), findsNothing);
  });

  testWidgets('l\'éditeur sans partage reçu : pas de sélecteur', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.editor,
      mine: [meal('own', 'uid-test', 'Gratin')],
    );

    expect(find.textContaining('Plannings :'), findsNothing);
    expect(find.text('Gratin'), findsOneWidget);
    expect(find.text('Nouveau planning'), findsOneWidget);
  });

  testWidgets('l\'éditeur : les partagés décochés par défaut', (tester) async {
    await pump(
      tester,
      role: UserRole.editor,
      reach: {'marie'},
      mine: [meal('own', 'uid-test', 'Gratin')],
      shared: {
        'marie': [meal('m1', 'marie', 'Poulet basquaise')],
      },
    );

    expect(find.text('Plannings : Moi'), findsOneWidget);
    expect(find.text('Poulet basquaise'), findsNothing);
    // Seul « Mon planning » : pas d'étiquette de propriétaire.
    expect(find.byIcon(Icons.person_outline), findsNothing);
  });

  testWidgets('une recette illisible garde son titre, sans s\'ouvrir', (
    tester,
  ) async {
    final m = PlannedMeal(
      id: 'm1',
      uid: 'marie',
      recipeId: 'secret',
      recipeTitre: 'Tarte secrète',
      plannedAt: DateTime(2026, 10, 12, 19),
      durationMinutes: 0,
      components: const [
        MealComponent(
          role: MealComponentRole.accompagnement,
          label: 'Kimchi',
          recipeId: 'kimchi',
        ),
      ],
      createdAt: DateTime(2026, 10, 1),
    );
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanningMealTile(
            meal: m,
            isPast: false,
            aiLoading: false,
            isWide: false,
            readOnly: true,
            ownerName: 'Marie',
            lockedRecipeIds: const {'secret', 'kimchi'},
            onTap: () => opened = true,
          ),
        ),
      ),
    );

    expect(find.text('Tarte secrète'), findsOneWidget);
    expect(find.text(kRecipeNotSharedLabel), findsOneWidget);
    expect(find.textContaining('Kimchi · $kRecipeNotSharedLabel'), findsOne);
    expect(find.byIcon(Icons.close), findsNothing);
    await tester.tap(find.text('Tarte secrète'));
    expect(opened, isFalse);
  });
}
