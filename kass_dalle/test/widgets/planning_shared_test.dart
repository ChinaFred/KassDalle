import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:kass_dalle/core/widgets/app_states.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_reach.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';
import 'package:kass_dalle/features/planning/presentation/planning_screen.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';

import '../support/test_backend.dart';

/// Plannings partagés, vus de l'écran du planning : le lecteur lit, ne
/// planifie pas ; l'éditeur voit son planning seul par défaut.
void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  PlannedMeal meal(
    String id,
    String uid,
    String titre, {
    int hour = 19,
    String? groupId,
  }) {
    final now = DateTime.now();
    return PlannedMeal(
      id: id,
      uid: uid,
      groupId: groupId,
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
    Set<String> groupReach = const {},
    Object? reachError,
    Map<String, List<PlannedMeal>> shared = const {},
    Map<String, List<PlannedMeal>> groupMeals = const {},
    Set<String> failingGroups = const {},
    List<PlannedMeal> mine = const [],
    List<FamilyGroup> groups = const [],
    List<FamilyGroup> pausedGroups = const [],
    Size size = const Size(360, 800),
  }) async {
    final backend = TestBackend(
      user: testUser(role: role),
      plannedMeals: mine,
      groups: groups,
      pausedGroups: pausedGroups,
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
          planningReachProvider.overrideWith(
            (ref) => reachError == null
                ? Stream.value(
                    PlanningReach(
                      uids: reach,
                      groupIds: groupReach,
                      maskedGroupIds: const {},
                    ),
                  )
                : Stream.error(reachError),
          ),
          sharedPlannedMealsProvider.overrideWith(
            (ref, uid) => Stream.value(shared[uid] ?? const []),
          ),
          groupPlannedMealsProvider.overrideWith(
            (ref, key) => failingGroups.contains(key.groupId)
                ? Stream.error(StateError('planning du groupe illisible'))
                : Stream.value(groupMeals[key.groupId] ?? const []),
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

  testWidgets('les anciens repas du lecteur : décochés, en lecture seule', (
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
    // Les règles refusent au lecteur toute écriture, suppression comprise :
    // aucun menu d'action sur ses anciens repas.
    expect(find.byType(PopupMenuButton<PlanningMealAction>), findsNothing);
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

  testWidgets('le lecteur sans partage qui garde d\'anciens repas est guidé', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      mine: [meal('own', 'uid-test', 'Gratin')],
    );

    expect(
      find.textContaining('Cochez « Mon planning » pour revoir vos anciens'),
      findsOneWidget,
    );
  });

  testWidgets('une portée illisible n\'est pas une portée vide', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      reachError: StateError('portée illisible'),
    );

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(
      find.text('Vous ne faites partie d\'aucun groupe familial.'),
      findsNothing,
    );
  });

  // ── Plannings de groupe ────────────────────────────────────────────────

  FamilyGroup dupont({String owner = 'marie'}) => FamilyGroup(
    id: 'gd',
    name: 'Famille Dupont',
    ownerId: owner,
    memberIds: {owner, 'uid-test', 'paul', 'zoe'}.toList(),
    createdAt: DateTime.utc(2026),
  );

  testWidgets('le membre lecteur lit le planning du groupe, sans action', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pump(
      tester,
      role: UserRole.reader,
      groups: [dupont()],
      groupReach: {'gd'},
      groupMeals: {
        'gd': [meal('g1', 'marie', 'Hachis parmentier', groupId: 'gd')],
      },
    );

    expect(tester.takeException(), isNull);
    // Le planning du groupe est coché par défaut : pas d'état « aucun
    // planning partagé ».
    expect(find.text('Aucun planning n\'est partagé avec vous.'), findsNothing);
    expect(find.text('Hachis parmentier'), findsOneWidget);
    expect(find.text('Plannings : Famille Dupont'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Repas du groupe Famille Dupont')),
      findsOneWidget,
    );
    expect(find.byType(PopupMenuButton<PlanningMealAction>), findsNothing);
    expect(find.text('Choisir une recette'), findsNothing);
    semantics.dispose();
  });

  testWidgets('le sélecteur nomme le groupe et son organisateur', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      groups: [dupont()],
      groupReach: {'gd'},
    );

    await tester.tap(find.text('Plannings : Famille Dupont'));
    await tester.pumpAndSettle();
    expect(find.text('Famille Dupont'), findsOneWidget);
    expect(
      find.text('Planning du groupe · organisé par Marie'),
      findsOneWidget,
    );
  });

  testWidgets('le propriétaire : une ligne vide par planning où il planifie', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.editor,
      groups: [dupont(owner: 'uid-test')],
      groupReach: {'gd'},
      mine: [meal('own', 'uid-test', 'Gratin')],
    );

    // Aujourd'hui : mon repas est là, le groupe n'a rien.
    expect(find.text('Gratin'), findsOneWidget);
    expect(find.text('Rien de prévu pour Famille Dupont'), findsWidgets);
    // Les autres jours : les deux plannings sont vides.
    expect(find.text('Rien de prévu pour vous'), findsWidgets);
  });

  testWidgets('le propriétaire a toutes les actions sur un repas du groupe', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.editor,
      groups: [dupont(owner: 'uid-test')],
      groupReach: {'gd'},
      groupMeals: {
        'gd': [meal('g1', 'uid-test', 'Hachis parmentier', groupId: 'gd')],
      },
    );

    expect(find.text('Hachis parmentier'), findsOneWidget);
    expect(find.byType(PopupMenuButton<PlanningMealAction>), findsOneWidget);
    // Le repas du groupe ne remplit pas « Mon planning ».
    expect(find.text('Rien de prévu pour vous'), findsWidgets);
  });

  testWidgets('un planning de groupe illisible est dit sous son nom', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      groups: [dupont()],
      groupReach: {'gd'},
      failingGroups: {'gd'},
    );

    expect(
      find.text('Le planning du groupe Famille Dupont n\'a pas pu être lu.'),
      findsOneWidget,
    );
    expect(find.text('Réessayer'), findsWidgets);
  });

  testWidgets('le propriétaire rétrogradé lit que son groupe est en pause', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.reader,
      pausedGroups: [dupont(owner: 'uid-test')],
    );

    expect(
      find.text('Votre groupe Famille Dupont est en pause.'),
      findsOneWidget,
    );
    expect(
      find.text('Il reviendra quand vous serez de nouveau éditeur.'),
      findsOneWidget,
    );
    expect(
      find.text('Vous ne faites partie d\'aucun groupe familial.'),
      findsNothing,
    );
  });

  testWidgets('un membre lit que le groupe d\'un proche est en pause', (
    tester,
  ) async {
    await pump(tester, role: UserRole.reader, pausedGroups: [dupont()]);

    expect(find.text('Le groupe Famille Dupont est en pause.'), findsOneWidget);
    expect(
      find.textContaining(
        'Marie, qui en est propriétaire, n\'est plus éditeur',
      ),
      findsOneWidget,
    );
    expect(find.text('Voir les groupes familiaux'), findsNothing);
    expect(find.text('Aucun planning n\'est partagé avec vous.'), findsNothing);
  });

  testWidgets('« Nouveau planning » demande pour qui au propriétaire', (
    tester,
  ) async {
    await pump(
      tester,
      role: UserRole.editor,
      groups: [dupont(owner: 'uid-test')],
      groupReach: {'gd'},
      mine: [meal('own', 'uid-test', 'Gratin')],
    );

    await tester.tap(find.text('Nouveau planning'));
    await tester.pumpAndSettle();
    expect(find.text('Planifier pour…'), findsOneWidget);
    expect(find.text('Mon planning'), findsOneWidget);
    expect(find.text('Famille Dupont'), findsWidgets);
    expect(find.text('Planning du groupe · 3 membres'), findsOneWidget);
  });
}
