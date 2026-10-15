import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_analysis.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_delivery.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_launch.dart';
import 'package:kass_dalle/features/tickets/presentation/admin_tickets_screen.dart';
import 'package:kass_dalle/features/tickets/presentation/tickets_providers.dart';

Ticket _ticket({
  TicketStatus status = TicketStatus.received,
  TicketType type = TicketType.evolution,
  int? issue = 7,
  DateTime? statusChangedAt,
}) => Ticket(
  id: 't1',
  type: type,
  title: 'Titre',
  description: '',
  screen: '/',
  appVersion: '1',
  platform: 'web',
  screenshotPath: null,
  authorUid: 'u',
  createdAt: null,
  updatedAt: null,
  status: status,
  rawStatus: status.value,
  githubIssueNumber: issue,
  githubUrl: null,
  sendAttempts: 0,
  lastSendError: null,
  replyText: null,
  statusChangedAt: statusChangedAt,
  seenByAuthorAt: null,
);

TicketLaunch _launch({
  required TicketLaunchAction action,
  required String from,
  required Duration ago,
  required Duration retryIn,
  TicketLaunchOutcome outcome = TicketLaunchOutcome.launched,
}) {
  final now = DateTime.now();
  return TicketLaunch(
    id: 'l',
    rawAction: action.value,
    action: action,
    launchedAt: now.subtract(ago),
    launchedByName: 'Admin',
    rawOutcome: outcome.value,
    outcome: outcome,
    sessionUrl: null,
    errorReason: null,
    fromStatus: from,
    retryAfter: now.add(retryIn),
  );
}

Future<void> _pump(
  WidgetTester tester,
  Ticket ticket,
  List<TicketLaunch> launches,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ticketLaunchesProvider(
          ticket.id,
        ).overrideWith((ref) => Stream.value(launches)),
        ticketAnalysisProvider(ticket.id).overrideWith(
          (ref) => Stream.value(
            const TicketAnalysisDoc(analyses: [], checkedAt: null),
          ),
        ),
        ticketDeliveryProvider(
          ticket.id,
        ).overrideWith((ref) => Stream.value(const TicketDelivery())),
      ],
      child: MaterialApp(
        home: Scaffold(body: AdminTicketLaunchChip(ticket: ticket)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('analyse lancée : « Analyse en cours »', (tester) async {
    await _pump(tester, _ticket(), [
      _launch(
        action: TicketLaunchAction.analysis,
        from: 'received',
        ago: const Duration(minutes: 5),
        retryIn: const Duration(minutes: 55),
      ),
    ]);
    expect(find.text('Analyse en cours'), findsOneWidget);
  });

  testWidgets('développement lancé : « Développement en cours »', (
    tester,
  ) async {
    await _pump(tester, _ticket(status: TicketStatus.validated), [
      _launch(
        action: TicketLaunchAction.development,
        from: 'validated',
        ago: const Duration(minutes: 5),
        retryIn: const Duration(hours: 3),
      ),
    ]);
    expect(find.text('Développement en cours'), findsOneWidget);
  });

  testWidgets('échéance passée : « Relance possible »', (tester) async {
    await _pump(tester, _ticket(), [
      _launch(
        action: TicketLaunchAction.analysis,
        from: 'received',
        ago: const Duration(hours: 2),
        retryIn: const Duration(hours: -1),
      ),
    ]);
    expect(find.text('Relance possible'), findsOneWidget);
    expect(find.text('Analyse en cours'), findsNothing);
  });

  testWidgets('aucun lancement : aucune puce', (tester) async {
    await _pump(tester, _ticket(), []);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('lancement en échec : aucune puce', (tester) async {
    await _pump(tester, _ticket(), [
      _launch(
        action: TicketLaunchAction.analysis,
        from: 'received',
        ago: const Duration(minutes: 5),
        retryIn: const Duration(minutes: 55),
        outcome: TicketLaunchOutcome.failed,
      ),
    ]);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('lancement antérieur au changement de statut : aucune puce', (
    tester,
  ) async {
    await _pump(
      tester,
      _ticket(
        statusChangedAt: DateTime.now().subtract(const Duration(minutes: 1)),
      ),
      [
        _launch(
          action: TicketLaunchAction.analysis,
          from: 'received',
          ago: const Duration(minutes: 5),
          retryIn: const Duration(minutes: 55),
        ),
      ],
    );
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('ticket de type question ou sans Issue : aucune puce', (
    tester,
  ) async {
    final run = [
      _launch(
        action: TicketLaunchAction.analysis,
        from: 'received',
        ago: const Duration(minutes: 5),
        retryIn: const Duration(minutes: 55),
      ),
    ];
    await _pump(tester, _ticket(type: TicketType.question), run);
    expect(find.byType(Text), findsNothing);
    await _pump(tester, _ticket(issue: null), run);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('ticket final : aucune puce', (tester) async {
    await _pump(tester, _ticket(status: TicketStatus.delivered), [
      _launch(
        action: TicketLaunchAction.delivery,
        from: 'in_progress',
        ago: const Duration(minutes: 5),
        retryIn: const Duration(hours: 3),
      ),
    ]);
    expect(find.byType(Text), findsNothing);
  });
}
