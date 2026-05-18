import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../domain/dead_letter.dart';

/// Accès Firestore + callables pour la Dead Letter Queue.
class DeadLetterRepository {
  final FirebaseFirestore _db;
  final FirebaseFunctions _functions;

  DeadLetterRepository({FirebaseFirestore? db, FirebaseFunctions? functions})
    : _db = db ?? FirebaseFirestore.instance,
      _functions =
          functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1');

  /// Stream temps réel de toutes les entrées DLQ, plus récentes d'abord.
  Stream<List<DeadLetter>> watchAll({int limit = 200}) {
    return _db
        .collection('dead_letters')
        .orderBy('failed_at', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs.map(DeadLetter.fromDoc).toList(growable: false),
        );
  }

  /// Relance un job DLQ : crée un nouveau processing_job côté backend et
  /// marque l'entrée DLQ comme relancée. Retourne l'id du nouveau job.
  Future<String> relaunch(String deadLetterId) async {
    final res = await _functions
        .httpsCallable('relaunchDeadLetterFn')
        .call<dynamic>({'deadLetterId': deadLetterId});
    final data = Map<String, dynamic>.from(res.data as Map);
    return (data['newJobId'] ?? '') as String;
  }

  /// Supprime définitivement une entrée DLQ.
  Future<void> delete(String deadLetterId) async {
    await _functions.httpsCallable('deleteDeadLetterFn').call<dynamic>({
      'deadLetterId': deadLetterId,
    });
  }
}
