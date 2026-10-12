import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/backfill_status.dart';

/// État et programmation des backfills, lus en continu.
///
/// Le serveur écrit seul ces documents (`functions/src/backfills/runner.ts`,
/// `setBackfillScheduleFn`, `setBackfillDoneFn`) ; l'écran les lit ici, si
/// bien qu'un passage programmé apparaît sans rafraîchir. Lecture réservée
/// aux administrateurs par les règles de sécurité, comme l'écran lui-même.
class BackfillStatusRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  BackfillStatusRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Même valeur que `BACKFILL_RUN_DOC_TYPE` côté serveur.
  static const runDocType = 'backfill_run';

  /// Même identifiant que `BACKFILL_SCHEDULES_DOC_ID` côté serveur.
  static const schedulesDocId = 'backfill_schedules';

  /// États de tous les backfills, par clé. Un backfill jamais lancé n'a pas
  /// de document : il est absent de la table.
  Stream<Map<String, BackfillRunState>> watchRuns() {
    return _firestore
        .collection('app_config')
        .where('doc_type', isEqualTo: runDocType)
        .snapshots()
        .map((snap) {
          final out = <String, BackfillRunState>{};
          for (final doc in snap.docs) {
            final data = _withDates(doc.data());
            final key = data['key'];
            if (key is! String || key.isEmpty) continue;
            out[key] = BackfillRunState.fromMap(key, data);
          }
          return out;
        })
        .transform(_reported('watchRuns'));
  }

  /// Programmations des récurrents.
  Stream<BackfillSchedules> watchSchedules() {
    return _firestore
        .collection('app_config')
        .doc(schedulesDocId)
        .snapshots()
        .map((snap) => BackfillSchedules(snap.data() ?? const {}))
        .transform(_reported('watchSchedules'));
  }

  /// Horodatages Firestore convertis en `DateTime`, au premier niveau.
  static Map<String, dynamic> _withDates(Map<String, dynamic> data) => {
    for (final entry in data.entries)
      entry.key: entry.value is Timestamp
          ? (entry.value as Timestamp).toDate()
          : entry.value,
  };

  /// Journalise une erreur de lecture, puis la laisse passer : l'écran
  /// l'affiche (« Impossible de lire l'état des backfills »).
  StreamTransformer<T, T> _reported<T>(String operation) {
    return StreamTransformer<T, T>.fromHandlers(
      handleError: (error, stackTrace, sink) {
        unawaited(
          _errorReportService.reportError(
            feature: 'backfill_status_repository',
            error: error,
            stackTrace: stackTrace,
            context: {'operation': operation},
          ),
        );
        sink.addError(error, stackTrace);
      },
    );
  }
}
