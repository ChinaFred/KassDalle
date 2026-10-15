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

/// « Répondre » à la dernière analyse : barre de décision, ticket bloqué,
/// boîte de réponse, réponses intercalées dans la section Analyses. Lisibles
/// à 320 px de large avec un texte à 200 %.
class _FakeTicketRepository extends TicketRepository {
  _FakeTicketRepository(this.onAnswer)
    : super(
        firestore: FakeFirebaseFirestore(),
        errorReportService: ErrorReportService(
          firestore: FakeFirebaseFirestore(),
        ),
      );

  final Future<String> Function(String text) onAnswer;
  final answers = <String>[];

  @override
  Future<String> answer(String ticketId, String answer) {
    answers.add(answer);
    return onAnswer(answer);
  }
}

Ticket _ticket(String status) => Ticket.fromMap('t1', {
  'type': 'bug',
  'title': 'La liste de courses se vide toute seule au retour',
  'description': 'Une description',
  'screen': '/planning',
  'app_version': '0.23.66',
  'platform': 'android',
  'author_uid': 'u1',
  'status': status,
  'github_issue_number': 68,
  'github_url': 'https://github.com/ChinaFred/KassDalle/issues/68',
});

TicketAnalysisDoc _doc({
  bool blocked = false,
  bool withReply = false,
  bool unverified = false,
  bool truncatedReply = false,
}) => TicketAnalysisDoc.fromMap({
  'analyses': [
    {
      'kind': 'analysis',
      'body': '## Analyse\n\nCause probable.',
      'created_at': DateTime(2026, 10, 14, 9, 30),
    },
    if (withReply)
      {
        'kind': 'reply',
        'body': '## Précisions de l\'administrateur\n\nGarder le bouton.',
        'created_at': DateTime(2026, 10, 14, 10, 15),
        'truncated': truncatedReply,
      },
    if (unverified)
      {
        'kind': 'unverified_reply',
        'body': '## Précisions de l\'administrateur\n\nTexte d\'ailleurs.',
        'created_at': DateTime(2026, 10, 14, 10, 30),
      },
  ],
  'validated_at': blocked
      ? DateTime(2026, 10, 14, 8)
      : DateTime(2026, 10, 14, 11),
});

void main() {
  Future<_FakeTicketRepository> pump(
    WidgetTester tester, {
    required String status,
    required TicketAnalysisDoc doc,
    Future<String> Function(String text)? onAnswer,
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repo = _FakeTicketRepository(onAnswer ?? (_) async => 'received');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ticketRepositoryProvider.overrideWithValue(repo),
          adminTicketsProvider.overrideWith(
            (ref) => Stream.value([_ticket(status)]),
          ),
          adminTicketsToProcessIdsProvider.overrideWith(
            (ref) => Stream.value({'t1'}),
          ),
          ticketAnalysisProvider.overrideWith(
            (ref, id) => Stream<TicketAnalysisDoc?>.value(doc),
          ),
          ticketLaunchesProvider.overrideWith(
            (ref, id) => Stream<List<TicketLaunch>?>.value(const []),
          ),
          ticketsStatusProvider.overrideWith(
            (ref) => Stream.value(TicketsStatus.fromMap(const {})),
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

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(OutlinedButton, 'Répondre'));
    await tester.pumpAndSettle();
  }

  testWidgets('Analysé : Refuser, Répondre, Valider, sans débordement', (
    tester,
  ) async {
    await pump(tester, status: 'analyzed', doc: _doc());
    expect(find.widgetWithText(OutlinedButton, 'Refuser'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Répondre'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Valider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Validé bloqué : ligne, Répondre principal, aucun lancement', (
    tester,
  ) async {
    await pump(tester, status: 'validated', doc: _doc(blocked: true));
    expect(
      find.text(
        'La dernière analyse, du 14/10/26 à 09:30, attend votre réponse.',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Répondre'), findsOneWidget);
    expect(find.text('Lancer le développement'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Validé non bloqué : Répondre secondaire, développement offert', (
    tester,
  ) async {
    await pump(tester, status: 'validated', doc: _doc());
    expect(find.widgetWithText(OutlinedButton, 'Répondre'), findsOneWidget);
    expect(find.text('Lancer le développement'), findsOneWidget);
  });

  testWidgets(
    'Reçu après une réponse : ligne des précisions, réponse affichée',
    (tester) async {
      await pump(tester, status: 'received', doc: _doc(withReply: true));
      expect(
        find.text(
          'Vos précisions du 14/10/26 à 10:15 seront lues par la prochaine '
          'analyse.',
        ),
        findsOneWidget,
      );
      // Un ticket Reçu se répond encore : les précisions s'ajoutent.
      expect(find.widgetWithText(OutlinedButton, 'Répondre'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Votre réponse du 14/10/26 à 10:15'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Analyses (1)'), findsOneWidget);
      expect(find.text('Garder le bouton.'), findsOneWidget);
    },
  );

  testWidgets('adresse e-mail : refusée avant l\'appel, texte gardé', (
    tester,
  ) async {
    final repo = await pump(tester, status: 'analyzed', doc: _doc());
    await openDialog(tester);
    expect(find.text('Répondre à l\'analyse'), findsOneWidget);
    // Sous-titre de la boîte ; la carte de la fiche porte le même libellé.
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Analyse du 14/10/26 à 09:30'),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'Écrivez à moi@exemple.fr');
    await tester.tap(find.text('Publier'));
    await tester.pumpAndSettle();
    expect(
      find.text('Retirez l\'adresse e-mail avant de publier.'),
      findsOneWidget,
    );
    expect(repo.answers, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('publication : boîte fermée, message, brouillon vidé', (
    tester,
  ) async {
    final repo = await pump(tester, status: 'validated', doc: _doc());
    await openDialog(tester);
    expect(find.text('La validation sera retirée.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '  Garder le bouton.  ');
    await tester.tap(find.text('Publier'));
    await tester.pumpAndSettle();
    expect(repo.answers, ['Garder le bouton.']);
    expect(find.text('Répondre à l\'analyse'), findsNothing);
    expect(
      find.text(
        'Réponse publiée. Le ticket repasse à Reçu : lancez l\'analyse.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await openDialog(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('« Fermer » pendant l\'envoi, puis échec en message', (
    tester,
  ) async {
    final pending = Completer<String>();
    await pump(
      tester,
      status: 'analyzed',
      doc: _doc(),
      onAnswer: (_) => pending.future,
    );
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), 'Garder le bouton.');
    await tester.tap(find.text('Publier'));
    await tester.pump();
    expect(
      find.text(
        'Publication en cours. Vous pouvez fermer : le résultat s\'affichera '
        'dans un message.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Répondre à l\'analyse'), findsNothing);
    pending.completeError(
      const TicketDecisionError(
        'Réponse publiée, mais le statut n\'a pas changé. Réessayez.',
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Réponse publiée, mais le statut n\'a pas changé. Réessayez.'),
      findsOneWidget,
    );
  });

  testWidgets('grand écran, deux colonnes : barre complète sans débordement', (
    tester,
  ) async {
    await pump(
      tester,
      status: 'validated',
      doc: _doc(),
      size: const Size(1400, 1800),
    );
    expect(find.widgetWithText(OutlinedButton, 'Refuser'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Répondre'), findsOneWidget);
    expect(find.text('Lancer le développement'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Reçu après réponse : « Lancer l\'analyse » en action principale',
    (tester) async {
      await pump(tester, status: 'received', doc: _doc(withReply: true));
      expect(
        find.widgetWithText(FilledButton, 'Lancer l\'analyse'),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Refuser'), findsOneWidget);
    },
  );

  testWidgets('échec partiel : texte verrouillé, aussi à la réouverture', (
    tester,
  ) async {
    await pump(
      tester,
      status: 'analyzed',
      doc: _doc(),
      onAnswer: (_) async => throw const TicketDecisionError(
        'Réponse publiée, mais le statut n\'a pas changé. Réessayez.',
        partial: true,
      ),
    );
    await openDialog(tester);
    await tester.enterText(find.byType(TextField), 'Garder le bouton.');
    await tester.tap(find.text('Publier'));
    await tester.pumpAndSettle();
    expect(
      find.text('Réponse publiée, mais le statut n\'a pas changé. Réessayez.'),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    await openDialog(tester);
    expect(
      find.text(
        'Cette réponse est déjà publiée sur GitHub. Publier remet le ticket à '
        'Reçu.',
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
  });

  testWidgets('précision non publiée depuis l\'application : mention, pas de '
      'carte de réponse', (tester) async {
    await pump(tester, status: 'received', doc: _doc(unverified: true));
    await tester.scrollUntilVisible(
      find.text('Non publiée depuis l\'application.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Précisions du 14/10/26 à 10:30'), findsOneWidget);
    expect(find.textContaining('Votre réponse du'), findsNothing);
  });

  testWidgets('réponse tronquée : « Réponse tronquée, voir GitHub. »', (
    tester,
  ) async {
    await pump(
      tester,
      status: 'received',
      doc: _doc(withReply: true, truncatedReply: true),
    );
    await tester.scrollUntilVisible(
      find.text('Réponse tronquée, voir GitHub.'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Analyse tronquée, voir GitHub.'), findsNothing);
  });
}
