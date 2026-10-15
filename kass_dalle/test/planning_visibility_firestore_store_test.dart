import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/planning/data/planning_visibility_store.dart';

class _RecordingErrorReportService extends ErrorReportService {
  final List<String> features = [];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'test';
  }
}

/// Un Firestore dont tout accès échoue.
class _BrokenFirestore implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Firestore injoignable');
}

/// Une mémoire locale dont la lecture échoue.
class _FailingLocalStore extends InMemoryPlanningVisibilityStore {
  @override
  Future<Set<String>> load({required String uid, required bool canPlan}) =>
      throw StateError('préférences illisibles');
}

/// Plannings affichés sur le compte (v0.23.70) : la sélection suit le membre
/// d'un appareil à l'autre.
void main() {
  const uid = 'moi';
  late FakeFirebaseFirestore firestore;
  late InMemoryPlanningVisibilityStore local;
  late _RecordingErrorReportService errors;

  FirestorePlanningVisibilityStore store() => FirestorePlanningVisibilityStore(
    firestore: firestore,
    local: local,
    errorReportService: errors,
  );

  Future<Map<String, dynamic>?> remote() async =>
      (await firestore.doc('users/$uid/preferences/planning_visibility').get())
          .data();

  setUp(() {
    firestore = FakeFirebaseFirestore();
    local = InMemoryPlanningVisibilityStore();
    errors = _RecordingErrorReportService();
  });

  test('un autre appareil relit la sélection enregistrée', () async {
    await store().save({'marie', 'paul'}, uid: uid, canPlan: true);
    // Appareil neuf : mémoire locale vide.
    local = InMemoryPlanningVisibilityStore();
    expect(await store().load(uid: uid, canPlan: true), {'marie', 'paul'});
  });

  test('chaque rôle garde sa liste', () async {
    await store().save({'marie'}, uid: uid, canPlan: false);
    await store().save({'paul'}, uid: uid, canPlan: true);
    final data = await remote();
    expect(data?['reader'], ['marie']);
    expect(data?['editor'], ['paul']);
    expect(await store().load(uid: uid, canPlan: false), {'marie'});
  });

  test('sans valeur distante, la sélection de l\'appareil est reprise '
      'et envoyée', () async {
    await local.save({'marie'}, uid: uid, canPlan: true);
    expect(await store().load(uid: uid, canPlan: true), {'marie'});
    expect((await remote())?['editor'], ['marie']);
  });

  test('sans valeur distante ni locale, rien n\'est écrit', () async {
    expect(await store().load(uid: uid, canPlan: true), isEmpty);
    expect(await remote(), isNull);
  });

  test('la valeur distante prime sur celle de l\'appareil', () async {
    await local.save({'ancien'}, uid: uid, canPlan: true);
    await firestore.doc('users/$uid/preferences/planning_visibility').set({
      'editor': ['marie'],
    });
    expect(await store().load(uid: uid, canPlan: true), {'marie'});
    // Et la copie locale suit.
    expect(await local.load(uid: uid, canPlan: true), {'marie'});
  });

  test('la liste distante est plafonnée à 100 entrées', () async {
    final many = {
      for (var i = 0; i < 120; i++) 'u${i.toString().padLeft(3, '0')}',
    };
    await store().save(many, uid: uid, canPlan: true);
    expect(((await remote())?['editor'] as List).length, 100);
  });

  test('une lecture distante en échec est rapportée '
      'et la copie locale sert', () async {
    final broken = FirestorePlanningVisibilityStore(
      firestore: _BrokenFirestore(),
      local: local,
      errorReportService: errors,
    );
    await local.save({'marie'}, uid: uid, canPlan: true);
    expect(await broken.load(uid: uid, canPlan: true), {'marie'});
    expect(errors.features, contains('planning_visibility_remote_load'));
  });

  test('une lecture locale en échec remonte à l\'appelant', () async {
    final s = FirestorePlanningVisibilityStore(
      firestore: firestore,
      local: _FailingLocalStore(),
      errorReportService: errors,
    );
    await expectLater(s.load(uid: uid, canPlan: true), throwsStateError);
  });
}
