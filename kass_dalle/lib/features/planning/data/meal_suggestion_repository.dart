import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/meal_suggestion.dart';

/// Un auteur a déjà fait [kSuggestionsPerAuthorPerDay] suggestions pour ce
/// groupe et ce jour.
class SuggestionLimitReached implements Exception {
  const SuggestionLimitReached();

  @override
  String toString() =>
      'SuggestionLimitReached: $kSuggestionsPerAuthorPerDay suggestions '
      'au plus par jour';
}

/// Accès aux suggestions de repas (`meal_suggestions`).
///
/// Deux lectures, chacune prouvable par les règles Firestore : le
/// propriétaire d'un groupe lit `group_owner_id == moi`, l'auteur lit
/// `author_uid == moi`. Toute erreur est remontée au rapport d'erreurs, puis
/// transmise à l'écran.
class MealSuggestionRepository {
  final FirebaseFirestore? _injectedDb;
  final ErrorReportService _errorReportService;

  /// L'horloge, remplaçable dans les tests.
  final DateTime Function() now;

  MealSuggestionRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
    DateTime Function()? now,
  }) : _injectedDb = firestore,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore),
       now = now ?? DateTime.now;

  /// Résolu à l'usage : construire le repository n'exige pas d'application
  /// Firebase (tests d'écran).
  FirebaseFirestore get _db => _injectedDb ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection('meal_suggestions');

  /// Premier jour lu en continu : aujourd'hui moins [kSuggestionHistoryDays].
  String get _fromKey {
    final t = now();
    return mealSuggestionDayKey(
      DateTime(t.year, t.month, t.day - kSuggestionHistoryDays),
    );
  }

  /// Dernier jour lu : un jour de plus que ce que l'écran laisse viser, pour
  /// un fuseau en avance sur celui de l'auteur.
  String get _toKey {
    final t = now();
    return mealSuggestionDayKey(
      DateTime(t.year, t.month, t.day + kSuggestionDaysAhead + 1),
    );
  }

  /// Suggestions lues au plus par flux. Un groupe de six membres qui en font
  /// cinq par jour sur 150 jours dépasserait ce nombre ; la borne protège
  /// l'écran d'un volume que les règles n'empêchent pas entre plusieurs
  /// groupes.
  static const watchLimit = 500;

  /// Les suggestions reçues par [ownerUid], propriétaire de groupes, depuis
  /// [kSuggestionHistoryDays] jours.
  Stream<List<MealSuggestion>> watchReceived(String ownerUid) => _watch(
    _col.where('group_owner_id', isEqualTo: ownerUid),
    feature: 'meal_suggestions.received',
    uid: ownerUid,
  );

  /// Les suggestions envoyées par [authorUid] depuis
  /// [kSuggestionHistoryDays] jours.
  Stream<List<MealSuggestion>> watchSent(String authorUid) => _watch(
    _col.where('author_uid', isEqualTo: authorUid),
    feature: 'meal_suggestions.sent',
    uid: authorUid,
  );

  Stream<List<MealSuggestion>> _watch(
    Query<Map<String, dynamic>> query, {
    required String feature,
    required String uid,
  }) {
    return query
        .where('day', isGreaterThanOrEqualTo: _fromKey)
        .where('day', isLessThanOrEqualTo: _toKey)
        .orderBy('day')
        .limit(watchLimit)
        .snapshots()
        .map((snap) => _read(snap.docs))
        .handleError((Object e, StackTrace st) {
          unawaited(
            _errorReportService.reportError(
              feature: feature,
              error: e,
              stackTrace: st,
              context: {'uid': uid},
            ),
          );
          Error.throwWithStackTrace(e, st);
        });
  }

  /// Les suggestions plus anciennes que [kSuggestionHistoryDays] jours, les
  /// plus récentes d'abord, [limit] au plus : « Voir les plus anciennes ».
  /// [received] : reçues par [uid] propriétaire, sinon envoyées par [uid].
  Future<List<MealSuggestion>> loadOlder(
    String uid, {
    required bool received,
    int limit = 100,
  }) async {
    try {
      final snap = await _col
          .where(received ? 'group_owner_id' : 'author_uid', isEqualTo: uid)
          .where('day', isLessThan: _fromKey)
          .orderBy('day', descending: true)
          .limit(limit)
          .get();
      return _read(snap.docs);
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'meal_suggestions.load_older',
          error: e,
          stackTrace: st,
          context: {'uid': uid, 'received': received},
        ),
      );
      rethrow;
    }
  }

  /// Un document mal formé est écarté, et signalé une fois par lecture.
  List<MealSuggestion> _read(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final out = <MealSuggestion>[];
    String? firstMalformed;
    for (final d in docs) {
      final s = MealSuggestion.fromFirestore(d.id, d.data());
      if (s == null) {
        firstMalformed ??= d.id;
      } else {
        out.add(s);
      }
    }
    if (firstMalformed != null) {
      unawaited(
        _errorReportService.reportError(
          feature: 'meal_suggestions.malformed',
          error: FormatException('Suggestion de repas mal formée'),
          stackTrace: StackTrace.current,
          context: {'first_suggestion_id': firstMalformed},
        ),
      );
    }
    return out;
  }

  /// Envoie la suggestion [draft] de [authorUid] et rend son identifiant.
  ///
  /// L'identifiant est imposé par les règles :
  /// `{group_id}_{auteur}_{jour}_{n}`, n de 0 à 4. Le premier n libre parmi
  /// les suggestions de l'auteur ce jour-là est pris. Lève
  /// [SuggestionLimitReached] quand les cinq sont pris. Toute autre erreur,
  /// brouillon invalide compris, est remontée au rapport, puis relancée.
  Future<String> suggest(MealSuggestionDraft draft, String authorUid) async {
    MealSuggestion? suggestion;
    try {
      suggestion = draft.toSuggestion(authorUid);
      final existing = await _col
          .where('author_uid', isEqualTo: authorUid)
          .where('group_id', isEqualTo: suggestion.groupId)
          .where('day', isEqualTo: suggestion.dayKey)
          .get();
      final taken = {for (final d in existing.docs) d.id};
      for (var n = 0; n < kSuggestionsPerAuthorPerDay; n++) {
        final id = mealSuggestionId(
          groupId: suggestion.groupId,
          authorUid: authorUid,
          dayKey: suggestion.dayKey,
          n: n,
        );
        if (taken.contains(id)) continue;
        await _col.doc(id).set(suggestion.toFirestore());
        return id;
      }
      throw const SuggestionLimitReached();
    } on SuggestionLimitReached {
      rethrow;
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'meal_suggestions.suggest',
          error: e,
          stackTrace: st,
          context: {
            'uid': authorUid,
            'group_id': draft.groupId,
            'day': mealSuggestionDayKey(draft.day),
            'free_name': draft.recipeId == null,
            'built': suggestion != null,
          },
        ),
      );
      rethrow;
    }
  }

  /// Retire la suggestion [suggestion]. Erreur remontée au rapport, puis
  /// relancée.
  Future<void> remove(MealSuggestion suggestion) async {
    try {
      await _col.doc(suggestion.id).delete();
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'meal_suggestions.remove',
          error: e,
          stackTrace: st,
          context: {
            'suggestion_id': suggestion.id,
            'group_id': suggestion.groupId,
          },
        ),
      );
      rethrow;
    }
  }

  /// Remet une suggestion retirée (« Annuler »), sous le même identifiant.
  /// Sa date de création devient celle de la remise : les règles n'admettent
  /// que l'heure du serveur.
  Future<void> restore(MealSuggestion suggestion) async {
    try {
      await _col.doc(suggestion.id).set(suggestion.toFirestore());
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'meal_suggestions.restore',
          error: e,
          stackTrace: st,
          context: {
            'suggestion_id': suggestion.id,
            'group_id': suggestion.groupId,
          },
        ),
      );
      rethrow;
    }
  }
}
