import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/admin/data/admin_repository.dart';
import 'package:kass_dalle/features/admin/data/invitations_repository.dart';
import 'package:kass_dalle/features/admin/domain/email_invitation.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/admin/presentation/admin_screen.dart';
import 'package:kass_dalle/features/admin/presentation/invitations_tab.dart';
import 'package:kass_dalle/features/admin/presentation/invite_by_email_screen.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/groups/domain/family_group.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';

/// Invitations par e-mail, vues du client : lecture du document, statut
/// effectif (expirée calculée à la lecture, fixture partagée avec le
/// serveur), sous-titre, onglet et formulaire.
class _FakeRepo implements InvitationsRepository {
  _FakeRepo(this.outcome, {this.invitations = const []});

  final InvitationOutcome outcome;
  final List<EmailInvitation> invitations;
  final calls = <Map<String, Object?>>[];

  @override
  Stream<List<EmailInvitation>> watchInvitations() => Stream.value(invitations);

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

/// Statut stocké → valeur de l'énumération Dart, pour la fixture.
const _wire = {
  'sent': EmailInvitationStatus.sent,
  'send_failed': EmailInvitationStatus.sendFailed,
  'accepted': EmailInvitationStatus.accepted,
  'cancelled': EmailInvitationStatus.cancelled,
  'expired': EmailInvitationStatus.expired,
};

void main() {
  group('statut effectif — fixture partagée avec le serveur', () {
    final fixture =
        jsonDecode(
              File(
                'test-fixtures/email_invitation_status.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    for (final raw in fixture['cases'] as List) {
      final c = raw as Map<String, dynamic>;
      test(c['name'] as String, () {
        final expires = c['expires_at'] as String?;
        final inv = EmailInvitation.fromFirestore('x', {
          'status': c['status'],
          if (expires != null)
            'expires_at': Timestamp.fromDate(DateTime.parse(expires)),
        });
        final status = inv.statusAt(DateTime.parse(c['now'] as String));
        expect(status, _wire[c['expected']]);
        expect(status.isPending, c['active']);
      });
    }
  });

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
      expect(EmailInvitationStatus.sent.canCopyLink, isTrue);
      expect(EmailInvitationStatus.expired.canCopyLink, isTrue);
      expect(EmailInvitationStatus.accepted.canCopyLink, isFalse);
      expect(EmailInvitationStatus.cancelled.canCopyLink, isFalse);
    });

    test('annulée par le serveur : adresse refusée', () {
      final inv = EmailInvitation.fromFirestore('a', {
        ..._doc(status: 'cancelled'),
        'cancelled_by': 'system',
        'last_error': 'Adresse refusée par Gmail : 550 5.1.1 m***@gmail.com',
      });
      expect(inv.cancelledBySystem, isTrue);
      expect(inv.statusAt(_now), EmailInvitationStatus.cancelled);
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
      'Lecteur · Les Kassbi · par Marie, le 05/10',
    );
  });

  test('sous-titre d\'une invitation acceptée par un compte révoqué', () {
    final inv = EmailInvitation.fromFirestore('a', {
      ..._doc(status: 'accepted'),
      'accepted_uid': 'gab',
      'accepted_at': Timestamp.fromDate(DateTime(2026, 10, 12)),
      'target': 'revoked',
      'target_uid': 'gab',
      'group_invite': 'invited',
    });
    expect(inv.targetsRevokedAccount, isTrue);
    expect(inv.targetUid, 'gab');
    expect(inv.groupInvite, 'invited');
    expect(
      invitationSubtitle(
        inv,
        EmailInvitationStatus.accepted,
        acceptedByName: 'Gabriel',
      ),
      'Lecteur · Les Kassbi · par Gabriel, le 12/10 · accès rétabli',
    );
    final full = EmailInvitation.fromFirestore('b', {
      ..._doc(status: 'accepted'),
      'target': 'revoked',
      'group_invite': 'full',
    });
    expect(
      invitationSubtitle(full, EmailInvitationStatus.accepted),
      'Lecteur · Les Kassbi · accès rétabli · pas invité au groupe, complet '
      '(50 invitations en attente) : invitez-le depuis Groupes familiaux '
      'quand une place se libère',
    );
    // Invitant sorti du groupe au retour du compte : rien d'écrit au groupe,
    // qui existe toujours.
    final left = EmailInvitation.fromFirestore('d', {
      ..._doc(status: 'accepted'),
      'target': 'revoked',
      'group_invite': 'missing',
      'group_missing': false,
    });
    expect(
      invitationSubtitle(left, EmailInvitationStatus.accepted),
      'Lecteur · Les Kassbi · accès rétabli · pas invité au groupe '
      "(l'invitant n'en fait plus partie) : invitez-le depuis Groupes "
      'familiaux',
    );
    final gone = EmailInvitation.fromFirestore('e', {
      ..._doc(status: 'accepted'),
      'target': 'revoked',
      'group_invite': 'missing',
      'group_missing': true,
    });
    expect(
      invitationSubtitle(gone, EmailInvitationStatus.accepted),
      'Lecteur · Les Kassbi · accès rétabli · groupe supprimé',
    );
    // En attente, la ligne dit que le compte visé est révoqué.
    final pending = EmailInvitation.fromFirestore('f', {
      ..._doc(),
      'target': 'revoked',
      'target_uid': 'gab',
    });
    for (final status in [
      EmailInvitationStatus.sent,
      EmailInvitationStatus.sendFailed,
      EmailInvitationStatus.expired,
    ]) {
      expect(
        invitationSubtitle(pending, status),
        endsWith(' · compte révoqué'),
        reason: status.name,
      );
    }
    expect(
      invitationSubtitle(pending, EmailInvitationStatus.sent),
      'Lecteur · Les Kassbi · envoyée le 02/10, expire le 01/11 · compte '
      'révoqué',
    );
    // Invitation antérieure au champ : compte neuf.
    expect(
      EmailInvitation.fromFirestore('c', _doc()).targetsRevokedAccount,
      isFalse,
    );
  });

  test('compte révoqué : reconnu sans casse, jamais un compte actif', () {
    AppUser user(String email, {bool revoked = false}) => AppUser(
      uid: email,
      email: email,
      displayName: '',
      role: UserRole.reader,
      createdAt: DateTime(2026),
      lastSeenAt: DateTime(2026),
      isRevoked: revoked,
    );
    final users = [
      user('gabriel@gmail.com', revoked: true),
      user('marie@gmail.com'),
    ];
    expect(isRevokedAccountEmail(users, ' Gabriel@Gmail.com '), isTrue);
    expect(isRevokedAccountEmail(users, 'marie@gmail.com'), isFalse);
    expect(isRevokedAccountEmail(users, ''), isFalse);
    expect(isRevokedAccountEmail(users, 'inconnu@gmail.com'), isFalse);
  });

  test('pied de l\'e-mail et message de succès d\'un compte révoqué', () {
    expect(
      invitationAccountLine(
        toEmail: 'gabriel@gmail.com',
        groupName: 'Les Kassbi',
        restoresAccess: true,
      ),
      'Connecte-toi avec le compte Google gabriel@gmail.com : ton accès sera '
      'rétabli, et l\'invitation au groupe « Les Kassbi » t\'attendra dans '
      'Groupes familiaux.',
    );
    expect(
      invitationAccountLine(
        toEmail: 'marie@gmail.com',
        groupName: 'Les Kassbi',
        restoresAccess: false,
      ),
      'Connecte-toi avec le compte Google marie@gmail.com. Avec une autre '
      'adresse, ton accès devra être validé à la main.',
    );
    final back = InvitationOutcome.fromMap({
      'status': 'sent',
      'invitationId': 'i1',
      'target': 'revoked',
    });
    expect(back.restoresAccess, isTrue);
    expect(
      invitationSentMessage('gabriel@gmail.com', back),
      'Invitation envoyée à gabriel@gmail.com — accès rétabli à sa prochaine '
      'connexion.',
    );
    expect(
      invitationSentMessage(
        'marie@gmail.com',
        InvitationOutcome.fromMap({'status': 'sent', 'target': 'new'}),
      ),
      'Invitation envoyée à marie@gmail.com.',
    );
    expect(
      invitationResentMessage('gabriel@gmail.com', back),
      'Invitation renvoyée à gabriel@gmail.com — accès rétabli à sa prochaine '
      'connexion.',
    );
    expect(
      invitationResentMessage(
        'marie@gmail.com',
        InvitationOutcome.fromMap({'status': 'sent', 'target': 'new'}),
      ),
      'Invitation renvoyée à marie@gmail.com.',
    );
    expect(
      kRevokedAccountHelper,
      'Ce compte est révoqué. Son accès sera rétabli à sa prochaine connexion '
      'avec cette adresse.',
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
      List<FamilyGroup>? groups,
      Stream<List<FamilyGroup>>? groupsStream,
      required InvitationOutcome outcome,
      bool settle = true,
      List<AppUser> users = const [],
    }) async {
      final repo = _FakeRepo(outcome);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUserProvider.overrideWith((ref) => Stream.value(me)),
            myGroupsProvider.overrideWith(
              (ref) => groupsStream ?? Stream.value(groups ?? const []),
            ),
            invitationsRepositoryProvider.overrideWithValue(repo),
            allUsersProvider.overrideWith((ref) => Stream.value(users)),
          ],
          child: const MaterialApp(home: InviteByEmailScreen()),
        ),
      );
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
      return repo;
    }

    Future<void> tapSend(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Envoyer l\'invitation'));
      await tester.tap(find.text('Envoyer l\'invitation'));
      await tester.pumpAndSettle();
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

    testWidgets('compte révoqué : aide sous l\'adresse et aperçu adaptés', (
      tester,
    ) async {
      final gabriel = AppUser(
        uid: 'gab',
        email: 'Gabriel@gmail.com',
        displayName: 'Gabriel',
        role: UserRole.reader,
        createdAt: DateTime(2026),
        lastSeenAt: DateTime(2026),
        isRevoked: true,
      );
      await pump(
        tester,
        groups: [group],
        users: [me, gabriel],
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      expect(find.text(kRevokedAccountHelper), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'gabriel@gmail.com');
      await tester.pumpAndSettle();
      expect(find.text(kRevokedAccountHelper), findsOneWidget);
      expect(find.text('Choisissez un groupe.'), findsNothing);
      expect(
        find.text(
          'Il devra accepter l\'invitation au groupe dans Groupes familiaux.',
        ),
        findsOneWidget,
      );
      // Un compte actif ne déclenche pas l'aide.
      await tester.enterText(find.byType(TextField).first, 'fred@gmail.com');
      await tester.pumpAndSettle();
      expect(find.text(kRevokedAccountHelper), findsNothing);
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
      expect(find.text('Ouvrir Groupes familiaux'), findsOneWidget);
    });

    testWidgets('groupes en chargement : champ désactivé, envoi impossible', (
      tester,
    ) async {
      final pending = StreamController<List<FamilyGroup>>();
      addTearDown(pending.close);
      await pump(
        tester,
        groupsStream: pending.stream,
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
        settle: false,
      );
      expect(find.text('Chargement des groupes…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Envoyer l\'invitation'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('groupes illisibles : erreur affichée, pas « aucun groupe »', (
      tester,
    ) async {
      await pump(
        tester,
        groupsStream: Stream.error(Exception('permission-denied')),
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      expect(find.text('Groupes illisibles'), findsOneWidget);
      expect(find.textContaining('aucun groupe'), findsNothing);
    });

    testWidgets('validation au clic : adresse vide, groupe non choisi', (
      tester,
    ) async {
      final other = FamilyGroup(
        id: 'g2',
        name: 'Les Voisins',
        ownerId: 'admin',
        memberIds: const ['admin'],
        createdAt: DateTime(2026),
      );
      final repo = await pump(
        tester,
        groups: [group, other],
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Envoyer l\'invitation'),
      );
      expect(button.onPressed, isNotNull);
      await tapSend(tester);
      expect(repo.calls, isEmpty);
      expect(find.text('Saisissez une adresse e-mail.'), findsOneWidget);
      expect(find.text('Choisissez un groupe.'), findsOneWidget);
    });

    testWidgets('Entrée dans l\'adresse envoie l\'invitation', (tester) async {
      final repo = await pump(
        tester,
        groups: [group],
        outcome: const InvitationOutcome(
          kind: InvitationOutcomeKind.refused,
          message: 'Refus.',
          field: 'email',
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'marie@gmail.com');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(repo.calls.single['email'], 'marie@gmail.com');
    });

    testWidgets('Ctrl+S envoie l\'invitation', (tester) async {
      final repo = await pump(
        tester,
        groups: [group],
        outcome: const InvitationOutcome(
          kind: InvitationOutcomeKind.refused,
          message: 'Refus.',
          field: 'email',
        ),
      );
      await tester.enterText(find.byType(TextField).first, 'marie@gmail.com');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(repo.calls.single['email'], 'marie@gmail.com');
    });

    testWidgets('aperçu grand écran : suit chaque frappe du message', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(
        tester,
        groups: [group],
        outcome: const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      );
      final message = find.byType(TextField).at(1);
      await tester.enterText(message, 'Salut');
      await tester.pump();
      expect(find.text('Salut'), findsWidgets);
      await tester.enterText(message, 'Salut Marie');
      await tester.pump();
      // Le champ et l'aperçu.
      expect(find.text('Salut Marie'), findsNWidgets(2));
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
      expect(find.text('Lui donner le rôle (sans groupe)'), findsOneWidget);
      expect(
        find.textContaining('invitez-le depuis Groupes familiaux'),
        findsOneWidget,
      );
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

  testWidgets('onglets lisibles à 360 dp', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final users = [
      for (var i = 0; i < 12; i++)
        AppUser(
          uid: 'u$i',
          email: 'u$i@gmail.com',
          displayName: 'U$i',
          role: UserRole.reader,
          createdAt: DateTime(2026),
          lastSeenAt: DateTime(2026),
        ),
    ];
    final repo = _FakeRepo(
      const InvitationOutcome(kind: InvitationOutcomeKind.sent),
      invitations: [
        for (var i = 0; i < 12; i++)
          EmailInvitation.fromFirestore(
            'i$i',
            _doc(expiresAt: DateTime.now().add(const Duration(days: 3))),
          ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appUserProvider.overrideWith((ref) => Stream.value(users.first)),
          allUsersProvider.overrideWith((ref) => Stream.value(users)),
          adminRepositoryProvider.overrideWithValue(
            AdminRepository(firestore: FakeFirebaseFirestore()),
          ),
          invitationsRepositoryProvider.overrideWithValue(repo),
        ],
        child: const MaterialApp(home: AdminScreen()),
      ),
    );
    await tester.pumpAndSettle();
    // La police de test (carrés de la taille du corps) ne mesure pas comme
    // Roboto : on vérifie les libellés courts et l'absence d'erreur de mise
    // en page, pas la largeur au pixel.
    expect(find.text('Comptes (12)'), findsOneWidget);
    expect(find.text('Invitations (12)'), findsOneWidget);
    expect(find.textContaining('en attente)'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
