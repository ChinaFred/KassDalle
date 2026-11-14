import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';
import 'package:kass_dalle/features/groups/presentation/groups_screen.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/presentation/planning_providers.dart';

/// « Groupes familiaux » : le groupe par défaut pour planifier (ticket 239).
class _FakePlanning extends PlanningRepository {
  _FakePlanning() : super(FakeFirebaseFirestore(), 'moi');

  final saved = <String>[];
  Object? saveError;

  @override
  Future<void> saveDefaultPlanningTarget(String key) async {
    final error = saveError;
    if (error != null) throw error;
    saved.add(key);
  }
}

class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
    String? userId,
    String? jobId,
  }) async {
    features.add(feature);
    return 'r';
  }
}

final _errors = _RecordingErrorReportService();

FamilyGroup _group(String id, String name, {String owner = 'moi'}) =>
    FamilyGroup(
      id: id,
      name: name,
      ownerId: owner,
      memberIds: const ['moi', 'marie'],
      createdAt: DateTime.utc(2026),
    );

void main() {
  final me = AppUser(
    uid: 'moi',
    email: 'moi@example.com',
    displayName: 'Moi',
    role: UserRole.editor,
    createdAt: DateTime.utc(2026),
    lastSeenAt: DateTime.utc(2026),
  );
  final dupont = _group('gd', 'Dupont');
  final cousins = _group('gc', 'Cousins', owner: 'marie');

  Future<_FakePlanning> pump(
    WidgetTester tester, {
    String? stored,
    List<FamilyGroup> owned = const [],
  }) async {
    final planning = _FakePlanning();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUserProvider.overrideWith((ref) => Stream.value(me)),
          myGroupsProvider.overrideWith(
            (ref) => Stream.value([dupont, cousins]),
          ),
          myInvitationsProvider.overrideWith((ref) => Stream.value(const [])),
          maskedGroupIdsProvider.overrideWith((ref) => Stream.value(const {})),
          groupEmailInvitationsProvider.overrideWith(
            (ref, _) => Stream.value(const []),
          ),
          planningRepositoryProvider.overrideWithValue(planning),
          errorReportServiceProvider.overrideWithValue(_errors),
          planningPreferencesProvider.overrideWith(
            (ref) => Stream.value(
              PlanningPreferences(defaultPlanningTarget: stored),
            ),
          ),
          ownedPlanningGroupsProvider.overrideWith((ref) => AsyncData(owned)),
        ],
        child: const MaterialApp(home: GroupsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return planning;
  }

  Future<void> openMenu(WidgetTester tester, String name) async {
    final tile = find.ancestor(
      of: find.text(name),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: tile.first, matching: find.byIcon(Icons.more_vert)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('groupe possédé : « Utiliser par défaut pour planifier » '
      'enregistre le groupe et l\'annonce', (tester) async {
    final planning = await pump(tester, owned: [dupont]);
    expect(find.text('2 membre(s)'), findsNWidgets(2));
    expect(find.byIcon(Icons.star), findsNothing);

    await openMenu(tester, 'Dupont');
    expect(find.text('Utiliser par défaut pour planifier'), findsOneWidget);
    await tester.tap(find.text('Utiliser par défaut pour planifier'));
    await tester.pumpAndSettle();

    expect(planning.saved, ['gd']);
    expect(
      find.text('« Dupont » sera proposé par défaut pour planifier.'),
      findsOneWidget,
    );
  });

  testWidgets('groupe d\'un autre : l\'action n\'apparaît pas', (tester) async {
    await pump(tester, owned: [dupont]);
    await openMenu(tester, 'Cousins');
    expect(find.text('Utiliser par défaut pour planifier'), findsNothing);
    expect(find.text('Ne plus utiliser par défaut'), findsNothing);
  });

  testWidgets('groupe par défaut : « Par défaut », l\'étoile, et « Ne plus '
      'utiliser par défaut » rend « Mon planning »', (tester) async {
    final planning = await pump(tester, stored: 'gd', owned: [dupont]);
    expect(find.text('Par défaut · 2 membre(s)'), findsOneWidget);
    expect(find.byTooltip('Groupe par défaut pour planifier'), findsOneWidget);

    await openMenu(tester, 'Dupont');
    await tester.tap(find.text('Ne plus utiliser par défaut'));
    await tester.pumpAndSettle();
    expect(planning.saved, ['personal']);
    expect(
      find.text('« Mon planning » sera proposé par défaut pour planifier.'),
      findsOneWidget,
    );
  });

  testWidgets('défaut sur un groupe où l\'on ne planifie plus : aucune '
      'marque', (tester) async {
    await pump(tester, stored: 'gd');
    expect(find.textContaining('Par défaut'), findsNothing);
    expect(find.byIcon(Icons.star), findsNothing);
  });

  testWidgets('échec d\'écriture : le message, réglage inchangé', (
    tester,
  ) async {
    final planning = await pump(tester, owned: [dupont]);
    planning.saveError = StateError('hors ligne');
    await openMenu(tester, 'Dupont');
    await tester.tap(find.text('Utiliser par défaut pour planifier'));
    await tester.pumpAndSettle();
    expect(planning.saved, isEmpty);
    expect(_errors.features, contains('groups.defaultPlanningTarget'));
    expect(
      find.text('Le groupe par défaut n\'a pas pu être enregistré.'),
      findsOneWidget,
    );
  });
}
