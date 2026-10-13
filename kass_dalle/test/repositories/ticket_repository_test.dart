import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/tickets/data/ticket_repository.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_form.dart';

/// Faux service des callables : rend la réponse ou lève l'erreur prévue, et
/// garde la dernière entrée de `submitTicket`.
class _FakeCallables extends GeminiService {
  Map<String, dynamic>? lastPayload;
  Map<String, dynamic> response = const {
    'ticketId': 'nouveau',
    'status': 'received',
    'remaining_today': 4,
  };
  Object? error;

  @override
  Future<Map<String, dynamic>> submitTicket(
    Map<String, dynamic> payload,
  ) async {
    lastPayload = payload;
    if (error != null) throw error!;
    return response;
  }
}

/// Garde les rapports d'erreur sans passer par Firebase Auth.
class _RecordingErrorReportService extends ErrorReportService {
  final reports = <Map<String, Object?>>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    reports.add({'feature': feature, 'error': error, ...context});
    return 'rapport';
  }
}

void main() {
  late FakeFirebaseFirestore firestore;
  late _FakeCallables callables;
  late TicketRepository repo;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    callables = _FakeCallables();
    repo = TicketRepository(
      firestore: firestore,
      callables: callables,
      errorReportService: ErrorReportService(firestore: firestore),
    );
  });

  Future<void> addTicket(String id, String author, DateTime created) =>
      firestore.collection('tickets').doc(id).set({
        'type': 'bug',
        'title': 'Titre $id',
        'description': 'd',
        'author_uid': author,
        'status': 'received',
        'created_at': Timestamp.fromDate(created),
      });

  Future<TicketSubmitResult> submit() => repo.submit(
    uid: 'u1',
    type: TicketType.bug,
    title: '  Un bug visible  ',
    description: ' Ce qui se passe ',
    screen: '/recipes/:recipeId',
    appVersion: '0.23.53',
    platform: 'web',
  );

  test(
    'mes tickets : les miens seuls, du plus récent au plus ancien',
    () async {
      await addTicket('a', 'u1', DateTime.utc(2026, 10, 1));
      await addTicket('b', 'u2', DateTime.utc(2026, 10, 2));
      await addTicket('c', 'u1', DateTime.utc(2026, 10, 3));

      final mine = await repo.watchMyTickets('u1').first;

      expect(mine.map((t) => t.id), ['c', 'a']);
    },
  );

  test('ouvrir le détail ne touche que seen_by_author_at', () async {
    await addTicket('a', 'u1', DateTime.utc(2026, 10, 1));
    final before = (await firestore.collection('tickets').doc('a').get())
        .data()!;

    await repo.markSeen('a');

    final after = (await firestore.collection('tickets').doc('a').get())
        .data()!;
    expect(after['seen_by_author_at'], isNotNull);
    expect({...after}..remove('seen_by_author_at'), before);
  });

  test('envoi : entrée du contrat, textes rognés', () async {
    final result = await submit();

    expect(callables.lastPayload, {
      'type': 'bug',
      'title': 'Un bug visible',
      'description': 'Ce qui se passe',
      'screen': '/recipes/:recipeId',
      'app_version': '0.23.53',
      'platform': 'web',
    });
    expect(result.ticketId, 'nouveau');
    expect(result.remainingToday, 4);
    expect(result.screenshotFailed, isFalse);
  });

  test('plafond du membre : refus attendu, pas de rapport d\'erreur', () async {
    callables.error = GeminiCallableException('resource_exhausted', 'Plafond', {
      'reason': 'member_daily_limit',
      'limit': 5,
    });

    await expectLater(
      submit(),
      throwsA(
        isA<TicketMemberLimitReached>().having((e) => e.limit, 'limit', 5),
      ),
    );
    final reports = await firestore.collection('error_reports').get();
    expect(reports.docs, isEmpty);
  });

  test(
    'coupure réseau : TicketNetworkError, et l\'erreur est remontée',
    () async {
      callables.error = Exception('Failed host lookup');

      await expectLater(submit(), throwsA(isA<TicketNetworkError>()));
      final reports = await firestore.collection('error_reports').get();
      expect(reports.docs.single.data()['feature'], 'tickets');
    },
  );

  group('plafond lu dans app_config/tickets', () {
    test('valeur lue', () async {
      await firestore.collection('app_config').doc('tickets').set({
        'per_member_per_day': 5,
        'global_per_day': 30,
      });
      expect(await repo.fetchPerMemberDailyLimit(), 5);
    });

    late _RecordingErrorReportService errors;
    late TicketRepository limitRepo;

    setUp(() {
      errors = _RecordingErrorReportService();
      limitRepo = TicketRepository(
        firestore: firestore,
        callables: callables,
        errorReportService: errors,
      );
    });

    test('document absent : null, sans rapport', () async {
      expect(await limitRepo.fetchPerMemberDailyLimit(), isNull);
      expect(errors.reports, isEmpty);
    });

    test('champ absent : null, sans rapport', () async {
      await firestore.collection('app_config').doc('tickets').set({
        'global_per_day': 30,
      });
      expect(await limitRepo.fetchPerMemberDailyLimit(), isNull);
      expect(errors.reports, isEmpty);
    });

    for (final bad in <Object?>[0, -1, 2.5, '5', null]) {
      test('valeur $bad : illisible, null et rapport d\'erreur', () async {
        await firestore.collection('app_config').doc('tickets').set({
          'per_member_per_day': bad,
        });
        expect(await limitRepo.fetchPerMemberDailyLimit(), isNull);
        expect(errors.reports.single['feature'], 'tickets');
        expect(errors.reports.single['step'], 'fetch_limits');
      });
    }

    test('entier écrit en flottant (3.0) : lu comme 3', () async {
      await firestore.collection('app_config').doc('tickets').set({
        'per_member_per_day': 3.0,
      });
      expect(await limitRepo.fetchPerMemberDailyLimit(), 3);
      expect(errors.reports, isEmpty);
    });
  });

  test('anomalies : envois abandonnés seulement', () async {
    final col = firestore.collection('tickets');
    await col.doc('a').set({'status': 'sending', 'send_attempts': 10});
    await col.doc('b').set({'status': 'sending', 'send_attempts': 2});
    await col.doc('c').set({
      'status': 'received',
      'send_attempts': 11,
      'github_issue_number': 4,
    });

    expect(await repo.watchAnomalyCount().first, 1);
  });
}
