import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/admin/data/invitations_repository.dart';
import 'package:kass_dalle/features/admin/domain/email_invitation.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/admin/presentation/invitations_tab.dart';
import 'package:kass_dalle/features/admin/presentation/invite_by_email_screen.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';

/// Invitations par e-mail, vues du client : lecture du document, statut
/// effectif (expirée calculée à la lecture), sous-titre, et formulaire.
class _FakeRepo implements InvitationsRepository {
  _FakeRepo(this.outcome);

  final InvitationOutcome outcome;
  final calls = <Map<String, Object?>>[];

  @override
  Stream<List<EmailInvitation>> watchInvitations() => Stream.value(const []);

  @override
  Future<InvitationOutcome> create({
    required String email,
    required UserRole role,
    required String groupId,
    required String message,
  }) async {
    calls.add({
      'email': email,
      'role': role,
      'groupId': groupId,
      'message': message,
    });
    return outcome;
  }

  @override
  Future<InvitationOutcome> resend(String invitationId) async => outcome;

  @override
  Future<InvitationOutcome> cancel(String invitationId) async => outcome;
}

final _now = DateTime(2026, 10, 12, 10);

Map<String, dynamic> _doc({
  String status = 'sent',
  DateTime? expiresAt,
  Object? role = 'reader',
}) => {
  'email': 'marie@gmail.com',
  'email_key': 'marie@gmail.com',
  'role': role,
  'group_id': 'g1',
  'group_name': 'Les Kassbi',
  'message': 'Viens !',
  'invited_by': 'admin',
  'invited_by_name': 'Fred',
  'status': status,
  'created_at': Timestamp.fromDate(DateTime(2026, 10, 2)),
  'last_sent_at': Timestamp.fromDate(DateTime(2026, 10, 2)),
  'expires_at': Timestamp.fromDate(expiresAt ?? DateTime(2026, 11, 1)),
  'send_count': 1,
  'last_error': null,
};

void main() {
  group('EmailInvitation.fromFirestore', () {
    test('lit les champs du serveur', () {
      final inv = EmailInvitation.fromFirestore('i1', _doc(role: 'editor'));
      expect(inv.email, 'marie@gmail.com');
      expect(inv.role, UserRole.editor);
      expect(inv.groupName, 'Les Kassbi');
      expect(inv.lastSentAt, DateTime(2026, 10, 2));
      expect(inv.sendCount, 1);
      expect(inv.lastError, isNull);
    });

    test('un document mal formé ne lève pas', () {
      final inv = EmailInvitation.fromFirestore('i2', {
        'role': 42,
        'send_count': 'x',
      });
      expect(inv.email, '');
      expect(inv.role, UserRole.reader);
      expect(inv.sendCount, 0);
      expect(inv.statusAt(_now), EmailInvitationStatus.expired);
    });
  });

  group('statut effectif', () {
    test('envoyée, échec, expirée, acceptée, annulée', () {
      EmailInvitationStatus at(Map<String, dynamic> d) =>
          EmailInvitation.fromFirestore('x', d).statusAt(_now);
      expect(at(_doc()), EmailInvitationStatus.sent);
      expect(at(_doc(status: 'send_failed')), EmailInvitationStatus.sendFailed);
      expect(
        at(_doc(expiresAt: DateTime(2026, 10, 1))),
        EmailInvitationStatus.expired,
      );
      expect(
        at(_doc(status: 'send_failed', expiresAt: DateTime(2026, 10, 1))),
        EmailInvitationStatus.expired,
      );
      expect(
        at(_doc(status: 'accepted', expiresAt: DateTime(2026, 10, 1))),
        EmailInvitationStatus.accepted,
      );
      expect(at(_doc(status: 'cancelled')), EmailInvitationStatus.cancelled);
    });

    test('actions permises', () {
      expect(EmailInvitationStatus.sent.canCancel, isTrue);
      expect(EmailInvitationStatus.expired.canResend, isTrue);
      expect(EmailInvitationStatus.expired.canCancel, isFalse);
      expect(EmailInvitationStatus.accepted.canResend, isFalse);
      expect(EmailInvitationStatus.cancelled.isPending, isFalse);
    });

    test('compte des invitations en attente', () {
      final list = [
        EmailInvitation.fromFirestore('a', _doc()),
        EmailInvitation.fromFirestore('b', _doc(status: 'send_failed')),
        EmailInvitation.fromFirestore('c', _doc(status: 'accepted')),
        EmailInvitation.fromFirestore(
          'd',
          _doc(expiresAt: DateTime(2026, 10, 1)),
        ),
      ];
      expect(pendingInvitationCount(list, _now), 2);
    });
  });

  test('sous-titre d\'une invitation en attente', () {
    final inv = EmailInvitation.fromFirestore('a', _doc());
    expect(
      invitationSubtitle(inv, EmailInvitationStatus.sent),
      'Lecteur · Les Kassbi · envoyée le 02/10, expire le 01/11',
    );
  });

  test('sous-titre d\'une invitation acceptée', () {
    final inv = EmailInvitation.fromFirestore('a', {
      ..._doc(status: 'accepted'),
      'accepted_uid': 'u1',
      'accepted_at': Timestamp.fromDate(DateTime(2026, 10, 5)),
    });
    expect(
      invitationSubtitle(
        inv,
        EmailInvitationStatus.accepted,
        acceptedByName: 'Marie',
      ),
      'Lecteur · Les Kassbi · acceptée par Marie, le 05/10',
    );
  });

  test('message par défaut et contrôle de forme', () {
    expect(
      defaultInvitationMessage('Les Kassbi'),
      'Je t\'invite dans mon groupe familial « Les Kassbi » sur Kass\'Dalle, '
      'pour suivre et noter tes repas préférés. Tu auras aussi accès aux '
      'recettes que le groupe partage.',
    );
    expect(looksLikeEmail(' marie@gmail.com '), isTrue);
    expect(looksLikeEmail('marie@gmail'), isFalse);
    expect(looksLikeEmail('ma rie@gmail.com'), isFalse);
  });

  test('réponse du serveur', () {
    final refused = InvitationOutcome.fromMap({
      'status': 'refused',
      'reason': 'account_pending',
      'message': 'Ce compte attend déjà un rôle.',
      'field': 'email',
      'existingUid': 'u9',
    });
    expect(refused.kind, InvitationOutcomeKind.refused);
    expect(refused.existingUid, 'u9');
    expect(
      InvitationOutcome.fromMap({'status': 'send_failed', 'error': 'x'}).kind,
      InvitationOutcomeKind.sendFailed,
    );
  });

  group('formulaire', () {
    final me = AppUser(
      uid: 'admin',
      email: 'fred@gmail.com',
      displayName: 'Fred',
      role: UserRole.admin,
      createdAt: DateTime(2026),
      lastSeenAt: DateTime(2026),
    );

    Future<_FakeRepo> pump(
      WidgetTester tester, {
      required List<FamilyGroup> groups,
      required InvitationOutcome outcome,
    }) async {
      final repo = _FakeRepo(outcome);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUserProvider.overrideWith((ref) => Stream.value(me)),
            myGroupsProvider.overrideWith((ref) => Stream.value(groups)),
            invitationsRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: InviteByEmailScreen()),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    final group = FamilyGroup(
      id: 'g1',
      name: 'Les Kassbi',
      ownerId: 'admin',
      memberIds: const ['admin'],
      createdAt: DateTime(2026),
    );

    testWidgets('un seul groupe : présélectionné, nom dans le message', (
      tester,
    ) async {
      await pump(
        tester,
        groups: [group],
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      expect(find.text('Les Kassbi'), findsWidgets);
      expect(
        find.textContaining('groupe familial « Les Kassbi »'),
        findsWidgets,
      );
    });

    testWidgets('aucun groupe : message et envoi impossible', (tester) async {
      await pump(
        tester,
        groups: const [],
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      expect(
        find.text(
          'Vous n\'appartenez à aucun groupe. Créez-en un dans Groupes '
          'familiaux.',
        ),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).first, 'marie@gmail.com');
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Envoyer l\'invitation'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('refus du serveur affiché sous l\'adresse', (tester) async {
      final repo = await pump(
        tester,
        groups: [group],
        outcome: const InvitationOutcome(
          kind: InvitationOutcomeKind.refused,
          reason: 'account_pending',
          message: 'Ce compte attend déjà un rôle.',
          field: 'email',
          existingUid: 'u9',
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'marie@gmail.com');
      await tester.pump();
      await tester.ensureVisible(find.text('Envoyer l\'invitation'));
      await tester.tap(find.text('Envoyer l\'invitation'));
      await tester.pumpAndSettle();
      expect(repo.calls.single['groupId'], 'g1');
      expect(repo.calls.single['role'], UserRole.reader);
      expect(find.text('Ce compte attend déjà un rôle.'), findsOneWidget);
      expect(find.text('Lui donner ce rôle maintenant'), findsOneWidget);
    });

    testWidgets('adresse mal formée : refusée sans appel au serveur', (
      tester,
    ) async {
      final repo = await pump(
        tester,
        groups: [group],
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      await tester.enterText(find.byType(TextField).first, 'marie@gmail');
      await tester.pump();
      await tester.ensureVisible(find.text('Envoyer l\'invitation'));
      await tester.tap(find.text('Envoyer l\'invitation'));
      await tester.pumpAndSettle();
      expect(repo.calls, isEmpty);
      expect(find.text('Adresse e-mail invalide.'), findsOneWidget);
    });
  });
}
