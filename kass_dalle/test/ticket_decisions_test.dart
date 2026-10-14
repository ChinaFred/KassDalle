import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_analysis.dart';
import 'package:kass_dalle/features/tickets/presentation/tickets_providers.dart';

Ticket _ticket({
  String id = 't1',
  String status = 'analyzed',
  String type = 'bug',
  int? issue = 12,
}) => Ticket.fromMap(id, {
  'type': type,
  'title': 'Un titre',
  'description': 'Une description',
  'screen': '/planning',
  'app_version': '0.23.62',
  'platform': 'web',
  'author_uid': 'u1',
  'status': status,
  'github_issue_number': issue,
});

void main() {
  group('filtre « À traiter »', () {
    final tickets = [
      _ticket(id: 'recu', status: 'received'),
      _ticket(id: 'analyse', status: 'analyzed', type: 'question'),
      _ticket(id: 'valide', status: 'validated'),
      _ticket(id: 'envoi', status: 'sending', issue: null),
      _ticket(id: 'refuse', status: 'refused'),
      // Statut inconnu de cette version : lu « Reçu », mais pas à traiter.
      _ticket(id: 'inconnu', status: 'archived'),
    ];

    List<String> ids(List<Ticket> l) => l.map((t) => t.id).toList();

    test('Reçus et Analysés seulement', () {
      expect(
        ids(
          filterAdminTickets(
            tickets,
            status: kAdminTicketTodoFilter,
            type: null,
          ),
        ),
        ['recu', 'analyse'],
      );
    });

    test('se combine avec le filtre de type', () {
      expect(
        ids(
          filterAdminTickets(
            tickets,
            status: kAdminTicketTodoFilter,
            type: TicketType.bug,
          ),
        ),
        ['recu'],
      );
    });

    test('même ensemble que la requête du compteur', () {
      expect(kAdminTicketToProcessStatuses.map((s) => s.value), [
        'received',
        'analyzed',
      ]);
    });
  });

  group('filtre posé à l\'entrée', () {
    test('« À traiter » à l\'entrée, gardé s\'il y a des tickets', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(adminTicketStatusFilterProvider.notifier);
      notifier.enterToProcess();
      expect(
        container.read(adminTicketStatusFilterProvider),
        kAdminTicketTodoFilter,
      );
      notifier.settleEntry(3);
      expect(
        container.read(adminTicketStatusFilterProvider),
        kAdminTicketTodoFilter,
      );
    });

    test('rien à traiter : bascule sur « Tous », une seule fois', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(adminTicketStatusFilterProvider.notifier);
      notifier.enterToProcess();
      notifier.settleEntry(0);
      expect(container.read(adminTicketStatusFilterProvider), isNull);
      // L'administrateur choisit « À traiter » ensuite : le compteur suivant
      // ne le remet pas sur « Tous ».
      notifier.set(kAdminTicketTodoFilter);
      notifier.settleEntry(0);
      expect(
        container.read(adminTicketStatusFilterProvider),
        kAdminTicketTodoFilter,
      );
    });

    test('un filtre choisi avant le compteur n\'est pas écrasé', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(adminTicketStatusFilterProvider.notifier);
      notifier.enterToProcess();
      notifier.set('refused');
      notifier.settleEntry(0);
      expect(container.read(adminTicketStatusFilterProvider), 'refused');
    });

    test('sans entrée, le compteur ne change rien', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(adminTicketStatusFilterProvider.notifier);
      notifier.set(kAdminTicketTodoFilter);
      notifier.settleEntry(0);
      expect(
        container.read(adminTicketStatusFilterProvider),
        kAdminTicketTodoFilter,
      );
    });
  });

  group('boutons de décision', () {
    test('statut inconnu avec Issue : aucune action, ligne de mise à jour', () {
      final d = adminTicketDecisions(_ticket(status: 'archived'));
      expect(d.hasAction, isFalse);
      expect(d.validateHint, kTicketUnknownStatusHint);
    });

    test('Analysé, hors Question : Valider et Refuser', () {
      final d = adminTicketDecisions(_ticket());
      expect(d.canValidate, isTrue);
      expect(d.canRefuse, isTrue);
      expect(d.validateHint, isNull);
      expect(d.hasAction, isTrue);
    });

    test('Reçu : Refuser seul, avec la ligne d\'explication', () {
      final d = adminTicketDecisions(_ticket(status: 'received'));
      expect(d.canValidate, isFalse);
      expect(d.canRefuse, isTrue);
      expect(d.validateHint, kTicketValidateAfterAnalysisHint);
    });

    test('Question analysée ou reçue : Refuser seul, ligne Question', () {
      for (final status in ['analyzed', 'received']) {
        final d = adminTicketDecisions(
          _ticket(status: status, type: 'question'),
        );
        expect(d.canValidate, isFalse, reason: status);
        expect(d.canRefuse, isTrue, reason: status);
        expect(d.validateHint, kTicketQuestionNoValidationHint, reason: status);
      }
    });

    test('Validé, En cours : Refuser seul, sans ligne', () {
      for (final status in ['validated', 'in_progress']) {
        final d = adminTicketDecisions(_ticket(status: status));
        expect(d.canValidate, isFalse, reason: status);
        expect(d.canRefuse, isTrue, reason: status);
        expect(d.validateHint, isNull, reason: status);
      }
    });

    test('envoi en cours, fins, sans Issue : aucune action', () {
      for (final t in [
        _ticket(status: 'sending', issue: null),
        _ticket(status: 'delivered'),
        _ticket(status: 'refused'),
        _ticket(status: 'answered'),
        _ticket(status: 'archived', issue: null),
        _ticket(status: 'analyzed', issue: null),
      ]) {
        final d = adminTicketDecisions(t);
        expect(d.hasAction, isFalse, reason: t.rawStatus);
        expect(d.validateHint, isNull, reason: t.rawStatus);
      }
    });
  });

  group('fixture ticket_decisions.json (partagée avec le serveur)', () {
    final fixture =
        jsonDecode(
              File('test-fixtures/ticket_decisions.json').readAsStringSync(),
            )
            as Map<String, dynamic>;

    test('raison de l\'échec partiel d\'un refus', () {
      expect(kTicketRefusalPartialReason, fixture['refusal_partial_reason']);
    });

    for (final c in (fixture['cases'] as List).cast<Map<String, dynamic>>()) {
      final hasIssue = c['has_issue'] as bool;
      test('${c['status']} · ${c['type']} · '
          '${hasIssue ? 'avec' : 'sans'} Issue', () {
        final d = adminTicketDecisions(
          _ticket(
            status: c['status'] as String,
            type: c['type'] as String,
            issue: hasIssue ? 12 : null,
          ),
        );
        expect(
          {'can_validate': d.canValidate, 'can_refuse': d.canRefuse},
          {'can_validate': c['can_validate'], 'can_refuse': c['can_refuse']},
        );
      });
    }
  });

  group('erreurs de décision', () {
    test('message du serveur quand il vient de ses contrôles', () {
      final e = ticketDecisionErrorFrom(
        message: 'Une décision est déjà en cours sur ce ticket.',
        details: {'reason': 'decision_in_progress'},
      );
      expect(e?.message, 'Une décision est déjà en cours sur ce ticket.');
      expect(e?.partial, isFalse);
      expect(
        ticketDecisionErrorFrom(
          message: 'Le motif doit faire au moins 5 caractères.',
          details: {'field': 'reason'},
        )?.message,
        'Le motif doit faire au moins 5 caractères.',
      );
    });

    test('échec partiel reconnu', () {
      final e = ticketDecisionErrorFrom(
        message: 'Motif publié, mais l\'Issue n\'a pas été fermée. Réessayez.',
        details: {'reason': kTicketRefusalPartialReason},
      );
      expect(e?.partial, isTrue);
    });

    test('réponse hors contrôles : message générique de l\'écran', () {
      expect(
        ticketDecisionErrorFrom(message: 'INTERNAL', details: null),
        isNull,
      );
      expect(
        ticketDecisionErrorFrom(message: 'x', details: {'autre': 1}),
        isNull,
      );
      expect(
        ticketDecisionErrorFrom(message: '  ', details: {'reason': 'r'}),
        isNull,
      );
    });
  });

  group('analyses', () {
    test('lecture du sous-document, entrée illisible ignorée', () {
      final doc = TicketAnalysisDoc.fromMap({
        'analyses': [
          {
            'comment_id': 7,
            'body': '## Analyse\n\nCause.',
            'created_at': Timestamp.fromDate(DateTime.utc(2026, 10, 12, 8)),
            'truncated': true,
          },
          {'body': ''},
          'texte',
        ],
        'checked_at': Timestamp.fromDate(DateTime.utc(2026, 10, 14)),
      });
      expect(doc.analyses, hasLength(1));
      expect(doc.analyses.single.commentId, 7);
      expect(doc.analyses.single.truncated, isTrue);
      expect(
        doc.analyses.single.createdAt!.isAtSameMomentAs(
          DateTime.utc(2026, 10, 12, 8),
        ),
        isTrue,
      );
      expect(
        doc.checkedAt!.isAtSameMomentAs(DateTime.utc(2026, 10, 14)),
        isTrue,
      );
      expect(TicketAnalysisDoc.fromMap({}).analyses, isEmpty);
    });

    test('état de la section', () {
      final empty = TicketAnalysisDoc.fromMap({'analyses': []});
      final full = TicketAnalysisDoc.fromMap({
        'analyses': [
          {'body': '## Analyse\n\nA'},
        ],
      });
      expect(
        ticketAnalysisView(status: TicketStatus.received, doc: null),
        TicketAnalysisView.notAnalyzed,
      );
      expect(
        ticketAnalysisView(status: TicketStatus.received, doc: empty),
        TicketAnalysisView.notAnalyzed,
      );
      expect(
        ticketAnalysisView(status: TicketStatus.analyzed, doc: null),
        TicketAnalysisView.notYetCollected,
      );
      expect(
        ticketAnalysisView(status: TicketStatus.delivered, doc: null),
        TicketAnalysisView.notYetCollected,
      );
      expect(
        ticketAnalysisView(status: TicketStatus.analyzed, doc: empty),
        TicketAnalysisView.notAnalyzed,
      );
      expect(
        ticketAnalysisView(status: TicketStatus.received, doc: full),
        TicketAnalysisView.list,
      );
    });

    test('texte affiché sans la ligne de titre', () {
      expect(
        ticketAnalysisDisplayBody('## Analyse\n\nCause probable.'),
        'Cause probable.',
      );
      expect(
        ticketAnalysisDisplayBody('\r\n## Analyse — compléments\r\nSuite.'),
        'Suite.',
      );
      expect(ticketAnalysisDisplayBody('## Analyse'), '');
      expect(ticketAnalysisDisplayBody('Autre texte'), 'Autre texte');
    });

    test('liens : http et https seulement', () {
      expect(openableAnalysisLink('https://github.com/x')?.host, 'github.com');
      expect(openableAnalysisLink('http://exemple.fr/a'), isNotNull);
      expect(openableAnalysisLink('javascript:alert(1)'), isNull);
      expect(openableAnalysisLink('file:///etc/passwd'), isNull);
      expect(openableAnalysisLink('mailto:a@b.fr'), isNull);
      expect(openableAnalysisLink('/relatif'), isNull);
      expect(openableAnalysisLink(null), isNull);
    });

    test('image remplacée par un texte', () {
      expect(
        ticketAnalysisImagePlaceholder('capture'),
        '[Image non affichée : capture]',
      );
      expect(ticketAnalysisImagePlaceholder(''), '[Image non affichée]');
      expect(ticketAnalysisImagePlaceholder(null), '[Image non affichée]');
    });
  });
}
