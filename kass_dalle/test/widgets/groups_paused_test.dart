import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:kass_dalle/core/router/app_router.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/groups/presentation/group_members_screen.dart';
import 'package:kass_dalle/features/groups/presentation/groups_screen.dart';

import '../support/test_backend.dart';

/// Groupe en pause dans l'écran Groupes : listé, marqué « En pause », géré
/// par son propriétaire lecteur dans la mesure de ses droits.
void main() {
  FamilyGroup group({required String owner}) => FamilyGroup(
    id: 'gd',
    name: 'Famille Dupont',
    ownerId: owner,
    memberIds: {owner, 'uid-test', 'paul'}.toList(),
    invitedIds: const ['zoe'],
    createdAt: DateTime.utc(2026),
  );

  Future<void> pump(
    WidgetTester tester,
    FamilyGroup paused, {
    String initialLocation = AppRoutes.groups,
  }) async {
    final backend = TestBackend(
      user: testUser(role: UserRole.reader),
      pausedGroups: [paused],
    );
    await tester.pumpWidget(
      ProviderScope(
        retry: appProviderRetry,
        overrides: [
          ...backend.overrides,
          memberNameProvider.overrideWith((ref, uid) => 'Marie'),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(
                path: AppRoutes.groups,
                builder: (_, _) => const GroupsScreen(),
              ),
              GoRoute(
                path: AppRoutes.groupMembers,
                builder: (_, state) => GroupMembersScreen(
                  groupId: state.pathParameters['groupId']!,
                ),
              ),
            ],
            initialLocation: initialLocation,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('le propriétaire lecteur garde son groupe en pause', (
    tester,
  ) async {
    await pump(tester, group(owner: 'uid-test'));

    expect(find.text('Famille Dupont'), findsOneWidget);
    expect(
      find.text('En pause · 2 membre(s) · 1 invitation(s) en attente'),
      findsOneWidget,
    );
    expect(find.textContaining('est en pause.'), findsNothing);
    expect(find.textContaining('aucun groupe'), findsNothing);
    expect(find.byTooltip('Renommer'), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Gérer les membres'), findsOneWidget);
    expect(find.text('Supprimer le groupe'), findsOneWidget);

    await tester.tap(find.text('Gérer les membres'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining(
        'Ce groupe est en pause : son planning n\'apparaît plus tant que '
        'vous n\'êtes pas éditeur.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('un membre voit le groupe en pause et peut le quitter', (
    tester,
  ) async {
    await pump(tester, group(owner: 'marie'));

    expect(find.text('En pause · 3 membre(s)'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    expect(find.text('Quitter le groupe'), findsOneWidget);
  });

  testWidgets('la page d\'un groupe s\'ouvre en plein écran et revient', (
    tester,
  ) async {
    await pump(tester, group(owner: 'uid-test'));

    await tester.tap(find.text('Famille Dupont'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupMembersScreen), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Membres'), findsOneWidget);

    await tester.tap(find.byTooltip('Retour aux groupes'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupMembersScreen), findsNothing);
    expect(find.byType(GroupsScreen), findsOneWidget);
  });

  testWidgets('un groupe inconnu affiche « Groupe introuvable »', (
    tester,
  ) async {
    await pump(
      tester,
      group(owner: 'uid-test'),
      initialLocation: AppRoutes.groupMembersPath('inconnu'),
    );

    expect(find.text('Groupe introuvable'), findsOneWidget);
    await tester.tap(find.text('Retour aux groupes'));
    await tester.pumpAndSettle();
    expect(find.byType(GroupsScreen), findsOneWidget);
  });
}
