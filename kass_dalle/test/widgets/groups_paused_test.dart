import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
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

  Future<void> pump(WidgetTester tester, FamilyGroup paused) async {
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
        child: const MaterialApp(home: GroupsScreen()),
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
}
