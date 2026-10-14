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

  @override
  Future<TicketLaunchResult> launch(
    String ticketId,
    TicketLaunchAction action,
  ) {
    launches += 1;
    return onLaunch();
  }
}

Ticket _ticket(String status) => Ticket.fromMap('t1', {
  'type': 'bug',
  'title': 'La liste de courses se vide toute seule au retour',
  'description': 'Une description',
  'screen': '/planning',
  'app_version': '0.23.63',
  'platform': 'android',
  'author_uid': 'u1',
  'status': status,
  'github_issue_number': 73,
  'github_url': 'https://github.com/ChinaFred/KassDalle/issues/73',
});

void main() {
  Future<_FakeTicketRepository> pump(
    WidgetTester tester, {
    required String status,
    List<TicketLaunch> launches = const [],
    Future<TicketLaunchResult> Function()? onLaunch,
  }) async {
    tester.view.physicalSize = const Size(320, 640);
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
            (ref) => Stream.value([_ticket(status)]),
          ),
          adminTicketsToProcessCountProvider.overrideWith(
            (ref) => Stream.value(1),
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
          home: const AdminTicketsScreen(selectedTicketId: 't1'),
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
}
