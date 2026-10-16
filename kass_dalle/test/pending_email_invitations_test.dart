import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/email_invitation.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/groups/presentation/group_providers.dart';

EmailInvitation _inv(
  String email,
  String status, {
  DateTime? expires,
  DateTime? created,
}) => EmailInvitation(
  id: email,
  email: email,
  role: _reader,
  groupId: 'g1',
  groupName: 'Famille',
  message: '',
  invitedBy: 'u',
  invitedByName: 'U',
  storedStatus: status,
  expiresAt: expires,
  createdAt: created,
);

const _reader = UserRole.reader;

void main() {
  final now = DateTime.utc(2026, 10, 16, 12);
  final future = now.add(const Duration(days: 5));
  final past = now.subtract(const Duration(days: 1));

  test('garde envoyée et envoi échoué non expirées, écarte le reste', () {
    final result = pendingEmailInvitations([
      _inv('a@x.fr', 'sent', expires: future),
      _inv('b@x.fr', 'send_failed', expires: future),
      _inv('c@x.fr', 'sent', expires: past),
      _inv('d@x.fr', 'accepted', expires: future),
      _inv('e@x.fr', 'cancelled', expires: future),
      _inv('f@x.fr', 'sent'),
    ], now);
    expect(result.map((i) => i.email), ['a@x.fr', 'b@x.fr']);
  });

  test('trie par date de création, sans date en dernier', () {
    final result = pendingEmailInvitations([
      _inv('nodate@x.fr', 'sent', expires: future),
      _inv('late@x.fr', 'sent', expires: future, created: now),
      _inv('early@x.fr', 'sent', expires: future, created: past),
    ], now);
    expect(result.map((i) => i.email), [
      'early@x.fr',
      'late@x.fr',
      'nodate@x.fr',
    ]);
  });
}
