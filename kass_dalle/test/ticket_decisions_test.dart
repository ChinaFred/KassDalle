import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_analysis.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_answer.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_launch.dart';
import 'package:kass_dalle/features/tickets/presentation/tickets_providers.dart';

Ticket _ticket({
  String id = 't1',
  String status = 'analyzed',
  String type = 'bug',
  int? issue = 12,
  DateTime? statusChangedAt,
}) => Ticket.fromMap(id, {
  'status_changed_at': ?statusChangedAt,
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

    test('raison de l\'échec partiel d\'une réponse', () {
      expect(kTicketAnswerPartialReason, fixture['answer_partial_reason']);
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
          {
            'can_validate': d.canValidate,
            'can_refuse': d.canRefuse,
            'can_launch_analysis': d.canLaunchAnalysis,
            'can_launch_development': d.canLaunchDevelopment,
          },
          {
            'can_validate': c['can_validate'],
            'can_refuse': c['can_refuse'],
            'can_launch_analysis': c['can_launch_analysis'],
            'can_launch_development': c['can_launch_development'],
          },
        );
      });
    }

    test('plafond quotidien des lancements par défaut', () {
      expect(kTicketDefaultLaunchesPerDay, fixture['default_launches_per_day']);
      expect(kTicketMaxLaunchesPerDay, fixture['max_launches_per_day']);
    });

    DateTime? iso(Object? v) => v is String ? DateTime.parse(v) : null;

    for (final r
        in (fixture['launch_runs'] as List).cast<Map<String, dynamic>>()) {
      test('lancements : ${r['name']}', () {
        final launches = (r['launches'] as List)
            .cast<Map<String, dynamic>>()
            .map(
              (e) => TicketLaunch.fromMap({
                ...e,
                'launched_at': iso(e['launched_at']),
                'retry_after': iso(e['retry_after']),
              })!,
            )
            .toList();
        final state = ticketLaunchRunState(
          launches: launches,
          action: TicketLaunchAction.fromValue(r['action'])!,
          rawStatus: r['raw_status'] as String,
          now: DateTime.parse(r['now'] as String),
          statusChangedAt: iso(r['status_changed_at']),
        );
        expect(state.running, r['running']);
        expect(state.runningSince, iso(r['running_since']));
        expect(state.relaunchOf, iso(r['relaunch_of']));
      });
    }
  });

  group('fixture ticket_decisions.json : réponse et ticket bloqué', () {
    final fixture =
        jsonDecode(
              File('test-fixtures/ticket_decisions.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    DateTime? iso(Object? v) => v is String ? DateTime.parse(v) : null;

    for (final c
        in (fixture['reply_cases'] as List).cast<Map<String, dynamic>>()) {
      final hasIssue = c['has_issue'] as bool;
      final hasAnalysis = c['has_analysis'] as bool;
      final running = c['development_running'] as bool;
      test('Répondre : ${c['status']} · ${c['type']} · '
          '${hasIssue ? 'avec' : 'sans'} Issue · '
          '${hasAnalysis ? 'avec' : 'sans'} analyse'
          '${running ? ' · développement en cours' : ''}', () {
        expect(
          ticketCanReply(
            rawStatus: c['status'] as String,
            type: TicketType.fromValue(c['type'])!,
            hasIssue: hasIssue,
            hasAnalysis: hasAnalysis,
            developmentRunning: running,
          ),
          c['can_reply'],
        );
      });
    }

    test('Répondre suit la règle partagée dans adminTicketDecisions', () {
      final d = adminTicketDecisions(
        _ticket(status: 'validated'),
        launches: const [],
        now: DateTime.utc(2026, 10, 14, 12),
        analysis: TicketAnalysisDoc.fromMap({
          'analyses': [
            {
              'body': '## Analyse\n\nA',
              'created_at': DateTime.utc(2026, 10, 14, 10),
            },
          ],
        }),
      );
      expect(d.canReply, isTrue);
    });

    for (final c
        in (fixture['awaiting_reply'] as List).cast<Map<String, dynamic>>()) {
      test('bloqué : ${c['name']}', () {
        expect(
          ticketAwaitingReply(
            rawStatus: c['status'] as String,
            type: TicketType.fromValue(c['type'])!,
            lastAnalysisAt: iso(c['last_analysis_at']),
            validatedAtKnown: c['validated_known'] as bool,
            validatedAt: iso(c['validated_at']),
          ),
          c['awaiting_reply'],
        );
      });
    }
  });

  group('fixture ticket_answer_text.json (partagée avec le serveur)', () {
    final fixture =
        jsonDecode(
              File('test-fixtures/ticket_answer_text.json').readAsStringSync(),
            )
            as Map<String, dynamic>;

    test('bornes du texte', () {
      expect(kTicketAnswerMinChars, fixture['min_chars']);
      expect(kTicketAnswerMaxChars, fixture['max_chars']);
    });

    for (final c
        in (fixture['email_cases'] as List).cast<Map<String, dynamic>>()) {
      test('adresse e-mail : "${c['text']}"', () {
        expect(
          ticketTextContainsEmail(c['text'] as String),
          c['contains_email'],
        );
      });
    }

    test('message sous le champ', () {
      expect(ticketAnswerFieldError('  abcd '), kTicketAnswerTooShortMessage);
      expect(
        ticketAnswerFieldError('Écrivez à moi@exemple.fr'),
        kTicketAnswerEmailMessage,
      );
      expect(ticketAnswerFieldError('Oui, garder le bouton.'), isNull);
      expect(ticketAnswerFieldError('Merci @ChinaFred'), isNull);
    });
  });

  group('Répondre et ticket bloqué', () {
    final now = DateTime.utc(2026, 10, 14, 13);
    TicketAnalysisDoc doc({
      required List<Map<String, Object?>> entries,
      Object? validatedAt = const _Absent(),
    }) => TicketAnalysisDoc.fromMap({
      'analyses': entries,
      if (validatedAt is! _Absent) 'validated_at': validatedAt,
    });
    Map<String, Object?> analysis(DateTime at) => {
      'body': '## Analyse\n\nA',
      'created_at': at,
    };
    Map<String, Object?> reply(DateTime at) => {
      'kind': 'reply',
      'body': '## Précisions de l\'administrateur\n\nR',
      'created_at': at,
    };
    TicketLaunch devLaunch(DateTime at) => TicketLaunch.fromMap({
      'id': 'l1',
      'action': 'developpement',
      'outcome': 'launched',
      'from_status': 'validated',
      'launched_at': at,
      'retry_after': at.add(const Duration(hours: 3)),
    })!;

    test('bloqué : Répondre offert, développement, relance et « en cours » '
        'retirés', () {
      final d = adminTicketDecisions(
        _ticket(status: 'validated'),
        launches: [devLaunch(DateTime.utc(2026, 10, 14, 12))],
        now: now,
        analysis: doc(
          entries: [analysis(DateTime.utc(2026, 10, 14, 11))],
          validatedAt: DateTime.utc(2026, 10, 14, 10),
        ),
      );
      expect(d.awaitingReply, isTrue);
      expect(d.canReply, isTrue);
      expect(d.canLaunchDevelopment, isFalse);
      expect(d.runningSince, isNull);
      expect(d.relaunchOf, isNull);
      expect(d.lastAnalysisAt, DateTime.utc(2026, 10, 14, 11));
    });

    test('date de validation inconnue : pas bloqué', () {
      final d = adminTicketDecisions(
        _ticket(status: 'validated'),
        launches: const [],
        now: now,
        analysis: doc(entries: [analysis(DateTime.utc(2026, 10, 14, 11))]),
      );
      expect(d.awaitingReply, isFalse);
      expect(d.canLaunchDevelopment, isTrue);
      expect(d.canReply, isTrue);
    });

    test('lancement en cours : Répondre masqué', () {
      final d = adminTicketDecisions(
        _ticket(status: 'validated'),
        launches: [devLaunch(DateTime.utc(2026, 10, 14, 12))],
        now: now,
        analysis: doc(
          entries: [analysis(DateTime.utc(2026, 10, 14, 9))],
          validatedAt: DateTime.utc(2026, 10, 14, 10),
        ),
      );
      expect(d.runningSince, isNotNull);
      expect(d.canReply, isFalse);
    });

    test('analyses pas encore lues : ni Répondre, ni blocage', () {
      final d = adminTicketDecisions(
        _ticket(status: 'analyzed'),
        launches: const [],
        now: now,
      );
      expect(d.canReply, isFalse);
      expect(d.awaitingReply, isFalse);
    });

    test('Reçu après une réponse : précisions en attente, relance ignorée', () {
      final d = adminTicketDecisions(
        _ticket(
          status: 'received',
          statusChangedAt: DateTime.utc(2026, 10, 14, 12),
        ),
        launches: [
          TicketLaunch.fromMap({
            'id': 'a1',
            'action': 'analyse',
            'outcome': 'launched',
            'from_status': 'received',
            'launched_at': DateTime.utc(2026, 10, 14, 8),
            'retry_after': DateTime.utc(2026, 10, 14, 9),
          })!,
        ],
        now: now,
        analysis: doc(
          entries: [
            analysis(DateTime.utc(2026, 10, 14, 10)),
            reply(DateTime.utc(2026, 10, 14, 12)),
          ],
        ),
      );
      expect(d.pendingAnswerAt, DateTime.utc(2026, 10, 14, 12));
      expect(d.canLaunchAnalysis, isTrue);
      expect(d.relaunchOf, isNull);
      expect(d.canReply, isFalse);
    });

    test('sous-document : nature, compte, dates', () {
      final d = doc(
        entries: [
          analysis(DateTime.utc(2026, 10, 14, 8)),
          reply(DateTime.utc(2026, 10, 14, 9)),
          analysis(DateTime.utc(2026, 10, 14, 10)),
          {'kind': 'inconnu', 'body': 'x'},
        ],
        validatedAt: null,
      );
      expect(d.analyses.map((a) => a.kind), [
        TicketAnalysisKind.analysis,
        TicketAnalysisKind.reply,
        TicketAnalysisKind.analysis,
      ]);
      expect(d.analysisCount, 2);
      expect(d.lastAnalysisAt, DateTime.utc(2026, 10, 14, 10));
      // La réponse précède la dernière analyse : rien en attente.
      expect(d.pendingAnswerAt, isNull);
      expect(d.validatedAtKnown, isTrue);
      expect(d.validatedAt, isNull);
      expect(TicketAnalysisDoc.fromMap({}).validatedAtKnown, isFalse);
    });

    test('texte affiché d\'une réponse sans sa ligne de titre', () {
      expect(
        ticketAnalysisDisplayBody(
          '## Précisions de l\'administrateur\n\nOui, garder.',
        ),
        'Oui, garder.',
      );
    });

    test('précision non publiée depuis l\'application : ni réponse, ni '
        'analyse', () {
      final d = doc(
        entries: [
          analysis(DateTime.utc(2026, 10, 14, 8)),
          {
            'kind': 'unverified_reply',
            'body': '## Précisions de l\'administrateur\n\nX',
            'created_at': DateTime.utc(2026, 10, 14, 9),
          },
        ],
      );
      expect(d.analyses.last.kind, TicketAnalysisKind.unverifiedReply);
      expect(d.analysisCount, 1);
      expect(d.pendingAnswerAt, isNull);
    });

    test('erreur du serveur sous le champ', () {
      final e = ticketDecisionErrorFrom(
        message: 'Retirez l\'adresse e-mail avant de publier.',
        details: {'field': 'answer', 'reason': 'contains_email'},
      );
      expect(e?.field, 'answer');
      expect(e?.partial, isFalse);
      expect(
        ticketDecisionErrorFrom(
          message:
              'Réponse publiée, mais le statut n\'a pas changé. '
              'Réessayez.',
          details: {'reason': 'answer_published_labels_failed'},
        )?.field,
        isNull,
      );
      expect(
        ticketDecisionErrorFrom(
          message:
              'Réponse publiée, mais le statut n\'a pas changé. '
              'Réessayez.',
          details: {'reason': kTicketAnswerPartialReason},
        )?.partial,
        isTrue,
      );
    });
  });

  group('boutons de lancement', () {
    final now = DateTime.utc(2026, 10, 14, 12, 30);
    TicketLaunch entry({
      String action = 'analyse',
      String outcome = 'launched',
      String from = 'received',
      DateTime? at,
      Duration delay = const Duration(hours: 1),
    }) {
      final launched = at ?? DateTime.utc(2026, 10, 14, 12);
      return TicketLaunch.fromMap({
        'id': 'l1',
        'action': action,
        'outcome': outcome,
        'from_status': from,
        'launched_at': launched,
        'retry_after': launched.add(delay),
        'launched_by_name': 'Fred',
      })!;
    }

    test('Reçu : Refuser et Lancer l\'analyse, jamais Valider', () {
      final d = adminTicketDecisions(
        _ticket(status: 'received'),
        launches: const [],
        now: now,
      );
      expect(d.canRefuse, isTrue);
      expect(d.canValidate, isFalse);
      expect(d.canLaunchAnalysis, isTrue);
      expect(d.canLaunchDevelopment, isFalse);
      expect(d.relaunchOf, isNull);
      expect(d.launchAction, TicketLaunchAction.analysis);
    });

    test('Question reçue : Lancer l\'analyse aussi', () {
      final d = adminTicketDecisions(
        _ticket(status: 'received', type: 'question'),
        launches: const [],
        now: now,
      );
      expect(d.canLaunchAnalysis, isTrue);
    });

    test('Validé : Lancer le développement, sauf une Question', () {
      expect(
        adminTicketDecisions(
          _ticket(status: 'validated'),
          launches: const [],
          now: now,
        ).canLaunchDevelopment,
        isTrue,
      );
      final question = adminTicketDecisions(
        _ticket(status: 'validated', type: 'question'),
        launches: const [],
        now: now,
      );
      expect(question.canLaunchDevelopment, isFalse);
      expect(question.launchAction, isNull);
    });

    test('Analysé : Valider, aucun lancement', () {
      final d = adminTicketDecisions(_ticket(), launches: const [], now: now);
      expect(d.canValidate, isTrue);
      expect(d.canLaunchAnalysis || d.canLaunchDevelopment, isFalse);
    });

    test('lancement en cours : bouton masqué, ligne « en cours »', () {
      final d = adminTicketDecisions(
        _ticket(status: 'received'),
        launches: [entry()],
        now: now,
      );
      expect(d.canLaunchAnalysis, isFalse);
      expect(d.runningSince, DateTime.utc(2026, 10, 14, 12));
      expect(d.hasAction, isTrue);
    });

    test('échéance passée : « Relancer »', () {
      final d = adminTicketDecisions(
        _ticket(status: 'received'),
        launches: [entry()],
        now: DateTime.utc(2026, 10, 14, 13, 5),
      );
      expect(d.canLaunchAnalysis, isTrue);
      expect(d.relaunchOf, DateTime.utc(2026, 10, 14, 12));
      expect(d.runningSince, isNull);
    });

    test('historique en chargement : bouton masqué ; en erreur : affiché', () {
      final loading = adminTicketDecisions(
        _ticket(status: 'validated'),
        launchesLoading: true,
        now: now,
      );
      expect(loading.canLaunchDevelopment, isFalse);
      expect(loading.runningSince, isNull);
      final failed = adminTicketDecisions(
        _ticket(status: 'validated'),
        launches: null,
        now: now,
      );
      expect(failed.canLaunchDevelopment, isTrue);
    });

    test('statut inconnu : aucun lancement', () {
      final d = adminTicketDecisions(
        _ticket(status: 'archived'),
        launches: const [],
        now: now,
      );
      expect(d.canLaunchAnalysis || d.canLaunchDevelopment, isFalse);
      expect(d.launchAction, isNull);
    });

    test('ligne « en cours » : heure seule le jour même, date sinon', () {
      final since = DateTime(2026, 10, 14, 14, 5);
      expect(
        ticketLaunchRunningLine(
          TicketLaunchAction.analysis,
          since,
          DateTime(2026, 10, 14, 15),
        ),
        'Analyse en cours depuis 14:05',
      );
      expect(
        ticketLaunchRunningLine(
          TicketLaunchAction.development,
          since,
          DateTime(2026, 10, 15, 9),
        ),
        'Développement en cours depuis le 14/10/26 à 14:05',
      );
    });

    test('historique : plus récent en tête, entrées illisibles écartées', () {
      final list = ticketLaunchesFromDoc({
        'launches': [
          {
            'id': 'a',
            'action': 'analyse',
            'outcome': 'failed',
            'launched_at': Timestamp.fromDate(DateTime.utc(2026, 10, 13)),
          },
          'texte',
          {
            'id': 'b',
            'action': 'developpement',
            'outcome': 'launched',
            'launched_at': Timestamp.fromDate(DateTime.utc(2026, 10, 14)),
            'session_url': 'https://claude.ai/code/s1',
          },
        ],
      });
      expect(list.map((l) => l.id), ['b', 'a']);
      expect(list.first.action, TicketLaunchAction.development);
      expect(list.first.outcome, TicketLaunchOutcome.launched);
      expect(ticketLaunchesFromDoc(null), isEmpty);
    });

    test('lien de session : https et claude.ai seulement', () {
      expect(
        openableSessionLink('https://claude.ai/code/session_1')?.host,
        'claude.ai',
      );
      expect(openableSessionLink('http://claude.ai/code/s'), isNull);
      expect(openableSessionLink('https://evil.example/claude.ai'), isNull);
      expect(openableSessionLink('https://claude.ai.evil.example/x'), isNull);
      expect(openableSessionLink('javascript:alert(1)'), isNull);
      expect(openableSessionLink(null), isNull);
    });

    test('compteurs : jour et mois de Paris, sinon zéro', () {
      final status = TicketsStatus.fromMap({
        'launches_today': {'day': '20261014', 'count': 3},
        'launches_month': {'month': '202610', 'count': 8},
        'routine_invalid_since': {
          'analyse': Timestamp.fromDate(DateTime.utc(2026, 10, 14, 8)),
          'developpement': null,
        },
      });
      final today = DateTime.utc(2026, 10, 14, 10);
      expect(status.launchesTodayAt(today), 3);
      expect(status.launchesMonthAt(today), 8);
      expect(status.launchesTodayAt(DateTime.utc(2026, 10, 15, 10)), 0);
      expect(status.launchesMonthAt(DateTime.utc(2026, 11, 2, 10)), 0);
      expect(status.analysisRoutineInvalidSince, isNotNull);
      expect(status.developmentRoutineInvalidSince, isNull);
      expect(TicketsStatus.fromMap(null).launchesTodayAt(today), 0);
    });

    test('réponse du serveur : résultat illisible lu « inconnu »', () {
      expect(
        TicketLaunchResult.fromMap({
          'outcome': 'launched',
          'session_url': 'https://claude.ai/code/s',
        }).outcome,
        TicketLaunchOutcome.launched,
      );
      expect(
        TicketLaunchResult.fromMap({'outcome': 'bizarre'}).outcome,
        TicketLaunchOutcome.unknown,
      );
      final serverError = TicketLaunchResult.fromMap({
        'outcome': 'unknown',
        'session_url': null,
        'message':
            'Claude ne répond pas. Vérifiez sur claude.ai/code avant de '
            'relancer.',
      });
      expect(serverError.outcome, TicketLaunchOutcome.unknown);
      expect(serverError.message, startsWith('Claude ne répond pas.'));
      expect(
        TicketLaunchResult.fromMap({'outcome': 'unknown'}).message,
        isNull,
      );
    });
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

/// Marque un champ absent du sous-document (distinct de `null`).
class _Absent {
  const _Absent();
}
