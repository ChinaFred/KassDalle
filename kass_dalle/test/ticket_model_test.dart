import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';

Ticket _ticket({
  String id = 't1',
  String status = 'received',
  String type = 'bug',
  Object? seen,
  Object? changed,
  int attempts = 0,
  int? issue,
  Object? created,
}) => Ticket.fromMap(id, {
  'type': type,
  'title': 'Un titre',
  'description': 'Une description',
  'screen': '/recipes/:recipeId',
  'app_version': '0.23.53',
  'platform': 'android',
  'author_uid': 'u1',
  'status': status,
  'created_at': created,
  'status_changed_at': changed,
  'seen_by_author_at': seen,
  'send_attempts': attempts,
  'github_issue_number': issue,
});

Ticket _delivered({String status = 'delivered', Object? number, Object? url}) =>
    Ticket.fromMap('t1', {
      'type': 'evolution',
      'title': 'Un titre',
      'status': status,
      'delivered_pr_number': number,
      'delivered_pr_url': url,
    });

void main() {
  group('PR de livraison', () {
    test('ticket livré avec PR : numéro et lien', () {
      final t = _delivered(
        number: 57,
        url: 'https://github.com/ChinaFred/KassDalle/pull/57',
      );
      expect(t.shownDeliveredPrNumber, 57);
      expect(
        t.deliveredPrLink.toString(),
        'https://github.com/ChinaFred/KassDalle/pull/57',
      );
    });

    test('ticket livré sans PR : rien', () {
      final t = _delivered();
      expect(t.shownDeliveredPrNumber, isNull);
      expect(t.deliveredPrLink, isNull);
    });

    test('adresse hors github.com ou en http : numéro sans lien', () {
      for (final url in [
        'https://evil.example/pull/57',
        'http://github.com/ChinaFred/KassDalle/pull/57',
      ]) {
        final t = _delivered(number: 57, url: url);
        expect(t.shownDeliveredPrNumber, 57);
        expect(t.deliveredPrLink, isNull);
      }
    });

    test('ticket refusé, répondu ou en cours : aucune PR affichée', () {
      for (final status in ['refused', 'answered', 'in_progress']) {
        final t = _delivered(
          status: status,
          number: 57,
          url: 'https://github.com/ChinaFred/KassDalle/pull/57',
        );
        expect(t.shownDeliveredPrNumber, isNull);
        expect(t.deliveredPrLink, isNull);
      }
    });
  });

  group('Ticket.fromMap', () {
    test('lit un document complet', () {
      final t = Ticket.fromMap('abc', {
        'type': 'question',
        'title': 'Comment planifier ?',
        'description': 'Détail',
        'screen': '/planning',
        'app_version': '0.23.53',
        'platform': 'web',
        'screenshot_path': 'tickets/u1/abc/screenshot.png',
        'author_uid': 'u1',
        'created_at': Timestamp.fromDate(DateTime.utc(2026, 10, 13, 8)),
        'updated_at': Timestamp.fromDate(DateTime.utc(2026, 10, 13, 9)),
        'status': 'answered',
        'github_issue_number': 12,
        'github_url': 'https://github.com/ChinaFred/KassDalle/issues/12',
        'send_attempts': 1,
        'last_send_error': null,
        'reply_text': 'Par le bouton Planning.',
        'status_changed_at': Timestamp.fromDate(DateTime.utc(2026, 10, 13, 9)),
        'seen_by_author_at': null,
      });
      expect(t.id, 'abc');
      expect(t.type, TicketType.question);
      expect(t.status, TicketStatus.answered);
      expect(t.githubIssueNumber, 12);
      expect(t.screenshotPath, 'tickets/u1/abc/screenshot.png');
      expect(t.replyText, 'Par le bouton Planning.');
      expect(t.createdAt!.toUtc(), DateTime.utc(2026, 10, 13, 8));
      expect(t.seenByAuthorAt, isNull);
    });

    test('un document mal formé ne lève pas', () {
      final t = Ticket.fromMap('x', {
        'type': 42,
        'title': null,
        'status': 'inconnu_du_client',
        'send_attempts': 'trois',
        'created_at': 'hier',
        'github_issue_number': '12',
      });
      expect(t.type, TicketType.bug);
      expect(t.title, '');
      expect(t.status, TicketStatus.received);
      expect(t.rawStatus, 'inconnu_du_client');
      expect(t.sendAttempts, 0);
      expect(t.createdAt, isNull);
      expect(t.githubIssueNumber, isNull);
    });

    test('statut `in_progress`', () {
      expect(_ticket(status: 'in_progress').status, TicketStatus.inProgress);
    });
  });

  test('statuts finaux : Livré, Refusé, Répondu', () {
    final finals = TicketStatus.values.where((s) => s.isFinal).toSet();
    expect(finals, {
      TicketStatus.delivered,
      TicketStatus.refused,
      TicketStatus.answered,
    });
  });

  group('point non vu', () {
    final changed = Timestamp.fromDate(DateTime.utc(2026, 10, 13, 10));

    test('statut final jamais ouvert', () {
      expect(
        _ticket(status: 'delivered', changed: changed).hasUnseenUpdate,
        isTrue,
      );
    });

    test('statut final ouvert avant le changement', () {
      final seen = Timestamp.fromDate(DateTime.utc(2026, 10, 13, 9));
      expect(
        _ticket(
          status: 'refused',
          changed: changed,
          seen: seen,
        ).hasUnseenUpdate,
        isTrue,
      );
    });

    test('statut final ouvert après le changement', () {
      final seen = Timestamp.fromDate(DateTime.utc(2026, 10, 13, 11));
      expect(
        _ticket(
          status: 'answered',
          changed: changed,
          seen: seen,
        ).hasUnseenUpdate,
        isFalse,
      );
    });

    test('statut non final : pas de point', () {
      for (final s in [
        'sending',
        'received',
        'analyzed',
        'validated',
        'in_progress',
      ]) {
        expect(
          _ticket(status: s, changed: changed).hasUnseenUpdate,
          isFalse,
          reason: s,
        );
      }
    });

    test('déjà lu, sans date de changement : pas de point', () {
      final seen = Timestamp.fromDate(DateTime.utc(2026, 10, 13, 11));
      expect(_ticket(status: 'delivered', seen: seen).hasUnseenUpdate, isFalse);
    });
  });

  group('anomalie', () {
    test('dix essais sans Issue', () {
      expect(_ticket(status: 'sending', attempts: 10).isInAnomaly, isTrue);
    });

    test('neuf essais : pas encore', () {
      expect(_ticket(status: 'sending', attempts: 9).isInAnomaly, isFalse);
    });

    test('Issue créée : jamais en anomalie', () {
      expect(_ticket(attempts: 12, issue: 3).isInAnomaly, isFalse);
    });
  });

  test('retard d\'envoi au-delà d\'une heure', () {
    final created = DateTime.utc(2026, 10, 13, 8);
    final t = _ticket(status: 'sending', created: Timestamp.fromDate(created));
    expect(t.isLate(created.add(const Duration(minutes: 59))), isFalse);
    expect(t.isLate(created.add(const Duration(minutes: 61))), isTrue);
    final received = _ticket(created: Timestamp.fromDate(created));
    expect(received.isLate(created.add(const Duration(hours: 5))), isFalse);
  });

  group('frise', () {
    test('parcours principal', () {
      expect(
        ticketTimeline(TicketStatus.analyzed).last,
        TicketStatus.delivered,
      );
      expect(ticketTimeline(TicketStatus.analyzed).length, 6);
    });

    test('un refus quitte le parcours après la réception', () {
      expect(ticketTimeline(TicketStatus.refused), [
        TicketStatus.sending,
        TicketStatus.received,
        TicketStatus.refused,
      ]);
    });
  });

  test('libellés', () {
    expect(TicketType.feature.label, 'Nouvelle fonctionnalité');
    expect(TicketStatus.inProgress.label, 'En cours');
    expect(TicketStatus.answered.memberSentence, isNull);
    expect(ticketPlatformLabel('ios'), 'iOS');
    expect(formatTicketDate(DateTime(2026, 10, 3)), '03/10/26');
    expect(
      formatTicketDateTime(DateTime(2026, 10, 3, 9, 5)),
      '03/10/26 à 09:05',
    );
  });

  group('filtres d\'administration', () {
    final tickets = [
      _ticket(id: 'a', status: 'sending', attempts: 10),
      _ticket(id: 'b', status: 'received', type: 'question'),
      _ticket(id: 'c', status: 'sending', attempts: 1, type: 'question'),
    ];

    List<String> ids(List<Ticket> l) => l.map((t) => t.id).toList();

    test('tous', () {
      expect(ids(filterAdminTickets(tickets, status: null, type: null)), [
        'a',
        'b',
        'c',
      ]);
    });

    test('en anomalie', () {
      expect(
        ids(
          filterAdminTickets(
            tickets,
            status: kAdminTicketAnomalyFilter,
            type: null,
          ),
        ),
        ['a'],
      );
    });

    test('statut et type', () {
      expect(
        ids(
          filterAdminTickets(
            tickets,
            status: 'sending',
            type: TicketType.question,
          ),
        ),
        ['c'],
      );
    });
  });
}
