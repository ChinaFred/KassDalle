import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/planning/data/meal_suggestion_repository.dart';
import 'package:kass_dalle/features/planning/domain/meal_suggestion.dart';

class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

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
    return 'report';
  }
}

/// Suggestions de repas sur un Firestore en mémoire : la forme écrite est
/// celle qu'admettent les règles (voir `rules-tests`), les lectures sont
/// celles qu'elles prouvent.
void main() {
  late FakeFirebaseFirestore firestore;
  late _RecordingErrorReportService reports;
  late MealSuggestionRepository repo;
  final now = DateTime(2026, 10, 13, 18);

  setUp(() {
    firestore = FakeFirebaseFirestore();
    reports = _RecordingErrorReportService();
    repo = MealSuggestionRepository(
      firestore: firestore,
      errorReportService: reports,
      now: () => now,
    );
  });

  MealSuggestionDraft draft({
    String? recipeId,
    String title = 'Lasagnes',
    DateTime? day,
    String groupId = 'gd',
  }) => MealSuggestionDraft(
    groupId: groupId,
    groupOwnerId: 'marie',
    day: day ?? DateTime(2026, 10, 17),
    recipeId: recipeId,
    title: title,
    note: 'Pour l\'anniversaire de Léo',
  );

  test('suggérer écrit la forme des règles', () async {
    final id = await repo.suggest(draft(recipeId: 'r1'), 'leo');
    final data = (await firestore.collection('meal_suggestions').doc(id).get())
        .data()!;
    expect(data.keys.toSet(), {
      'group_id',
      'group_owner_id',
      'author_uid',
      'day',
      'recipe_id',
      'recipe_titre',
      'note',
      'created_at',
    });
    expect(data['day'], '2026-10-17');
    expect(data['created_at'], isA<Timestamp>());
    // L'identifiant imposé par les règles.
    expect(id, 'gd_leo_2026-10-17_0');
  });

  test('un brouillon invalide est signalé au rapport, puis relancé', () async {
    await expectLater(
      repo.suggest(draft(title: 'a' * 61), 'leo'),
      throwsArgumentError,
    );
    await pumpEventQueue();
    expect(reports.features, ['meal_suggestions.suggest']);
  });

  test('cinq suggestions par auteur, groupe et jour au plus', () async {
    final ids = [
      for (var i = 0; i < kSuggestionsPerAuthorPerDay; i++)
        await repo.suggest(draft(title: 'Plat $i'), 'leo'),
    ];
    expect(ids, [for (var n = 0; n < 5; n++) 'gd_leo_2026-10-17_$n']);
    await expectLater(
      repo.suggest(draft(title: 'Un de trop'), 'leo'),
      throwsA(isA<SuggestionLimitReached>()),
    );
    // Un autre jour, un autre groupe : libres.
    await repo.suggest(draft(day: DateTime(2026, 10, 18)), 'leo');
    await repo.suggest(draft(groupId: 'cousins'), 'leo');
    // Le plafond n'est pas une panne : rien au rapport.
    expect(reports.features, isEmpty);
  });

  test('le propriétaire lit les siennes, depuis 90 jours', () async {
    await repo.suggest(draft(), 'leo');
    await firestore.collection('meal_suggestions').add({
      'group_id': 'gd',
      'group_owner_id': 'marie',
      'author_uid': 'leo',
      'day': '2026-01-02',
      'free_title': 'Ancienne',
    });
    await firestore.collection('meal_suggestions').add({
      'group_id': 'autre',
      'group_owner_id': 'jean',
      'author_uid': 'leo',
      'day': '2026-10-17',
      'free_title': 'Chez Jean',
    });
    // Au-delà de la borne haute (aujourd'hui + 60 jours) : pas lue.
    await firestore.collection('meal_suggestions').add({
      'group_id': 'gd',
      'group_owner_id': 'marie',
      'author_uid': 'leo',
      'day': '2027-06-01',
      'free_title': 'Lointaine',
    });
    final received = await repo.watchReceived('marie').first;
    expect(received.map((s) => s.title), ['Lasagnes']);
    final sent = await repo.watchSent('leo').first;
    expect(sent.map((s) => s.title).toSet(), {'Lasagnes', 'Chez Jean'});
    final older = await repo.loadOlder('marie', received: true);
    expect(older.map((s) => s.title), ['Ancienne']);
  });

  test('un document mal formé est écarté et signalé', () async {
    await repo.suggest(draft(), 'leo');
    await firestore.collection('meal_suggestions').add({
      'group_id': 'gd',
      'group_owner_id': 'marie',
      'author_uid': 'leo',
      'day': '2026-10-20',
    });
    final received = await repo.watchReceived('marie').first;
    expect(received.map((s) => s.title), ['Lasagnes']);
    await pumpEventQueue();
    expect(reports.features, ['meal_suggestions.malformed']);
  });

  test('un identifiant retiré se réutilise', () async {
    final first = await repo.suggest(draft(), 'leo');
    await repo.suggest(draft(title: 'Autre'), 'leo');
    final mine = await repo.watchSent('leo').first;
    await repo.remove(mine.firstWhere((s) => s.id == first));
    expect(await repo.suggest(draft(title: 'Encore'), 'leo'), first);
  });

  test(
    'retirer puis annuler remet la suggestion sous le même identifiant',
    () async {
      final id = await repo.suggest(draft(recipeId: 'r1'), 'leo');
      final s = (await repo.watchSent('leo').first).single;
      expect(s.id, id);
      await repo.remove(s);
      expect(
        (await firestore.collection('meal_suggestions').doc(id).get()).exists,
        isFalse,
      );
      await repo.restore(s);
      final back =
          (await firestore.collection('meal_suggestions').doc(id).get())
              .data()!;
      expect(back['recipe_titre'], 'Lasagnes');
      expect(back['author_uid'], 'leo');
    },
  );
}
