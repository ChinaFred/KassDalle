import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/tickets/data/ticket_repository.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_analysis.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_launch.dart';
import 'package:kass_dalle/features/tickets/presentation/admin_tickets_screen.dart';
import 'package:kass_dalle/features/tickets/presentation/tickets_providers.dart';

/// Barre de décision et boîte de lancement de la fiche admin d'un ticket :
/// lisibles à 320 px de large avec un texte à 200 %.
class _FakeTicketRepository extends TicketRepository {
  _FakeTicketRepository(this.onLaunch)
    : super(
        firestore: FakeFirebaseFirestore(),
        errorReportService: ErrorReportService(
          firestore: FakeFirebaseFirestore(),
        ),
      );

  final Future<TicketLaunchResult> Function() onLaunch;
  int launches = 0;

  /// Appels de `validate` et de `launch`, dans l'ordre.
  final calls = <String>[];
  Object? validateError;

  @override
  Future<String> validate(String ticketId) async {
    calls.add('validate');
    final error = validateError;
    if (error != null) throw error;
    return 'ok';
  }

  @override
  Future<TicketLaunchResult> launch(
    String ticketId,
    TicketLaunchAction action,
  ) {
    launches += 1;
    calls.add('launch');
    return onLaunch();
  }
}

Ticket _ticket(
  String status, {
  bool withIssue = true,
  String id = 't1',
  int issue = 73,
}) => Ticket.fromMap(id, {
  'type': 'bug',
  'title': 'La liste de courses se vide toute seule au retour',
  'description': 'Une description',
  'screen': '/planning',
  'app_version': '0.23.63',
  'platform': 'android',
  'author_uid': 'u1',
  'status': status,
  if (withIssue) ...{
    'github_issue_number': issue,
    'github_url': 'https://github.com/ChinaFred/KassDalle/issues/$issue',
  },
});

/// La liste seule, au téléphone : sous les bandeaux et les filtres à 200 %,
/// 640 px de haut ne laissent pas de place aux tuiles.
const _listSize = Size(360, 1200);

void main() {
  Future<_FakeTicketRepository> pump(
    WidgetTester tester, {
    required String status,
    bool withIssue = true,
    String? selectedTicketId = 't1',
    Size size = const Size(320, 640),
    List<TicketLaunch> launches = const [],
    Future<TicketLaunchResult> Function()? onLaunch,
    List<Ticket>? tickets,
    ValueNotifier<String?>? selection,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _FakeTicketRepository(
      onLaunch ??
          () async => const TicketLaunchResult(
            outcome: TicketLaunchOutcome.launched,
            sessionUrl: 'https://claude.ai/code/s1',
          ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ticketRepositoryProvider.overrideWithValue(repo),
          adminTicketsProvider.overrideWith(
            (ref) => Stream.value(
              tickets ?? [_ticket(status, withIssue: withIssue)],
            ),
          ),
          adminTicketsToProcessIdsProvider.overrideWith(
            (ref) => Stream.value({'t1'}),
          ),
          ticketAnalysisProvider.overrideWith(
            (ref, id) => Stream<TicketAnalysisDoc?>.value(null),
          ),
          ticketLaunchesProvider.overrideWith(
            (ref, id) => Stream<List<TicketLaunch>?>.value(launches),
          ),
          ticketsStatusProvider.overrideWith(
            (ref) => Stream.value(
              TicketsStatus.fromMap({
                'routine_invalid_since': {
                  'analyse': DateTime.utc(2026, 10, 14, 8),
                },
              }),
            ),
          ),
          ticketLaunchesPerDayProvider.overrideWith((ref) async => 10),
          memberNameProvider.overrideWith((ref, uid) => 'Marie'),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2.0)),
            child: child!,
          ),
          // Une sélection qui change sans routeur : l'écran large garde le
          // même `State` de fiche d'un ticket à l'autre.
          home: selection == null
              ? AdminTicketsScreen(selectedTicketId: selectedTicketId)
              : ValueListenableBuilder<String?>(
                  valueListenable: selection,
                  builder: (_, id, _) =>
                      AdminTicketsScreen(selectedTicketId: id),
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('Reçu : Refuser et Lancer l\'analyse, sans débordement', (
    tester,
  ) async {
    await pump(tester, status: 'received');
    expect(tester.takeException(), isNull);
    expect(find.text('Refuser'), findsOneWidget);
    expect(find.text('Lancer l\'analyse'), findsOneWidget);
    expect(find.text('Valider'), findsNothing);
    // Bandeau de la routine d'analyse, sur la fiche au téléphone.
    expect(
      find.textContaining('Jeton de la routine d\'analyse refusé depuis le'),
      findsOneWidget,
    );
  });

  testWidgets('Validé : Lancer le développement', (tester) async {
    await pump(tester, status: 'validated');
    expect(tester.takeException(), isNull);
    expect(find.text('Lancer le développement'), findsOneWidget);
    expect(find.text('Lancer l\'analyse'), findsNothing);
  });

  testWidgets('lancement en cours : bouton masqué, ligne « en cours »', (
    tester,
  ) async {
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    await pump(
      tester,
      status: 'received',
      launches: [
        TicketLaunch.fromMap({
          'id': 'l1',
          'action': 'analyse',
          'outcome': 'launched',
          'from_status': 'received',
          'launched_at': at,
          'retry_after': at.add(const Duration(hours: 1)),
          'launched_by_name': 'Fred',
          'session_url': 'https://claude.ai/code/s1',
        })!,
      ],
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Lancer l\'analyse'), findsNothing);
    expect(find.textContaining('Analyse en cours depuis'), findsOneWidget);
    expect(find.text('Lancements (1)'), findsOneWidget);
  });

  testWidgets('à l\'échéance, « en cours » laisse place à « Relancer »', (
    tester,
  ) async {
    final at = DateTime.now().subtract(const Duration(hours: 1));
    final until = DateTime.now().add(const Duration(milliseconds: 500));
    await pump(
      tester,
      status: 'received',
      launches: [
        TicketLaunch.fromMap({
          'id': 'l1',
          'action': 'analyse',
          'outcome': 'unknown',
          'from_status': 'received',
          'launched_at': at,
          'retry_after': until,
          'launched_by_name': 'Fred',
        })!,
      ],
    );
    expect(find.textContaining('Analyse en cours depuis'), findsOneWidget);
    expect(find.text('Relancer l\'analyse'), findsNothing);
    // L'heure réelle passe l'échéance, puis le minuteur de la fiche part.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 700)),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('Analyse en cours depuis'), findsNothing);
    expect(find.text('Relancer l\'analyse'), findsOneWidget);
  });

  testWidgets('confirmation, envoi, puis message de réussite', (tester) async {
    final repo = await pump(tester, status: 'received');
    await tester.ensureVisible(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Lancer l\'analyse de ce ticket ?'), findsOneWidget);
    expect(
      find.text('Lancements restants aujourd\'hui : 10 sur 10.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Facturé sur l\'abonnement Claude'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Lancer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer'));
    await tester.pumpAndSettle();
    expect(repo.launches, 1);
    expect(find.text('Lancer l\'analyse de ce ticket ?'), findsNothing);
    expect(
      find.text('Session lancée. Le lien est dans la section Lancements.'),
      findsOneWidget,
    );
  });

  testWidgets('5xx de Claude : boîte fermée, message du serveur', (
    tester,
  ) async {
    await pump(
      tester,
      status: 'received',
      onLaunch: () async => const TicketLaunchResult(
        outcome: TicketLaunchOutcome.unknown,
        sessionUrl: null,
        message:
            'Claude ne répond pas. Vérifiez sur claude.ai/code avant de '
            'relancer.',
      ),
    );
    await tester.ensureVisible(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Lancer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer'));
    await tester.pumpAndSettle();
    expect(find.text('Lancer l\'analyse de ce ticket ?'), findsNothing);
    expect(
      find.text(
        'Claude ne répond pas. Vérifiez sur claude.ai/code avant de relancer.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('refus du serveur : la boîte reste ouverte avec le message', (
    tester,
  ) async {
    await pump(
      tester,
      status: 'received',
      onLaunch: () async => throw const TicketLaunchError(
        'La routine est en pause sur claude.ai. Réactivez-la, puis relancez.',
      ),
    );
    await tester.ensureVisible(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Lancer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer'));
    await tester.pumpAndSettle();
    expect(find.text('Lancer l\'analyse de ce ticket ?'), findsOneWidget);
    expect(
      find.text(
        'La routine est en pause sur claude.ai. Réactivez-la, puis relancez.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('liste : numéro d\'Issue avant l\'auteur', (tester) async {
    await pump(
      tester,
      status: 'received',
      selectedTicketId: null,
      size: _listSize,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('#73 · Marie · …'), findsOneWidget);
  });

  testWidgets('liste et fiche : sans Issue, aucun numéro', (tester) async {
    await pump(
      tester,
      status: 'received',
      withIssue: false,
      selectedTicketId: null,
      size: _listSize,
    );
    expect(find.text('Marie · …'), findsOneWidget);
    expect(find.textContaining('#'), findsNothing);
  });

  testWidgets('fiche : « Issue #73 », absent sans Issue', (tester) async {
    await pump(tester, status: 'received');
    expect(find.text('Issue #73'), findsOneWidget);
  });

  testWidgets('fiche sans Issue : pas de « Issue # »', (tester) async {
    await pump(tester, status: 'received', withIssue: false);
    expect(find.textContaining('Issue #'), findsNothing);
  });

  testWidgets('la boîte du développement cite l\'Issue', (tester) async {
    await pump(tester, status: 'validated');
    await tester.ensureVisible(find.text('Lancer le développement'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer le développement'));
    await tester.pumpAndSettle();
    expect(find.text('Lancer le développement de ce ticket ?'), findsOneWidget);
    expect(
      find.text(
        'Une session Claude Code va écrire le code de l\'Issue #73 et ouvrir '
        'une pull request. Elle ne fusionne rien.',
      ),
      findsOneWidget,
    );
  });

  Future<void> openAndLaunch(WidgetTester tester, String button) async {
    await tester.ensureVisible(find.text(button));
    await tester.pumpAndSettle();
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Lancer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer'));
    // L'indicateur tourne pendant l'envoi : pas de pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('« Annuler » avant l\'envoi : rien n\'est appelé', (
    tester,
  ) async {
    final repo = await pump(tester, status: 'received');
    await tester.ensureVisible(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lancer l\'analyse'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Annuler'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(find.text('Lancer l\'analyse de ce ticket ?'), findsNothing);
    expect(repo.launches, 0);
  });

  testWidgets('« Fermer » pendant l\'envoi, puis message de réussite', (
    tester,
  ) async {
    final reply = Completer<TicketLaunchResult>();
    final repo = await pump(
      tester,
      status: 'received',
      onLaunch: () => reply.future,
    );
    await openAndLaunch(tester, 'Lancer l\'analyse');
    expect(repo.launches, 1);
    expect(find.text('Annuler'), findsNothing);
    expect(
      find.text(
        'Lancement en cours. Vous pouvez fermer : le résultat s\'affichera '
        'dans la section Lancements.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('Fermer'));
    await tester.pump();
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Lancer l\'analyse de ce ticket ?'), findsNothing);
    // La fiche reste ouverte : un seul `pop`.
    expect(find.text('Lancements (0)'), findsOneWidget);
    reply.complete(
      const TicketLaunchResult(
        outcome: TicketLaunchOutcome.launched,
        sessionUrl: 'https://claude.ai/code/s1',
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.text('Session lancée. Le lien est dans la section Lancements.'),
      findsOneWidget,
    );
    expect(repo.launches, 1);
  });

  testWidgets('« Fermer » pendant l\'envoi, puis refus en message', (
    tester,
  ) async {
    final reply = Completer<TicketLaunchResult>();
    await pump(tester, status: 'validated', onLaunch: () => reply.future);
    await openAndLaunch(tester, 'Lancer le développement');
    await tester.ensureVisible(find.text('Fermer'));
    await tester.pump();
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    reply.completeError(
      const TicketLaunchError('Un développement a été lancé.'),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Un développement a été lancé.'), findsOneWidget);
  });

  testWidgets('session lancée : comment l\'arrêter', (tester) async {
    final at = DateTime.now().subtract(const Duration(hours: 2));
    await pump(
      tester,
      status: 'received',
      launches: [
        TicketLaunch.fromMap({
          'id': 'l1',
          'action': 'analyse',
          'outcome': 'launched',
          'from_status': 'received',
          'launched_at': at,
          'retry_after': at.add(const Duration(hours: 1)),
          'launched_by_name': 'Fred',
          'session_url': 'https://claude.ai/code/s1',
        })!,
      ],
    );
    expect(
      find.text('Pour l\'arrêter, ouvrez-la sur claude.ai/code.'),
      findsOneWidget,
    );
  });

  testWidgets('écran large : « Fermer » sur A ne bloque pas le ticket B', (
    tester,
  ) async {
    final reply = Completer<TicketLaunchResult>();
    final selection = ValueNotifier<String?>('t1');
    addTearDown(selection.dispose);
    await pump(
      tester,
      status: 'received',
      // À 200 %, les filtres sur 460 px de large prennent la hauteur de la
      // liste : 1000 px de haut la font déborder.
      size: const Size(1400, 1800),
      tickets: [
        _ticket('received'),
        _ticket('analyzed', id: 't2', issue: 74),
      ],
      selection: selection,
      onLaunch: () => reply.future,
    );
    ButtonStyleButton button(String label) => tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );

    await openAndLaunch(tester, 'Lancer l\'analyse');
    await tester.ensureVisible(find.text('Fermer'));
    await tester.pump();
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(button('Lancer l\'analyse').enabled, isFalse);

    selection.value = 't2';
    await tester.pumpAndSettle();
    expect(find.text('Issue #74'), findsOneWidget);
    expect(button('Valider').enabled, isTrue);
    expect(button('Refuser').enabled, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // A reste bloqué jusqu'à la réponse, puis se libère.
    selection.value = 't1';
    await tester.pumpAndSettle();
    expect(button('Lancer l\'analyse').enabled, isFalse);
    reply.complete(
      const TicketLaunchResult(
        outcome: TicketLaunchOutcome.launched,
        sessionUrl: 'https://claude.ai/code/s1',
      ),
    );
    await tester.pumpAndSettle();
    expect(button('Lancer l\'analyse').enabled, isTrue);
    expect(tester.takeException(), isNull);
  });

  group('Valider et lancer le développement', () {
    const combined = 'Valider et lancer le développement';

    Future<_FakeTicketRepository> openCombined(
      WidgetTester tester, {
      Object? validateError,
      Future<TicketLaunchResult> Function()? onLaunch,
      String status = 'analyzed',
    }) async {
      final repo = await pump(tester, status: status, onLaunch: onLaunch);
      repo.validateError = validateError;
      await tester.ensureVisible(find.text(combined));
      await tester.pumpAndSettle();
      await tester.tap(find.text(combined));
      await tester.pumpAndSettle();
      return repo;
    }

    Future<void> confirm(WidgetTester tester) async {
      await tester.ensureVisible(find.text('Valider et lancer'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valider et lancer'));
      await tester.pumpAndSettle();
    }

    testWidgets('proposé sur un ticket analysé, pas ailleurs', (tester) async {
      await pump(tester, status: 'analyzed');
      expect(find.text(combined), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Valider'), findsOneWidget);
    });

    testWidgets('absent hors « analysé »', (tester) async {
      await pump(tester, status: 'validated');
      expect(find.text(combined), findsNothing);
    });

    testWidgets('absent sans Issue', (tester) async {
      await pump(tester, status: 'analyzed', withIssue: false);
      expect(find.text(combined), findsNothing);
    });

    testWidgets('une confirmation, puis validation avant lancement', (
      tester,
    ) async {
      final repo = await openCombined(tester);
      expect(
        find.text('Valider ce ticket et lancer le développement ?'),
        findsOneWidget,
      );
      expect(find.textContaining('Issue #73 sera validé'), findsOneWidget);
      expect(repo.calls, isEmpty);
      await confirm(tester);
      expect(repo.calls, ['validate', 'launch']);
      expect(
        find.text(
          'Ticket validé. Session lancée. Le lien est dans la section '
          'Lancements.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('validation refusée : aucun lancement, message du serveur', (
      tester,
    ) async {
      final repo = await openCombined(
        tester,
        validateError: const TicketDecisionError('Ticket déjà refusé.'),
      );
      await confirm(tester);
      expect(repo.calls, ['validate']);
      expect(find.text('Ticket déjà refusé.'), findsOneWidget);
    });

    testWidgets('lancement refusé : le ticket reste validé, message dit', (
      tester,
    ) async {
      final repo = await openCombined(
        tester,
        onLaunch: () async => throw const TicketLaunchError('Plafond atteint.'),
      );
      await confirm(tester);
      expect(repo.calls, ['validate', 'launch']);
      expect(
        find.text('Ticket validé, développement non lancé : Plafond atteint.'),
        findsOneWidget,
      );
    });
  });
}
