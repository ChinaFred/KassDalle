import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_delivery.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_launch.dart';

/// « Livrer » côté client : lecture de `admin/delivery`, ligne de la barre
/// d'un ticket En cours. Les règles partagées avec le serveur (décision,
/// règle « en cours » avec blocage, verrou) sont dans
/// `test-fixtures/ticket_decisions.json`.
void main() {
  final now = DateTime(2026, 10, 15, 15, 0);
  final ci = DateTime(2026, 10, 15, 14, 5);

  TicketDelivery ready({
    int count = 1,
    bool? mergeable = true,
    String? ciStatus = 'completed',
    String? ciConclusion = 'success',
    bool isReady = true,
  }) => TicketDelivery(
    eligiblePrCount: count,
    prNumber: count == 1 ? 57 : null,
    prUrl: 'https://github.com/ChinaFred/KassDalle/pull/57',
    mergeable: mergeable,
    ciStatus: ciStatus,
    ciConclusion: ciConclusion,
    ciCompletedAt: ci,
    ready: isReady,
  );

  TicketDeliveryBar bar({
    TicketLaunchRunState run = TicketLaunchRunState.none,
    bool loading = false,
    bool error = false,
    TicketDelivery? delivery,
    TicketDeliveryLock? lock,
  }) => ticketDeliveryBar(
    run: run,
    deliveryLoading: loading,
    deliveryError: error,
    delivery: delivery,
    issueNumber: 42,
    lockElsewhere: lock,
    now: now,
  );

  group('ligne de la barre, par priorité', () {
    test('livraison en cours ici : aucune action', () {
      final b = bar(
        run: TicketLaunchRunState(runningSince: DateTime(2026, 10, 15, 14, 5)),
        delivery: ready(),
      );
      expect(b.kind, TicketDeliveryLineKind.running);
      expect(b.text, 'Livraison en cours depuis 14:05');
      expect(b.action, isNull);
    });

    test('livraison en cours depuis un autre jour', () {
      final b = bar(
        run: TicketLaunchRunState(runningSince: DateTime(2026, 10, 14, 14, 5)),
      );
      expect(b.text, 'Livraison en cours depuis le 14/10/26 à 14:05');
    });

    test('chargement, puis illisible', () {
      expect(bar(loading: true).text, 'Vérification de la pull request…');
      expect(bar(error: true).text, 'État de la pull request illisible.');
    });

    test('plusieurs PR, conflit, CI en échec, CI en cours, aucune', () {
      expect(
        bar(delivery: ready(count: 3, isReady: false)).text,
        '3 pull requests ferment l\'Issue #42 : fermez celles à abandonner '
        'sur GitHub.',
      );
      expect(
        bar(delivery: ready(mergeable: false, isReady: false)).text,
        'Conflit sur la PR #57',
      );
      expect(
        bar(delivery: ready(ciConclusion: 'failure', isReady: false)).text,
        'CI de la PR #57 en échec',
      );
      expect(
        bar(
          delivery: ready(
            ciStatus: 'in_progress',
            ciConclusion: null,
            isReady: false,
          ),
        ).text,
        'CI de la PR #57 en cours',
      );
      expect(
        bar(
          delivery: ready(ciStatus: null, ciConclusion: null, isReady: false),
        ).kind,
        TicketDeliveryLineKind.ciRunning,
      );
      expect(
        bar(delivery: ready(count: 0, isReady: false)).text,
        'Aucune PR prête',
      );
      expect(bar().text, 'Aucune PR prête');
      expect(bar().action, isNull);
    });

    test('livraison ailleurs, seulement si la PR est prête ici', () {
      final lock = TicketDeliveryLock(
        ticketId: 't31',
        issueNumber: 31,
        launchedAt: DateTime(2026, 10, 15, 14, 5),
        retryAfter: DateTime(2026, 10, 15, 17, 5),
      );
      final b = bar(delivery: ready(), lock: lock);
      expect(b.kind, TicketDeliveryLineKind.elsewhere);
      expect(b.text, 'Livraison du ticket #31 en cours depuis 14:05');
      expect(b.elsewhereTicketId, 't31');
      expect(b.action, isNull);
      expect(
        bar(delivery: ready(mergeable: false, isReady: false), lock: lock).kind,
        TicketDeliveryLineKind.conflict,
      );
    });

    test('blocage relevé : relance', () {
      final b = bar(
        run: TicketLaunchRunState(
          relaunchOf: DateTime(2026, 10, 15, 14, 5),
          blocked: true,
        ),
        delivery: ready(),
      );
      expect(b.kind, TicketDeliveryLineKind.blocked);
      expect(
        b.text,
        'La livraison du 15/10/26 à 14:05 s\'est arrêtée : lisez '
        '« Livraison — blocage » ci-dessous.',
      );
      expect(b.action, TicketDeliveryAction.relaunch);
    });

    test('échéance passée : ligne prête et relance', () {
      final b = bar(
        run: TicketLaunchRunState(relaunchOf: DateTime(2026, 10, 15, 10)),
        delivery: ready(),
      );
      expect(b.kind, TicketDeliveryLineKind.expired);
      expect(b.text, 'PR #57 prête — CI verte le 15/10/26 à 14:05');
      expect(b.action, TicketDeliveryAction.relaunch);
    });

    test('prête : « Livrer »', () {
      final b = bar(delivery: ready());
      expect(b.kind, TicketDeliveryLineKind.ready);
      expect(b.text, 'PR #57 prête — CI verte le 15/10/26 à 14:05');
      expect(b.action, TicketDeliveryAction.deliver);
    });
  });

  group('lecture de admin/delivery', () {
    test('champs et comptes rendus', () {
      final d = TicketDelivery.fromMap({
        'eligible_pr_count': 1,
        'pr_number': 57,
        'pr_url': 'https://github.com/ChinaFred/KassDalle/pull/57',
        'mergeable': null,
        'ci_status': 'completed',
        'ci_conclusion': 'success',
        'ci_completed_at': ci,
        'ready': true,
        'reports': [
          {
            'comment_id': 1,
            'kind': 'blocked',
            'body': '## Livraison — blocage\n\nConflit.',
            'created_at': DateTime(2026, 10, 15, 13),
          },
          {
            'kind': 'done',
            'body': '## Livraison — terminée\n\nv0.23.75',
            'created_at': DateTime(2026, 10, 15, 16),
          },
          {'kind': 'autre', 'body': 'x'},
          'illisible',
        ],
      });
      expect(d.ready, isTrue);
      expect(d.mergeable, isNull);
      expect(d.reports.length, 2);
      expect(d.lastBlockedAt, DateTime(2026, 10, 15, 13));
      expect(d.openablePrLink.toString(), d.prUrl);
      expect(ticketDeliveryReportDisplayBody(d.reports.first.body), 'Conflit.');
    });

    test('lien de PR : https sur github.com seulement', () {
      for (final bad in [
        'http://github.com/ChinaFred/KassDalle/pull/57',
        'https://evil.example/pull/57',
        'javascript:alert(1)',
      ]) {
        expect(
          TicketDelivery(
            eligiblePrCount: 1,
            prNumber: 57,
            prUrl: bad,
          ).openablePrLink,
          isNull,
          reason: bad,
        );
      }
    });

    test('ready strict : seul true vaut prête', () {
      expect(TicketDelivery.fromMap({'ready': 'true'}).ready, isFalse);
    });
  });

  group('décision « Livrer » avec blocage', () {
    final ticket = Ticket.fromMap('t1', {
      'type': 'evolution',
      'status': 'in_progress',
      'github_issue_number': 42,
      'author_uid': 'u1',
    });
    final launch = TicketLaunch.fromMap({
      'action': 'livraison',
      'outcome': 'launched',
      'from_status': 'in_progress',
      'launched_at': DateTime.utc(2026, 10, 15, 12),
      'retry_after': DateTime.utc(2026, 10, 15, 15),
    })!;

    test('en cours avant l\'échéance, relance après un blocage', () {
      final running = adminTicketDecisions(
        ticket,
        launches: [launch],
        now: DateTime.utc(2026, 10, 15, 13),
      );
      expect(running.canDeliver, isFalse);
      expect(running.runningSince, DateTime.utc(2026, 10, 15, 12));

      final blocked = adminTicketDecisions(
        ticket,
        launches: [launch],
        now: DateTime.utc(2026, 10, 15, 13),
        delivery: TicketDelivery(
          reports: [
            TicketDeliveryReport(
              commentId: 1,
              kind: TicketDeliveryReportKind.blocked,
              body: '## Livraison — blocage',
              createdAt: DateTime.utc(2026, 10, 15, 12, 30),
              truncated: false,
            ),
          ],
        ),
      );
      expect(blocked.canDeliver, isTrue);
      expect(blocked.relaunchOf, DateTime.utc(2026, 10, 15, 12));
      expect(blocked.relaunchAfterBlock, isTrue);
    });
  });

  test('statut des tickets : verrou des livraisons lu', () {
    final status = TicketsStatus.fromMap({
      'delivery_running': {
        'ticket_id': 't31',
        'issue_number': 31,
        'launched_at': DateTime(2026, 10, 15, 14, 5),
        'retry_after': DateTime(2026, 10, 15, 17, 5),
      },
    });
    expect(status.deliveryRunning?.ticketId, 't31');
    expect(
      TicketsStatus.fromMap({'delivery_running': null}).deliveryRunning,
      isNull,
    );
  });
}
