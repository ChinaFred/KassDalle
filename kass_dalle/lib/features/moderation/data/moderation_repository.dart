import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/moderation_entry.dart';

/// Lecture du journal de modération et décisions d'administration.
///
/// Le journal porte **toutes** les images. Une page qui ne montrerait que les
/// rejets ne dirait rien du plus important : ce que la modération laisse
/// passer.
class ModerationRepository {
  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  static const _functionsRegion = 'europe-west1';
  static const collection = 'image_moderation';

  ModerationRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _functions =
           functions ?? FirebaseFunctions.instanceFor(region: _functionsRegion),
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Le journal, filtré par état et borné dans le temps.
  ///
  /// `status == null` rend tous les états : c'est le mode par défaut de
  /// l'écran, et c'est délibéré.
  Stream<List<ModerationEntry>> watchJournal({
    String? status,
    DateTime? since,
    int limit = 100,
  }) {
    Query<Map<String, dynamic>> query = _db.collection(collection);
    if (status != null) query = query.where('status', isEqualTo: status);
    if (since != null) {
      query = query.where(
        'created_at',
        isGreaterThanOrEqualTo: Timestamp.fromDate(since),
      );
    }
    return query
        .orderBy('created_at', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => ModerationEntry.fromMap(d.id, d.data()))
              .toList(),
        );
  }

  /// Nombre d'images qui attendent réellement quelqu'un.
  ///
  /// Le badge ne compte pas le journal entier : il compte ce sur quoi un
  /// administrateur doit agir. Un badge qui afficherait le total ne
  /// redescendrait jamais à zéro, et cesserait donc d'être lu.
  Stream<int> watchPendingCount({int cap = 99}) {
    return _db
        .collection(collection)
        .where('status', isEqualTo: 'manual_review')
        .limit(cap)
        .snapshots()
        .map((snap) => snap.docs.length);
  }

  /// Décision d'un administrateur. [note] est obligatoire pour un refus.
  Future<void> review({
    required String moderationId,
    required bool approve,
    String note = '',
  }) async {
    try {
      await _functions
          .httpsCallable('reviewModeratedImageFn')
          .call<Map<Object?, Object?>>({
            'moderationId': moderationId,
            'decision': approve ? 'approve' : 'reject',
            'note': note,
          });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'moderation.review',
        error: e,
        stackTrace: st,
        context: {'moderationId': moderationId, 'approve': approve},
      );
      rethrow;
    }
  }

  /// Relance les images restées sans verdict. Rend le nombre traité.
  Future<({int relaunched, int stillDown})> retryPending() async {
    try {
      final result = await _functions
          .httpsCallable('retryPendingModerationFn')
          .call<Map<Object?, Object?>>(<String, Object?>{});
      return (
        relaunched: (result.data['relaunched'] as num?)?.toInt() ?? 0,
        stillDown: (result.data['stillDown'] as num?)?.toInt() ?? 0,
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'moderation.retryPending',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
