import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/presentation/tickets_providers.dart';

Ticket _ticket(String id, String status, {Object? seen}) => Ticket.fromMap(id, {
  'type': 'bug',
  'title': 'Un titre',
  'description': 'Une description',
  'screen': '/planning',
  'app_version': '0.23.78',
  'platform': 'android',
  'author_uid': 'u1',
  'status': status,
  'status_changed_at': Timestamp.fromDate(DateTime.utc(2026, 10, 15, 10)),
  'seen_by_author_at': seen,
});

Future<int> _count(
  List<Ticket> mine,
  Set<String> toProcess, {
  bool admin = true,
}) async {
  final container = ProviderContainer(
    overrides: [
      isAdminProvider.overrideWithValue(admin),
      myTicketsProvider.overrideWith((ref) => Stream.value(mine)),
      adminTicketsToProcessIdsProvider.overrideWith(
        (ref) => Stream.value(toProcess),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.listen(accountTicketsBadgeCountProvider, (_, _) {});
  await pumpEventQueue();
  return container.read(accountTicketsBadgeCountProvider);
}

void main() {
  test('administrateur : seuls les tickets à traiter comptent', () async {
    final n = await _count(
      [_ticket('a', 'received'), _ticket('b', 'delivered')],
      {'a', 'c'},
    );
    expect(n, 2);
  });

  test('administrateur : ses tickets non lus seuls ne donnent rien', () async {
    expect(await _count([_ticket('b', 'delivered')], {}), 0);
  });

  test('membre : les tickets non lus comptent, pas les autres', () async {
    final n = await _count(
      [_ticket('a', 'received'), _ticket('b', 'delivered')],
      {'a', 'c'},
      admin: false,
    );
    expect(n, 2);
  });

  test('membre : un ticket lu ne compte pas', () async {
    final seen = Timestamp.fromDate(DateTime.utc(2026, 10, 15, 11));
    expect(
      await _count([_ticket('a', 'in_progress', seen: seen)], {}, admin: false),
      0,
    );
  });

  test('un envoi en cours ne compte pas', () async {
    expect(await _count([_ticket('a', 'sending')], {}, admin: false), 0);
  });
}
